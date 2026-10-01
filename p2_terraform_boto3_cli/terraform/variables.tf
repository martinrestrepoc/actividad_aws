# Valores configurables, como la región y el tamaño de las instancias.

variable "aws_region" {
  description = "Región de AWS autorizada por la política IAM de la actividad"
  type        = string
  default     = "us-east-1"
}

variable "ec2_instance_type" {
  description = "Tipo de instancia EC2 x86_64; el ejemplo usa créditos de CPU standard"
  type        = string
  default     = "t3.micro"
}

variable "db_instance_class" {
  description = "Clase de RDS; se comprueba su disponibilidad durante el plan"
  type        = string
  default     = "db.t3.micro"
}

variable "postgres_version" {
  description = "Versión mayor de PostgreSQL, o versión exacta para repetir el despliegue"
  type        = string
  default     = "17"
}
