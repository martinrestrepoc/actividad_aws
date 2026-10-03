terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Contraseña aleatoria 
resource "random_password" "db_password" {
  length           = 16
  special          = true
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# 2. AWS Secrets Manager
resource "aws_secretsmanager_secret" "redshift_secret" {
  name                    = "redshift-admin-secret-test-p5"
  recovery_window_in_days = 0 
}

resource "aws_secretsmanager_secret_version" "redshift_secret_version" {
  secret_id     = aws_secretsmanager_secret.redshift_secret.id
  secret_string = jsonencode({
    username = "adminuser"
    password = random_password.db_password.result
  })
}

# 3. Rol de IAM para Redshift 
resource "aws_iam_role" "redshift_s3_role" {
  name = "redshift_s3_read_role_p5_serverless"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "redshift.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "s3_read_only" {
  role       = aws_iam_role.redshift_s3_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# 4. Bucket de S3
resource "aws_s3_bucket" "data_bucket" {
  bucket_prefix = "redshift-data-taller-"
  force_destroy = true
}

# 5. Redshift Serverless (Namespace y Workgroup)
resource "aws_redshiftserverless_namespace" "namespace" {
  namespace_name      = "taller-redshift-ns"
  admin_username      = "adminuser"
  admin_user_password = random_password.db_password.result
  iam_roles           = [aws_iam_role.redshift_s3_role.arn]
}

resource "aws_redshiftserverless_workgroup" "workgroup" {
  namespace_name = aws_redshiftserverless_namespace.namespace.namespace_name
  workgroup_name = "taller-redshift-wg"
  base_capacity  = 8
  publicly_accessible = true
}

# 6. Auto-configuración para Python
resource "local_file" "config_json" {
  content = jsonencode({
    S3_BUCKET    = aws_s3_bucket.data_bucket.bucket
    WORKGROUP    = aws_redshiftserverless_workgroup.workgroup.workgroup_name
    DATABASE     = "dev" # Serverless usa la base de datos 'dev' por defecto
    SECRET_ARN   = aws_secretsmanager_secret.redshift_secret.arn
    IAM_ROLE_ARN = aws_iam_role.redshift_s3_role.arn
    REGION       = "us-east-1"
  })
  filename = "${path.module}/config.json"
}
