provider "aws" {
  region = "us-east-1" 
}

data "aws_availability_zones" "available" {
  state = "available"
}

# 1. VPC y Redes
resource "aws_vpc" "neptune_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "neptune-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.neptune_vpc.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.neptune_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "neptune-public-subnet"
  }
}

resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.neptune_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "neptune-private-subnet-1"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.neptune_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "neptune-private-subnet-2"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.neptune_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_neptune_subnet_group" "default" {
  name       = "neptune-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
}

# 2. Grupos de Seguridad
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-bastion-sg"
  description = "Permitir SSH a la instancia EC2"
  vpc_id      = aws_vpc.neptune_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "neptune_sg" {
  name        = "neptune-sg"
  description = "Permitir trafico de Neptune desde EC2"
  vpc_id      = aws_vpc.neptune_vpc.id

  ingress {
    from_port       = 8182
    to_port         = 8182
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Instancia EC2 (Túnel SSH)

resource "aws_instance" "bastion" {
  ami           = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS en us-east-1
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  
  key_name = "taller-mazz-kp" 

  tags = {
    Name = "Neptune-Bastion-Host"
  }
}

# 4. Amazon Neptune (Cluster e Instancia)
resource "aws_neptune_cluster" "default" {
  cluster_identifier                  = "neptune-cluster-prueba"
  engine                              = "neptune"
  skip_final_snapshot                 = true
  iam_database_authentication_enabled = false
  apply_immediately                   = true
  vpc_security_group_ids              = [aws_security_group.neptune_sg.id]
  neptune_subnet_group_name           = aws_neptune_subnet_group.default.name
}

resource "aws_neptune_cluster_instance" "example" {
  count              = 1
  cluster_identifier = aws_neptune_cluster.default.id
  engine             = "neptune"
  instance_class     = "db.t3.medium" 
  apply_immediately  = true
}

output "ec2_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "neptune_endpoint" {
  value = aws_neptune_cluster.default.endpoint
}
