#!/usr/bin/env bash
set -euo pipefail

# los archivos se guardan junto al script, aunque se ejecute desde otra carpeta
carpeta=$(cd "$(dirname "$0")" && pwd)
inventario="$carpeta/.runtime/recursos.json"
ami="ami-03c3da4cfa8e8943a"
postgres="17.11"

aws_cli() { aws --profile default --region us-east-1 --no-cli-pager "$@"; }
guardar() {
    jq --arg clave "$1" --arg valor "$2" '.[$clave] = $valor' "$inventario" > "$inventario.tmp"
    mv "$inventario.tmp" "$inventario"
}

# se comprueba la identidad antes de crear recursos
identidad=$(aws_cli sts get-caller-identity --output json)
arn=$(jq -r '.Arn' <<< "$identidad")
cuenta=$(jq -r '.Account' <<< "$identidad")
[[ "$arn" =~ :user/(.*/)?user_cli$ ]] || { echo "el perfil no corresponde a user_cli" >&2; exit 1; }
[[ ! -f "$inventario" ]] || { echo "ya existe un inventario de cli" >&2; exit 1; }

# las tres versiones de la actividad se ejecutan por separado
boto="$carpeta/../boto3/.runtime/recursos.json"
if [[ -f "$boto" ]]; then
    [[ $(jq -r '.phase' "$boto") == deleted ]] || { echo "falta eliminar boto3" >&2; exit 1; }
fi
tf="$carpeta/../terraform/terraform.tfstate"
if [[ -f "$tf" ]]; then
    jq -e '[.resources[]? | select(.mode == "managed")] | length == 0' "$tf" >/dev/null
fi
vpcs=$(aws_cli ec2 describe-vpcs --filters Name=tag:Project,Values=actividad-aws --query 'length(Vpcs)' --output text)
[[ "$vpcs" == 0 ]] || { echo "quedan vpc de la actividad" >&2; exit 1; }

# usa la misma imagen y versión de postgres que las versiones anteriores
raiz=$(aws_cli ec2 describe-images --image-ids "$ami" --query 'Images[0].RootDeviceName' --output text)
oferta=$(aws_cli rds describe-orderable-db-instance-options --engine postgres --engine-version "$postgres" \
    --db-instance-class db.t3.micro --vpc --output json)
zonas=$(jq -r '[.OrderableDBInstanceOptions[] | select(.StorageType == "gp3" and .SupportsStorageEncryption) | .AvailabilityZones[].Name] | unique | .[:2][]' <<< "$oferta")
az1=$(sed -n '1p' <<< "$zonas")
az2=$(sed -n '2p' <<< "$zonas")
[[ -n "$az2" && "$raiz" != None ]] || { echo "configuración no disponible" >&2; exit 1; }

printf 'Identidad: %s\nRegión: us-east-1\n' "$arn"
read -r -p "Crear recursos facturables. Escribe si para continuar: " respuesta
[[ "$respuesta" == si ]] || exit 0

run=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-12)
nombre="eia-lab-cli-$run"
tags="[{Key=Name,Value=$nombre},{Key=Project,Value=actividad-aws},{Key=Method,Value=cli},{Key=RunId,Value=$run}]"
# rds recibe las etiquetas como una lista json
json_tags=$(jq -n --arg nombre "$nombre" --arg run "$run" '[{Key:"Name",Value:$nombre},{Key:"Project",Value:"actividad-aws"},{Key:"Method",Value:"cli"},{Key:"RunId",Value:$run}]')
mkdir -p "$carpeta/.runtime"
jq -n --arg account "$cuenta" --arg identity "$arn" --arg run "$run" \
    '{account:$account, identity:$identity, region:"us-east-1", run_id:$run, phase:"creating"}' > "$inventario"

# cada id se guarda al recibirlo para poder limpiar una creación parcial
echo "Creando VPC..."
vpc=$(aws_cli ec2 create-vpc --cidr-block 10.42.0.0/16 --tag-specifications "ResourceType=vpc,Tags=$tags" --query Vpc.VpcId --output text)
guardar vpc "$vpc"
aws_cli ec2 wait vpc-available --vpc-ids "$vpc"
aws_cli ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-support '{"Value":true}'
aws_cli ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames '{"Value":true}'

