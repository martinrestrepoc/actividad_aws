variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "aws_profile" {
  type    = string
  default = "default"
}
variable "ssh_cidr" {
  description = "Tu IPv4 publica seguida de /32; unico origen autorizado para SSH."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.ssh_cidr)) && can(regex("/32$", var.ssh_cidr)) && var.ssh_cidr != "0.0.0.0/32"
    error_message = "Usa tu IPv4 publica con mascara /32."
  }
}
variable "ssh_public_key_path" {
  description = "Ruta a la clave PUBLICA SSH local (.pub). La privada nunca se envia a AWS."
  type        = string
}
variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
  validation {
    condition     = contains(["db.t3.medium", "db.t4g.medium"], var.db_instance_class)
    error_message = "Esta practica usa una instancia aprovisionada pequena: db.t3.medium o db.t4g.medium."
  }
}
