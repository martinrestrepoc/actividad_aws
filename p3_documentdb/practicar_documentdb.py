import json

import boto3
from pymongo import MongoClient

# Ejecutar desde la carpeta p3_documentdb, con el tunel SSH abierto.
with open("config.json") as archivo:
    config = json.load(archivo)

session = boto3.Session(profile_name=config["profile"], region_name=config["region"])
secrets = session.client("secretsmanager")
respuesta = secrets.get_secret_value(SecretId=config["secret_arn"])
credenciales = json.loads(respuesta["SecretString"])

cliente = MongoClient(
    host="127.0.0.1",
    port=config["local_port"],
    username=credenciales["username"],
    password=credenciales["password"],
    authSource="admin",
    tls=True,
    tlsCAFile="global-bundle.pem",
    # El tunel usa localhost; el certificado pertenece al endpoint de AWS.
    tlsAllowInvalidHostnames=True,
    directConnection=True,
    retryWrites=False,
)

coleccion = cliente["actividad_aws"]["pedidos"]

pedidos = [
    {"_id": 1, "categoria": "libros", "cantidad": 2, "precio_unitario": 10000, "estado": "pagado"},
    {"_id": 2, "categoria": "tecnologia", "cantidad": 3, "precio_unitario": 20000, "estado": "pagado"},
    {"_id": 3, "categoria": "hogar", "cantidad": 1, "precio_unitario": 30000, "estado": "pagado"},
    {"_id": 4, "categoria": "libros", "cantidad": 2, "precio_unitario": 40000, "estado": "pendiente"},
    {"_id": 5, "categoria": "tecnologia", "cantidad": 3, "precio_unitario": 50000, "estado": "pagado"},
    {"_id": 6, "categoria": "hogar", "cantidad": 1, "precio_unitario": 60000, "estado": "pagado"},
    {"_id": 7, "categoria": "libros", "cantidad": 2, "precio_unitario": 70000, "estado": "pagado"},
    {"_id": 8, "categoria": "tecnologia", "cantidad": 3, "precio_unitario": 80000, "estado": "pendiente"},
    {"_id": 9, "categoria": "hogar", "cantidad": 1, "precio_unitario": 90000, "estado": "pagado"},
    {"_id": 10, "categoria": "libros", "cantidad": 2, "precio_unitario": 100000, "estado": "pagado"},
    {"_id": 11, "categoria": "tecnologia", "cantidad": 3, "precio_unitario": 110000, "estado": "pagado"},
    {"_id": 12, "categoria": "hogar", "cantidad": 1, "precio_unitario": 120000, "estado": "pendiente"},
]

coleccion.insert_many(pedidos)
print("Se insertaron 12 pedidos.")

print("Filtro: pagados con precio mayor o igual a 50000")
for pedido in coleccion.find({"estado": "pagado", "precio_unitario": {"$gte": 50000}}):
    print(pedido)

print("Ordenacion: precio de mayor a menor")
for pedido in coleccion.find().sort("precio_unitario", -1):
    print(pedido)

print("Agregacion: ingresos de pedidos pagados por categoria")
for resultado in coleccion.aggregate([
    {"$match": {"estado": "pagado"}},
    {"$group": {
        "_id": "$categoria",
        "pedidos": {"$sum": 1},
        "total_cop": {"$sum": {"$multiply": ["$cantidad", "$precio_unitario"]}},
    }},
    {"$sort": {"total_cop": -1}},
]):
    print(resultado)

cliente.close()
