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
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Bucket S3 para los datos y para los resultados de Athena
resource "aws_s3_bucket" "glue_data_bucket" {
  bucket_prefix = "glue-taller-datos-"
  force_destroy = true
}

resource "aws_s3_bucket" "athena_results" {
  bucket_prefix = "athena-taller-resultados-"
  force_destroy = true
}

# 2. Base de datos de AWS Glue Catalog
resource "aws_glue_catalog_database" "taller_db" {
  name = "ventas_taller_db"
}

# 3. Rol de IAM para el Crawler de Glue
resource "aws_iam_role" "glue_crawler_role" {
  name = "GlueCrawlerRoleTallerP6"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })
}

# Darle permiso a Glue de leer nuestro Bucket y permisos de servicio Glue
resource "aws_iam_role_policy_attachment" "glue_service_policy" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_policy" {
  name = "GlueS3Access"
  role = aws_iam_role.glue_crawler_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = [
        aws_s3_bucket.glue_data_bucket.arn,
        "${aws_s3_bucket.glue_data_bucket.arn}/*"
      ]
    }]
  })
}

# 4. AWS Glue Crawler
resource "aws_glue_crawler" "ventas_crawler" {
  database_name = aws_glue_catalog_database.taller_db.name
  name          = "ventas_crawler_taller"
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.glue_data_bucket.bucket}/datos_ventas/"
  }
}

# 5. Output config para Python
resource "local_file" "config_json" {
  content = jsonencode({
    S3_DATA_BUCKET    = aws_s3_bucket.glue_data_bucket.bucket
    S3_ATHENA_BUCKET  = aws_s3_bucket.athena_results.bucket
    GLUE_DB           = aws_glue_catalog_database.taller_db.name
    CRAWLER_NAME      = aws_glue_crawler.ventas_crawler.name
    REGION            = "us-east-1"
  })
  filename = "${path.module}/config.json"
}