# una subred privada en cada zona
for numero in 1 2; do
    zona="$az1"
    [[ "$numero" == 1 ]] || zona="$az2"
    subnet=$(aws_cli ec2 create-subnet --vpc-id "$vpc" --cidr-block "10.42.$numero.0/24" \
        --availability-zone "$zona" --tag-specifications "ResourceType=subnet,Tags=$tags" --query Subnet.SubnetId --output text)
    guardar "subnet$numero" "$subnet"
    aws_cli ec2 modify-subnet-attribute --subnet-id "$subnet" --map-public-ip-on-launch '{"Value":false}'
done
subnet1=$(jq -r '.subnet1' "$inventario")
subnet2=$(jq -r '.subnet2' "$inventario")

# se quita la salida general y se permite solo postgres dentro de la vpc
for tipo in ec2 rds; do
    sg=$(aws_cli ec2 create-security-group --group-name "$nombre-$tipo" --description "laboratorio $tipo" \
        --vpc-id "$vpc" --tag-specifications "ResourceType=security-group,Tags=$tags" --query GroupId --output text)
    guardar "sg_$tipo" "$sg"
    reglas=$(aws_cli ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' --output json)
    aws_cli ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions "$reglas" >/dev/null
done
sg_ec2=$(jq -r '.sg_ec2' "$inventario")
sg_rds=$(jq -r '.sg_rds' "$inventario")
aws_cli ec2 authorize-security-group-egress --group-id "$sg_ec2" \
    --ip-permissions 'IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=10.42.0.0/16}]' >/dev/null
aws_cli ec2 authorize-security-group-ingress --group-id "$sg_rds" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$sg_ec2}]" >/dev/null

echo "Creando bucket S3..."
bucket="$nombre-$cuenta"
# us-east-1 no necesita locationconstraint en create-bucket
aws_cli s3api create-bucket --bucket "$bucket" >/dev/null
guardar bucket "$bucket"
aws_cli s3api put-bucket-tagging --bucket "$bucket" --tagging "TagSet=$tags"
aws_cli s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo "Creando EC2..."
instancia=$(aws_cli ec2 run-instances --image-id "$ami" --instance-type t3.micro --count 1 --client-token "$run" \
    --network-interfaces "DeviceIndex=0,SubnetId=$subnet1,Groups=[$sg_ec2],AssociatePublicIpAddress=false" \
    --credit-specification CpuCredits=standard --metadata-options HttpTokens=required \
    --block-device-mappings "DeviceName=$raiz,Ebs={VolumeSize=8,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=$tags" "ResourceType=volume,Tags=$tags" \
    --query 'Instances[0].InstanceId' --output text)
guardar instance "$instancia"

aws_cli rds create-db-subnet-group --db-subnet-group-name "$nombre" --db-subnet-group-description "laboratorio privado" \
    --subnet-ids "$subnet1" "$subnet2" --tags "$json_tags" >/dev/null
guardar db_subnet_group "$nombre"

echo "Creando RDS (puede tardar varios minutos)..."
aws_cli rds create-db-instance --db-instance-identifier "$nombre" --engine postgres --engine-version "$postgres" \
    --db-instance-class db.t3.micro --db-name actividad --master-username labadmin --port 5432 \
    --manage-master-user-password --allocated-storage 20 --storage-type gp3 --storage-encrypted \
    --db-subnet-group-name "$nombre" --vpc-security-group-ids "$sg_rds" --no-publicly-accessible --no-multi-az \
    --backup-retention-period 0 --no-deletion-protection --monitoring-interval 0 --no-enable-performance-insights \
    --engine-lifecycle-support open-source-rds-extended-support-disabled --tags "$json_tags" >/dev/null
guardar database "$nombre"

# espera a que las instancias estén listas antes de consultar el resultado
aws_cli ec2 wait instance-running --instance-ids "$instancia"
volumen=$(aws_cli ec2 describe-instances --instance-ids "$instancia" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
guardar volume "$volumen"
aws_cli rds wait db-instance-available --db-instance-identifier "$nombre"
secreto=$(aws_cli rds describe-db-instances --db-instance-identifier "$nombre" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
guardar secret_arn "$secreto"
guardar phase created
bash "$carpeta/estado.sh" | tee "$carpeta/.runtime/creacion.txt"
