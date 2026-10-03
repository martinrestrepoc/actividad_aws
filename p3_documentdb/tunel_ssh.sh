#!/usr/bin/env bash

# Clave privada correspondiente a la clave publica que registramos con Terraform.
CLAVE="$HOME/.ssh/p3_documentdb"

# Se reemplazan estos dos valores con bastion_ip y endpoint de config.json.
IP_EC2="44.211.238.144"
ENDPOINT_DOCUMENTDB="p3-documentdb.cluster-cgbk422gy31s.us-east-1.docdb.amazonaws.com"

# Python y Compass se conectaran a este puerto.
PUERTO_LOCAL=27018

# -i indica la clave privada para entrar a la EC2.
# -N abre solo el tunel, sin ejecutar comandos en la EC2.
# -L reenvia el puerto local al puerto 27017 de DocumentDB pasando por la EC2.
# 127.0.0.1 permite usar el tunel solo desde tu propio computador.
# ExitOnForwardFailure cierra SSH si no puede abrir el puerto local.
# ec2-user es el usuario de la instancia Amazon Linux.
# Deja esta terminal abierta mientras usas la base. Para cerrar, pulsa Ctrl+C.
ssh -i "$CLAVE" -N \
  -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:$PUERTO_LOCAL:$ENDPOINT_DOCUMENTDB:27017" \
  "ec2-user@$IP_EC2"
