import json
import os

import boto3

sesion = boto3.Session()

# Confirma qué identidad utiliza realmente Python.
identidad = sesion.client("sts").get_caller_identity()
print("Identidad AWS:", identidad["Arn"])

cliente = sesion.client(
    "secretsmanager",
    region_name=os.environ["AWS_REGION"],
)

respuesta = cliente.get_secret_value(
    SecretId=os.environ["SECRET_ID"],
    VersionStage="AWSCURRENT",
)

datos = json.loads(respuesta["SecretString"])
usuario = datos["username"]
contrasena = datos["password"]

print("Usuario y contraseña recuperados correctamente.")
print("Versión actual:", respuesta["VersionId"])
print("Usuario:", usuario)
print("Contraseña:", contrasena)