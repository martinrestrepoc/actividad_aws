# Los recursos: Virtual Private Cloud (VPC), subredes, grupos de seguridad, S3, EC2 y RDS.

# DATA consulta información que necesita de AWS.
# RESOURCE administra recursos.

# Consulta con qué identidad estás trabajando
data "aws_caller_identity" "current" {}

# Consulta las zonas de disponibilidad dentro de la región.
data "aws_availability_zones" "available" {
  state = "available"
  # Limita la búsqueda a zonas de disponibilidad convencionales, excluyendo otros tipos de zonas.
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

# Una AMI es la imagen utilizada para iniciar una 
# instancia: incluye el sistema operativo y su configuración inicial.

# Imagen oficial de Amazon Linux 2023 para una instancia x86_64.
# Busca la imagen para EC2
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Resuelve una versión menor disponible de PostgreSQL 17 durante el plan.
data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = var.postgres_version
  latest  = true
}

# Comprueba que la combinación de RDS sea ofrecida por AWS.
# Si no existe esa combinación, falla el plan en vez de elegir una clase más cara.
data "aws_rds_orderable_db_instance" "lab" {
  # La versión de PostgreSQL seleccionada.
  engine                      = "postgres"
  engine_version              = data.aws_rds_engine_version.postgres.version_actual
  # La clase db.t3.micro.
  instance_class              = var.db_instance_class
  # Almacenamiento gp3 (SSD de propósito general).
  storage_type                = "gp3"
  # Despliegue dentro de una VPC.
  vpc                         = true
  # Soporte para almacenamiento cifrado.
  supports_storage_encryption = true
}

# Define la VPC y sus subredes privadas. La VPC es la red virtual de AWS.
resource "aws_vpc" "lab" {
  # Espacio de direcciones privadas de la red.
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "eia-lab-terraform"
    Project = "actividad-aws"
  }

  lifecycle {
    precondition {
      condition     = can(regex(":user/(.*/)?user_cli$", data.aws_caller_identity.current.arn))
      error_message = "El perfil default debe autenticar como el usuario IAM user_cli."
    }
  }
  # La condición evita continuar con este recurso si la identidad no coincide. 
  # Está asociada a la VPC; no reemplaza los controles IAM de toda la configuración.
}


# Crea cada subred del grupo de subredes de RDS en una zona de disponibilidad distinta.

# COUNT crea dos subredes. count.index vale 0 y 1.
# RDS requiere que su grupo de subredes cubra al menos dos zonas,
# aunque despleguemos una sola instancia sin Multi-AZ.
resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.42.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "eia-lab-private-${count.index + 1}"
  }
}

# Define el grupo de seguridad de EC2, controla tráfico de las interfaces asociadas.

# Sin Internet Gateway ni NAT: las subredes usan la ruta local de la VPC.
# EC2 no recibe conexiones entrantes. Solo inicia tráfico PostgreSQL en la VPC.
resource "aws_security_group" "ec2" {
  name        = "eia-lab-terraform-ec2"
  description = "EC2: salida PostgreSQL dentro de la VPC"
  vpc_id      = aws_vpc.lab.id
  ingress     = []

  egress {
    description = "PostgreSQL privado"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.lab.cidr_block]
  }

  tags = {
    Name = "eia-lab-terraform-ec2"
  }
}

# RDS acepta conexiones PostgreSQL únicamente desde el grupo de EC2.
# Los grupos son stateful: permiten las respuestas a conexiones autorizadas.
resource "aws_security_group" "rds" {
  name        = "eia-lab-terraform-rds"
  description = "RDS: PostgreSQL desde EC2"
  vpc_id      = aws_vpc.lab.id
  egress      = []

  ingress {
    description     = "PostgreSQL desde EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  tags = {
    Name = "eia-lab-terraform-rds"
  }
}

# Define el bucket S3

# S3: bucket vacío. AWS/Terraform añade un sufijo para evitar colisiones de nombres.
# S3 no pertenece a una subred de la VPC.
resource "aws_s3_bucket" "lab" {
  bucket_prefix = "eia-lab-terraform-"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket = aws_s3_bucket.lab.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# EC2: sin IP pública, claves SSH, rol de instancia ni instalación de aplicaciones.
resource "aws_instance" "lab" {
  # La AMI que se consulto.
  ami                         = data.aws_ami.amazon_linux.id
  # El tipo t3.micro.
  instance_type               = var.ec2_instance_type
  # La primera subred.
  subnet_id                   = aws_subnet.private[0].id
  # El grupo de seguridad de EC2.
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  # Únicamente direccionamiento privado.
  associate_public_ip_address = false

  # Limita el uso de CPU para que la instancia no consuma créditos de CPU ilimitados.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  # Define el disco principal
  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "eia-lab-terraform-ec2"
  }
}

# Define el grupo de subredes de RDS con las subredes ya creadas.
resource "aws_db_subnet_group" "lab" {
  name       = "eia-lab-terraform"
  # recoge los IDs de todas las subredes creadas por ese bloque
  subnet_ids = aws_subnet.private[*].id
}

# Define la instancia RDS
resource "aws_db_instance" "lab" {
  identifier     = "eia-lab-terraform"
  engine         = "postgres"
  engine_version = data.aws_rds_engine_version.postgres.version_actual
  instance_class = data.aws_rds_orderable_db_instance.lab.instance_class
  db_name        = "actividad"
  username       = "labadmin"
  port           = 5432

  # RDS genera y guarda la contraseña. Terraform no recibe su valor.
  manage_master_user_password = true

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.lab.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  # Configuración DESECHABLE para la práctica: al destruir se pierden los datos.
  backup_retention_period  = 0
  skip_final_snapshot      = true
  delete_automated_backups = true
  deletion_protection      = false

  monitoring_interval          = 0
  performance_insights_enabled = false
  engine_lifecycle_support     = "open-source-rds-extended-support-disabled"

  tags = {
    Name = "eia-lab-terraform-rds"
  }
}
