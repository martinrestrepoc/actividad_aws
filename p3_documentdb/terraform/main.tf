locals {
  name = "p3-documentdb"
}

# Consulta zonas disponibles.
data "aws_availability_zones" "available" {
  state = "available"
}
# Amazon Linux 2023 oficial, x86_64 para t3.micro.
data "aws_ami" "linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Crear la red privada donde estarán EC2 y DocumentDB
resource "aws_vpc" "lab" {
  # Rango de direcciones privadas de la VPC.
  cidr_block           = "10.33.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

# Cada subred pertenece a una zona de disponibilidad distinta

# Subred publica para ubicar la EC2 (bastion).
# Un bastión es un servidor que sirve como punto de entrada a una red privada.
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.33.0.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${local.name}-public" }
}
# Subredes privadas para ubicar DocumentDB.
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.33.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${local.name}-private-${count.index + 1}" }
}
# El Internet Gateway conecta la VPC con Internet
resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
}
# Tabla publica asociada a la subred de EC2, con ruta a Internet.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  # Para destinos fuera de la red local, utiliza el Internet Gateway.
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
}
# Cuando varias rutas coinciden, se elige la más específica, es decir, la que tiene el prefijo más largo.

# Asigna la tabla publica a la subred de EC2
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Tabla privada asociada a las subredes privadas de DocumentDB, sin ruta a Internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
}
# Asigna la tabla privada a las subredes privadas de DocumentDB
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Grupos de seguridad, funcionan como reglas de acceso para EC2 y DocumentDB.

# El grupo bastion, asignado a EC2:
# - Permite entrada SSH por el puerto 22 únicamente desde mi IP pública.
# - Permite salida hacia DocumentDB por el puerto 27017.
resource "aws_security_group" "bastion" {
  name_prefix = "${local.name}-ssh-"
  vpc_id      = aws_vpc.lab.id
  ingress {
    description = "SSH desde el PC propio"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [var.ssh_cidr]
  }
  egress {
    description = "DocumentDB en las subredes privadas"
    protocol    = "tcp"
    from_port   = 27017
    to_port     = 27017
    cidr_blocks = aws_subnet.private[*].cidr_block
  }
}

# El grupo database, asignado a DocumentDB:
# - Permite entrada desde el grupo bastion.
resource "aws_security_group" "database" {
  name_prefix = "${local.name}-db-"
  vpc_id      = aws_vpc.lab.id
  ingress {
    description     = "MongoDB solo desde el bastion"
    protocol        = "tcp"
    from_port       = 27017
    to_port         = 27017
    security_groups = [aws_security_group.bastion.id]
  }
}
# Registra en AWS la clave SSH pública que se usará para acceder a la EC2 (bastion).
resource "aws_key_pair" "lab" {
  key_name_prefix = "${local.name}-"
  public_key      = trimspace(file(pathexpand(var.ssh_public_key_path)))
}
# La clave privada permanece en el computador y la usa el comando SSH.

# Crear la EC2 (bastion) en la subred pública, con IP pública y asociada al grupo bastion.
# Es el servidor que sirve de puente para acceder a DocumentDB en la subred privada.
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.linux.id
  instance_type               = "t3.micro"
  # La ubica en la subred pública.
  subnet_id                   = aws_subnet.public.id
  # Le asigna una IP pública para SSH.
  associate_public_ip_address = true
  # Aplica las reglas de acceso de `bastion`.
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = aws_key_pair.lab.key_name
  credit_specification { cpu_credits = "standard" }
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }
  tags = { Name = "${local.name}-bastion" }
}

# Agrupa las subredes que DocumentDB puede utilizar
resource "aws_docdb_subnet_group" "lab" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}
# Define parámetros del motor DocumentDB 5.0. 
# Usa TLS para usar conexiones cifradas.
resource "aws_docdb_cluster_parameter_group" "lab" {
  name   = local.name
  family = "docdb5.0"
  parameter {
    name  = "tls"
    value = "enabled"
  }
}
# Crea el cluster DocumentDB en las subredes privadas, con un usuario administrador y cifrado de datos.
resource "aws_docdb_cluster" "lab" {
  cluster_identifier              = local.name
  engine                          = "docdb"
  engine_version                  = "5.0.0"
  master_username                 = "labadmin"
  manage_master_user_password     = true
  storage_encrypted               = true
  storage_type                    = "standard"
  db_subnet_group_name            = aws_docdb_subnet_group.lab.name
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.lab.name
  vpc_security_group_ids          = [aws_security_group.database.id]
  backup_retention_period         = 1
  deletion_protection             = false
  # Laboratorio desechable: destroy elimina los datos sin snapshot final.
  skip_final_snapshot = true
  apply_immediately   = true
}
# Crea una instancia DocumentDB en el cluster, con CPU y memoria para atender conexiones y consultas.
resource "aws_docdb_cluster_instance" "lab" {
  identifier         = "${local.name}-1"
  cluster_identifier = aws_docdb_cluster.lab.id
  instance_class     = var.db_instance_class
  availability_zone  = aws_subnet.private[0].availability_zone
  depends_on         = [aws_docdb_subnet_group.lab]
  apply_immediately  = true
}

# Cluster: Organiza el almacenamiento compartido, las instancias y configuraciones como usuarios, backups, red y cifrado. 
# Instancia: Aporta CPU y memoria para atender conexiones, leer, escribir y ejecutar consultas. 
