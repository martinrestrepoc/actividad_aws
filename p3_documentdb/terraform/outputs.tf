output "connection" {
  description = "Metadatos de conexion; no contiene la contrasena."
  value = {
    region     = var.aws_region
    profile    = var.aws_profile
    endpoint   = aws_docdb_cluster.lab.endpoint
    secret_arn = aws_docdb_cluster.lab.master_user_secret[0].secret_arn
    bastion_ip = aws_instance.bastion.public_ip
    bastion_id = aws_instance.bastion.id
    cluster_id = aws_docdb_cluster.lab.id
    local_port = 27018
  }
}
output "secret_read_policy" {
  description = "Politica minima para que el usuario local lea este secreto; no se adjunta automaticamente."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow", Action = ["secretsmanager:GetSecretValue"],
      Resource = aws_docdb_cluster.lab.master_user_secret[0].secret_arn
    }]
  })
}
