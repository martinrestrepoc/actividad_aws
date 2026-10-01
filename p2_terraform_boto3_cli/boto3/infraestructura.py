"""creación, consulta y eliminación de los recursos de la práctica."""
import argparse
import json
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# mismos parámetros utilizados en el despliegue terraform.
PROFILE = "default"
REGION = "us-east-1"
AMI = "ami-03c3da4cfa8e8943a"
POSTGRES = "17.11"
EC2_TYPE = "t3.micro"
RDS_CLASS = "db.t3.micro"
CIDR = "10.42.0.0/16"
BASE = Path(__file__).resolve().parent
STATE = BASE / ".runtime" / "recursos.json"


def guardar(datos, path=None):
    """guarda el inventario sin dejar el archivo a medio escribir."""
    path = STATE if path is None else path
    path.parent.mkdir(parents=True, exist_ok=True)
    temporal = path.with_suffix(".tmp")
    temporal.write_text(json.dumps(datos, indent=2, default=str) + "\n")
    temporal.replace(path)


def consultar(funcion, ausente, **kwargs):
    """devuelve none si el recurso no existe; los demás errores se propagan."""
    try:
        return funcion(**kwargs)
    except ClientError as error:
        if error.response["Error"]["Code"] in ausente:
            return None
        raise


def reintentar_dependencia(funcion, **kwargs):
    """espera a que se liberen las dependencias antes de borrar la red."""
    for intento in range(60):
        try:
            return funcion(**kwargs)
        except ClientError as error:
            if error.response["Error"]["Code"] != "DependencyViolation" or intento == 59:
                raise
            print("AWS todavía libera dependencias de red; reintentando en 10 segundos...", flush=True)
            time.sleep(10)


