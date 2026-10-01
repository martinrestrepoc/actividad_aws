# Valores útiles para comprobar el despliegue. No exponemos contraseñas.
# Los datos que queremos mostrar al finalizar, como los identificadores de los recursos.


output "caller_arn" {
  description = "Identidad AWS con la que se consultó el despliegue"
  value       = data.aws_caller_identity.current.arn
}

output "vpc_id" {
  description = "Identificador de la VPC creada para la práctica"
  value       = aws_vpc.lab.id
}

output "subnet_ids" {
  description = "Identificadores de las dos subredes privadas"
  value       = aws_subnet.private[*].id
}

output "bucket_name" {
  description = "Nombre globalmente único del bucket S3"
  value       = aws_s3_bucket.lab.id
}

output "ec2_instance_id" {
  description = "ID de EC2 para consultar su estado"
  value       = aws_instance.lab.id
}

output "ec2_private_ip" {
  description = "IP privada de EC2; no es accesible directamente desde el PC"
  value       = aws_instance.lab.private_ip
}

output "ec2_ami_id" {
  description = "AMI seleccionada; conservarla para comparar con Boto3 y CLI"
  value       = aws_instance.lab.ami
}

output "rds_identifier" {
  description = "Identificador de RDS para consultar su estado"
  value       = aws_db_instance.lab.identifier
}

output "rds_endpoint" {
  description = "Endpoint privado de PostgreSQL, con puerto"
  value       = aws_db_instance.lab.endpoint
}

output "rds_engine_version" {
  description = "Versión de PostgreSQL resuelta para repetirla en Boto3 y CLI"
  value       = aws_db_instance.lab.engine_version_actual
}

output "rds_secret_arn" {
  description = "Referencia al secreto administrado por RDS; NO es su contraseña"
  value       = aws_db_instance.lab.master_user_secret[0].secret_arn
}
