# Requisitos de Terraform y del proveedor de AWS.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# El perfil local "default" corresponde al usuario IAM user_cli.
# Las claves se obtienen de la configuración local de AWS, no de este archivo.
provider "aws" {
  region  = var.aws_region
  profile = "default"

  default_tags {
    tags = {
      Project = "actividad-aws"
      Method  = "terraform"
    }
  }
}

# El provider es el componente que permite que Terraform se comunique con la API de AWS.

# terraform init descarga el proveedor y prepara la carpeta, Registra la versión exacta 
# seleccionada del proveedor y sus verificaciones de integridad.