class Laboratorio:
    def __init__(self):
        # sesión explícita: no utiliza credenciales de root ni las escribe en archivos.
        sesion = boto3.Session(profile_name=PROFILE, region_name=REGION)
        opciones = Config(retries={"mode": "standard", "max_attempts": 5},
                          connect_timeout=10, read_timeout=60)
        self.ec2 = sesion.client("ec2", config=opciones)
        self.rds = sesion.client("rds", config=opciones)
        self.s3 = sesion.client("s3", config=opciones)
        self.secrets = sesion.client("secretsmanager", config=opciones)
        identidad = sesion.client("sts", config=opciones).get_caller_identity()
        if not re.search(r":user/(.*/)?user_cli$", identidad["Arn"]):
            raise RuntimeError("el perfil no corresponde a user_cli")
        self.account = identidad["Account"]
        self.arn = identidad["Arn"]
        self.datos = json.loads(STATE.read_text()) if STATE.exists() else {}
        if self.datos and (self.datos["account"] != self.account or self.datos["region"] != REGION):
            raise RuntimeError("el inventario corresponde a otra cuenta o región")
        print(f"Identidad: {self.arn}\nRegión: {REGION}", flush=True)

    def registrar(self, clave, valor):
        # guarda cada id para poder eliminar los recursos después
        self.datos[clave] = valor
        guardar(self.datos)

    def tags(self, nombre):
        # run_id identifica los recursos de una misma ejecución
        return [{"Key": k, "Value": v} for k, v in {
            "Name": nombre, "Project": "actividad-aws", "Method": "boto3",
            "RunId": self.datos["run_id"],
        }.items()]

    def especificacion(self, tipo, nombre):
        return [{"ResourceType": tipo, "Tags": self.tags(nombre)}]

    def verificar(self):
        """consulta la limpieza anterior y la disponibilidad de las instancias."""
        tf = BASE.parent / "terraform" / "terraform.tfstate"
        if tf.exists():
            estado_tf = json.loads(tf.read_text())
            if any(r.get("mode") == "managed" for r in estado_tf.get("resources", [])):
                raise RuntimeError("quedan recursos en el estado de terraform")
        vpcs = self.ec2.describe_vpcs(Filters=[
            {"Name": "tag:Project", "Values": ["actividad-aws"]},
            {"Name": "tag:Method", "Values": ["terraform", "boto3", "cli"]},
        ])["Vpcs"]
        if vpcs:
            raise RuntimeError("quedan vpc de la actividad: " +
                               ", ".join(v["VpcId"] for v in vpcs))
        anterior = consultar(self.rds.describe_db_instances, {"DBInstanceNotFound"},
                             DBInstanceIdentifier="eia-lab-terraform")
        if anterior:
            raise RuntimeError("todavía existe la instancia rds de terraform")
        imagen = self.ec2.describe_images(ImageIds=[AMI])["Images"]
        if not imagen or imagen[0]["State"] != "available" or imagen[0]["Architecture"] != "x86_64":
            raise RuntimeError("la ami no está disponible o no es x86_64")
        opciones = []
        # la respuesta puede venir repartida en varias páginas
        for pagina in self.rds.get_paginator("describe_orderable_db_instance_options").paginate(
            Engine="postgres", EngineVersion=POSTGRES, DBInstanceClass=RDS_CLASS, Vpc=True
        ):
            opciones.extend(o for o in pagina["OrderableDBInstanceOptions"]
                            if o["StorageType"] == "gp3" and o["SupportsStorageEncryption"])
        zonas_rds = {a["Name"] for o in opciones for a in o["AvailabilityZones"]}
        zonas = sorted(a["ZoneName"] for a in self.ec2.describe_availability_zones(Filters=[
            {"Name": "zone-type", "Values": ["availability-zone"]},
            {"Name": "state", "Values": ["available"]},
        ])["AvailabilityZones"] if a["ZoneName"] in zonas_rds)
        if len(zonas) < 2:
            raise RuntimeError("se necesitan dos zonas compatibles con la configuración de rds")
        print(f"Consultas correctas. AMI: {AMI}; PostgreSQL: {POSTGRES}; zonas: {zonas[:2]}")
        return zonas[:2], imagen[0]["RootDeviceName"]

    def crear(self):
        if self.datos:
            raise RuntimeError("ya existe un inventario de recursos")
        zonas, raiz = self.verificar()
        run = uuid.uuid4().hex[:12]
        nombre = f"eia-lab-boto3-{run}"
        self.datos = {"account": self.account, "region": REGION, "identity": self.arn,
                      "run_id": run, "phase": "creating", "started": datetime.now(timezone.utc).isoformat(),
                      "ami": AMI, "postgres_version": POSTGRES, "subnets": []}
        guardar(self.datos)

        # 1. red: primero vpc; luego subredes y grupos de seguridad.
        print("Creando VPC...", flush=True)
        vpc = self.ec2.create_vpc(CidrBlock=CIDR, TagSpecifications=self.especificacion("vpc", nombre))["Vpc"]["VpcId"]
        self.registrar("vpc", vpc)
        self.ec2.get_waiter("vpc_available").wait(VpcIds=[vpc])
        self.ec2.modify_vpc_attribute(VpcId=vpc, EnableDnsSupport={"Value": True})
        self.ec2.modify_vpc_attribute(VpcId=vpc, EnableDnsHostnames={"Value": True})
        # una subred por zona, con rangos 10.42.1.0/24 y 10.42.2.0/24
        for indice, zona in enumerate(zonas, start=1):
            sub = self.ec2.create_subnet(VpcId=vpc, CidrBlock=f"10.42.{indice}.0/24", AvailabilityZone=zona,
                                        TagSpecifications=self.especificacion("subnet", f"{nombre}-{indice}"))["Subnet"]["SubnetId"]
            self.datos["subnets"].append(sub)
            guardar(self.datos)
            self.ec2.modify_subnet_attribute(SubnetId=sub, MapPublicIpOnLaunch={"Value": False})
        for tipo in ["ec2", "rds"]:
            sg = self.ec2.create_security_group(GroupName=f"{nombre}-{tipo}", Description=f"Laboratorio {tipo}",
                 VpcId=vpc, TagSpecifications=self.especificacion("security-group", f"{nombre}-{tipo}"))["GroupId"]
            self.registrar(f"sg_{tipo}", sg)
            # un sg nuevo permite salida general. revocarla antes de agregar reglas limitadas.
            reglas = self.ec2.describe_security_groups(GroupIds=[sg])["SecurityGroups"][0]["IpPermissionsEgress"]
            if reglas:
                self.ec2.revoke_security_group_egress(GroupId=sg, IpPermissions=reglas)
        # permite que ec2 se conecte a postgres por el puerto 5432
        self.ec2.authorize_security_group_egress(GroupId=self.datos["sg_ec2"], IpPermissions=[{
            "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
            "IpRanges": [{"CidrIp": CIDR}],
        }])
        self.ec2.authorize_security_group_ingress(GroupId=self.datos["sg_rds"], IpPermissions=[{
            "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
            "UserIdGroupPairs": [{"GroupId": self.datos["sg_ec2"]}],
        }])

        # 2. s3 vacío. en us-east-1 createbucket no lleva locationconstraint.
        print("Creando bucket S3...", flush=True)
        bucket = f"{nombre}-{self.account}"
        self.s3.create_bucket(Bucket=bucket)
        self.registrar("bucket", bucket)
        self.s3.put_bucket_tagging(Bucket=bucket, Tagging={"TagSet": self.tags(nombre)})
        self.s3.put_public_access_block(Bucket=bucket, PublicAccessBlockConfiguration={
            "BlockPublicAcls": True, "IgnorePublicAcls": True,
            "BlockPublicPolicy": True, "RestrictPublicBuckets": True,
        })

        # 3. ec2. clienttoken evita duplicar instancias si aws reintenta la solicitud.
        print("Creando EC2...", flush=True)
        instancia = self.ec2.run_instances(ImageId=AMI, InstanceType=EC2_TYPE, MinCount=1, MaxCount=1,
            ClientToken=run, NetworkInterfaces=[{"DeviceIndex": 0, "SubnetId": self.datos["subnets"][0],
                "Groups": [self.datos["sg_ec2"]], "AssociatePublicIpAddress": False}],
            CreditSpecification={"CpuCredits": "standard"}, MetadataOptions={"HttpTokens": "required"},
            BlockDeviceMappings=[{"DeviceName": raiz, "Ebs": {"VolumeSize": 8, "VolumeType": "gp3",
                "Encrypted": True, "DeleteOnTermination": True}}],
            TagSpecifications=self.especificacion("instance", nombre) + self.especificacion("volume", nombre)
        )["Instances"][0]
        self.registrar("instance", instancia["InstanceId"])

        # 4. rds y su grupo de subredes. nunca enviar masteruserpassword.
        self.rds.create_db_subnet_group(DBSubnetGroupName=nombre, DBSubnetGroupDescription="Laboratorio privado",
                                       SubnetIds=self.datos["subnets"], Tags=self.tags(nombre))
        self.registrar("db_subnet_group", nombre)
        print("Creando RDS (puede tardar varios minutos)...", flush=True)
        db = self.rds.create_db_instance(DBInstanceIdentifier=nombre, Engine="postgres", EngineVersion=POSTGRES,
            DBInstanceClass=RDS_CLASS, DBName="actividad", MasterUsername="labadmin", Port=5432,
            ManageMasterUserPassword=True, AllocatedStorage=20, StorageType="gp3", StorageEncrypted=True,
            DBSubnetGroupName=nombre, VpcSecurityGroupIds=[self.datos["sg_rds"]], PubliclyAccessible=False,
            MultiAZ=False, BackupRetentionPeriod=0, DeletionProtection=False, MonitoringInterval=0,
            EnablePerformanceInsights=False, EngineLifecycleSupport="open-source-rds-extended-support-disabled",
            Tags=self.tags(nombre))["DBInstance"]
        self.registrar("database", nombre)
        if db.get("MasterUserSecret", {}).get("SecretArn"):
            self.registrar("secret_arn", db["MasterUserSecret"]["SecretArn"])
        # los waiters consultan hasta que las instancias estén listas
        self.ec2.get_waiter("instance_running").wait(InstanceIds=[self.datos["instance"]])
        self.rds.get_waiter("db_instance_available").wait(DBInstanceIdentifier=nombre,
                                                       WaiterConfig={"Delay": 30, "MaxAttempts": 120})
        self.registrar("phase", "created")
        self.estado()

    def estado(self):
        if not self.datos:
            raise RuntimeError("no hay inventario")
        d = self.datos
        # el resumen conserva el formato usado en las evidencias
        resultado = {"identity": self.arn, "region": REGION, "phase": d["phase"]}
        if d.get("vpc"):
            v = consultar(self.ec2.describe_vpcs, {"InvalidVpcID.NotFound"}, VpcIds=[d["vpc"]])
            resultado["vpc"] = d["vpc"] if v else "ausente"
        if d.get("bucket"):
            b = consultar(self.s3.head_bucket, {"404", "NoSuchBucket", "NotFound"}, Bucket=d["bucket"], ExpectedBucketOwner=self.account)
            resultado["bucket"] = d["bucket"] if b is not None else "ausente"
        if d.get("instance"):
            e = consultar(self.ec2.describe_instances, {"InvalidInstanceID.NotFound"}, InstanceIds=[d["instance"]])
            if e:
                instancia = e["Reservations"][0]["Instances"][0]
                resultado["ec2"] = {"id": d["instance"], "state": instancia["State"]["Name"]}
                volumenes = [b["Ebs"]["VolumeId"] for b in instancia.get("BlockDeviceMappings", []) if "Ebs" in b]
                if volumenes:
                    self.registrar("volumes", volumenes)
            else:
                resultado["ec2"] = "ausente"
        if d.get("database"):
            db = consultar(self.rds.describe_db_instances, {"DBInstanceNotFound"}, DBInstanceIdentifier=d["database"])
            if db:
                db = db["DBInstances"][0]
                resultado["rds"] = {"id": d["database"], "state": db["DBInstanceStatus"],
                                    "endpoint": db.get("Endpoint", {}).get("Address")}
                secreto = db.get("MasterUserSecret", {})
                if secreto.get("SecretArn"):
                    self.registrar("secret_arn", secreto["SecretArn"])
                    resultado["secret"] = {"arn": secreto["SecretArn"], "status": secreto.get("SecretStatus")}
            else:
                resultado["rds"] = "ausente"
        print(json.dumps(resultado, indent=2))
        guardar(resultado, BASE / ".runtime" / "ultima-verificacion.json")
        if (isinstance(resultado.get("ec2"), dict) and resultado["ec2"]["state"] == "running"
                and isinstance(resultado.get("rds"), dict) and resultado["rds"]["state"] == "available"):
            guardar(resultado, BASE / ".runtime" / "evidencia-creacion.json")
        return resultado

    def eliminar(self):
        if not self.datos:
            raise RuntimeError("no hay inventario")
        d = self.datos
        if d.get("phase") == "deleted":
            print("Esta ejecución ya se verificó como eliminada.")
            return
        self.registrar("phase", "deleting")
        # orden inverso: cómputo, rds, grupo de subredes, sg, subredes y vpc.
        if d.get("instance"):
            e = consultar(self.ec2.describe_instances, {"InvalidInstanceID.NotFound"}, InstanceIds=[d["instance"]])
            if e:
                instancia = e["Reservations"][0]["Instances"][0]
                volumenes = [b["Ebs"]["VolumeId"] for b in instancia.get("BlockDeviceMappings", []) if "Ebs" in b]
                if volumenes:
                    self.registrar("volumes", volumenes)
                if instancia["State"]["Name"] != "terminated":
                    print("Terminando EC2...", flush=True)
                    self.ec2.terminate_instances(InstanceIds=[d["instance"]])
                    self.ec2.get_waiter("instance_terminated").wait(InstanceIds=[d["instance"]])
        if d.get("database"):
            db = consultar(self.rds.describe_db_instances, {"DBInstanceNotFound"}, DBInstanceIdentifier=d["database"])
            if db:
                db = db["DBInstances"][0]
                secreto = db.get("MasterUserSecret", {}).get("SecretArn")
                if secreto:
                    self.registrar("secret_arn", secreto)
                if db["DBInstanceStatus"] != "deleting":
                    print("Eliminando RDS sin snapshot final...", flush=True)
                    self.rds.delete_db_instance(DBInstanceIdentifier=d["database"], SkipFinalSnapshot=True,
                                                DeleteAutomatedBackups=True)
                print("Esperando la eliminación de RDS...", flush=True)
                self.rds.get_waiter("db_instance_deleted").wait(DBInstanceIdentifier=d["database"],
                                                              WaiterConfig={"Delay": 30, "MaxAttempts": 120})
        if d.get("db_subnet_group"):
            consultar(self.rds.delete_db_subnet_group, {"DBSubnetGroupNotFoundFault"},
                       DBSubnetGroupName=d["db_subnet_group"])
        for clave in ["sg_rds", "sg_ec2"]:
            if d.get(clave):
                consultar(lambda **kw: reintentar_dependencia(self.ec2.delete_security_group, **kw),
                           {"InvalidGroup.NotFound"}, GroupId=d[clave])
        for sub in d.get("subnets", []):
            consultar(lambda **kw: reintentar_dependencia(self.ec2.delete_subnet, **kw),
                       {"InvalidSubnetID.NotFound"}, SubnetId=sub)
        if d.get("vpc"):
            consultar(lambda **kw: reintentar_dependencia(self.ec2.delete_vpc, **kw),
                       {"InvalidVpcID.NotFound"}, VpcId=d["vpc"])
        if d.get("bucket"):
            # no elimina objetos ajenos: bucketnotempty detiene la limpieza.
            consultar(self.s3.delete_bucket, {"NoSuchBucket"}, Bucket=d["bucket"], ExpectedBucketOwner=self.account)
        # la limpieza solo termina si los discos desaparecen y el secreto fue eliminado.
        for volumen in d.get("volumes", []):
            self.ec2.get_waiter("volume_deleted").wait(VolumeIds=[volumen],
                                                      WaiterConfig={"Delay": 5, "MaxAttempts": 120})
        if d.get("secret_arn"):
            for intento in range(60):
                secreto = consultar(self.secrets.describe_secret, {"ResourceNotFoundException"}, SecretId=d["secret_arn"])
                if secreto is None:
                    break
                time.sleep(5)
            else:
                raise RuntimeError("el secreto todavía existe")
        resultado = self.estado()
        for campo in ["vpc", "bucket", "rds"]:
            if campo in resultado and resultado[campo] != "ausente":
                raise RuntimeError(f"{campo} todavía existe")
        ec2 = resultado.get("ec2", "ausente")
        if ec2 != "ausente" and ec2.get("state") != "terminated":
            raise RuntimeError("ec2 todavía no está terminada")
        self.registrar("phase", "deleted")
        resultado["phase"] = "deleted"
        guardar(resultado, BASE / ".runtime" / "ultima-verificacion.json")
        guardar({"identity": self.arn, "region": REGION, "result": "deleted",
                 "time": datetime.now(timezone.utc).isoformat(), "resources": self.datos},
                BASE / ".runtime" / "evidencia-eliminacion.json")
        print("Limpieza completada. Conserva el inventario y las evidencias.")


def main():
    # la acción se recibe al ejecutar el archivo desde la terminal
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("accion", choices=["verificar", "crear", "estado", "eliminar"])
    args = parser.parse_args()
    if args.accion in {"crear", "eliminar"}:
        mensaje = "Crear recursos facturables" if args.accion == "crear" else "Eliminar los recursos del inventario SIN snapshot final"
        if input(f"{mensaje}. Escribe si para continuar: ").strip().lower() != "si":
            print("Cancelado.")
            return
    try:
        lab = Laboratorio()
        getattr(lab, args.accion)()
    except (ClientError, BotoCoreError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
