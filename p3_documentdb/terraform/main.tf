locals {
  name = "p3-documentdb"
}

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
resource "aws_vpc" "lab" {
  cidr_block           = "10.33.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.33.0.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${local.name}-public" }
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.33.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${local.name}-private-${count.index + 1}" }
}
# Subred creada en el intento anterior con db.t4g.medium.
# Se conserva hasta destroy para no modificar la red durante la correccion.
resource "aws_subnet" "documentdb_capacity" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.33.3.0/24"
  availability_zone = "us-east-1f"
  tags              = { Name = "${local.name}-private-capacity" }
}
resource "aws_route_table_association" "documentdb_capacity" {
  subnet_id      = aws_subnet.documentdb_capacity.id
  route_table_id = aws_route_table.private.id
}
resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
}
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
# Las privadas solo tienen la ruta local de la VPC, sin NAT ni acceso publico.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
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
    cidr_blocks = concat(aws_subnet.private[*].cidr_block, [aws_subnet.documentdb_capacity.cidr_block])
  }
}
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
resource "aws_key_pair" "lab" {
  key_name_prefix = "${local.name}-"
  public_key      = trimspace(file(pathexpand(var.ssh_public_key_path)))
}
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
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
resource "aws_docdb_subnet_group" "lab" {
  name       = local.name
  subnet_ids = concat(aws_subnet.private[*].id, [aws_subnet.documentdb_capacity.id])
}
resource "aws_docdb_cluster_parameter_group" "lab" {
  name   = local.name
  family = "docdb5.0"
  parameter {
    name  = "tls"
    value = "enabled"
  }
}
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
resource "aws_docdb_cluster_instance" "lab" {
  identifier         = "${local.name}-1"
  cluster_identifier = aws_docdb_cluster.lab.id
  instance_class     = var.db_instance_class
  availability_zone  = aws_subnet.private[0].availability_zone
  depends_on         = [aws_docdb_subnet_group.lab]
  apply_immediately  = true
}
