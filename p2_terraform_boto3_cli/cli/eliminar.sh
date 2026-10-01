#!/usr/bin/env bash
set -euo pipefail

carpeta=$(cd "$(dirname "$0")" && pwd)
inventario="$carpeta/.runtime/recursos.json"
aws_cli() { aws --profile default --region us-east-1 --no-cli-pager "$@"; }
[[ -f "$inventario" ]] || { echo "no hay inventario" >&2; exit 1; }
guardar() {
    jq --arg clave "$1" --arg valor "$2" '.[$clave] = $valor' "$inventario" > "$inventario.tmp"
    mv "$inventario.tmp" "$inventario"
}

# no se elimina infraestructura con otra identidad o cuenta
identidad=$(aws_cli sts get-caller-identity --output json)
arn=$(jq -r '.Arn' <<< "$identidad")
cuenta=$(jq -r '.Account' <<< "$identidad")
[[ "$arn" =~ :user/(.*/)?user_cli$ && "$cuenta" == $(jq -r '.account' "$inventario") && $(jq -r '.region' "$inventario") == us-east-1 ]] || exit 1
[[ $(jq -r '.phase' "$inventario") != deleted ]] || { echo "la ejecución ya está eliminada"; exit 0; }
read -r -p "Eliminar sin snapshot final. Escribe si para continuar: " respuesta
[[ "$respuesta" == si ]] || exit 0
guardar phase deleting

# admite recursos ya borrados y espera si aws todavía está liberando la red
intentar() {
    local ausente="$1" intento
    shift
    for intento in {1..60}; do
        if aws_cli "$@" 2> "$carpeta/.runtime/error.txt"; then
            return 0
        fi
        if grep -Fq "($ausente)" "$carpeta/.runtime/error.txt"; then
            return 0
        fi
        if ! grep -Fq '(DependencyViolation)' "$carpeta/.runtime/error.txt"; then
            break
        fi
        sleep 5
    done
    cat "$carpeta/.runtime/error.txt" >&2
    return 1
}

instancia=$(jq -r '.instance // empty' "$inventario")
if [[ -n "$instancia" ]]; then
    datos=$(intentar InvalidInstanceID.NotFound ec2 describe-instances --instance-ids "$instancia" --output json)
    if [[ -n "$datos" ]]; then
        volumen=$(jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId // empty' <<< "$datos")
        [[ -z "$volumen" ]] || guardar volume "$volumen"
        echo "Terminando EC2..."
        aws_cli ec2 terminate-instances --instance-ids "$instancia" >/dev/null
        aws_cli ec2 wait instance-terminated --instance-ids "$instancia"
    fi
fi

db=$(jq -r '.database // empty' "$inventario")
if [[ -n "$db" ]]; then
    datos=$(intentar DBInstanceNotFound rds describe-db-instances --db-instance-identifier "$db" --output json)
    if [[ -n "$datos" ]]; then
        secreto=$(jq -r '.DBInstances[0].MasterUserSecret.SecretArn // empty' <<< "$datos")
        [[ -z "$secreto" ]] || guardar secret_arn "$secreto"
        if [[ $(jq -r '.DBInstances[0].DBInstanceStatus' <<< "$datos") != deleting ]]; then
            echo "Eliminando RDS sin snapshot final..."
            aws_cli rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups >/dev/null
        fi
        echo "Esperando la eliminación de RDS..."
        aws_cli rds wait db-instance-deleted --db-instance-identifier "$db"
    fi
fi

# se eliminan primero los recursos que dependen de la red
subgrupo=$(jq -r '.db_subnet_group // empty' "$inventario")
[[ -z "$subgrupo" ]] || intentar DBSubnetGroupNotFoundFault rds delete-db-subnet-group --db-subnet-group-name "$subgrupo"
for clave in sg_rds sg_ec2; do
    id=$(jq -r --arg clave "$clave" '.[$clave] // empty' "$inventario")
    [[ -z "$id" ]] || intentar InvalidGroup.NotFound ec2 delete-security-group --group-id "$id"
done
for clave in subnet1 subnet2; do
    id=$(jq -r --arg clave "$clave" '.[$clave] // empty' "$inventario")
    [[ -z "$id" ]] || intentar InvalidSubnetID.NotFound ec2 delete-subnet --subnet-id "$id"
done
vpc=$(jq -r '.vpc // empty' "$inventario")
[[ -z "$vpc" ]] || intentar InvalidVpcID.NotFound ec2 delete-vpc --vpc-id "$vpc"
bucket=$(jq -r '.bucket // empty' "$inventario")
# el bucket debe estar vacío; no se borran objetos automáticamente
[[ -z "$bucket" ]] || intentar NoSuchBucket s3api delete-bucket --bucket "$bucket" --expected-bucket-owner "$cuenta"

volumen=$(jq -r '.volume // empty' "$inventario")
[[ -z "$volumen" || "$volumen" == None ]] || aws_cli ec2 wait volume-deleted --volume-ids "$volumen"
secreto=$(jq -r '.secret_arn // empty' "$inventario")
if [[ -n "$secreto" && "$secreto" != None ]]; then
    for intento in {1..60}; do
        datos=$(intentar ResourceNotFoundException secretsmanager describe-secret --secret-id "$secreto" --output json)
        [[ -n "$datos" ]] || break
        sleep 5
    done
    [[ -z "$datos" ]] || { echo "el secreto todavía existe" >&2; exit 1; }
fi

guardar phase deleted
bash "$carpeta/estado.sh" | tee "$carpeta/.runtime/eliminacion.txt"
echo "Limpieza completada."
