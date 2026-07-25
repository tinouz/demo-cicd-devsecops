output "vpc_id" {
  description = "ID du VPC créé."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID du sous-réseau public."
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "ID du security group de l'instance web."
  value       = aws_security_group.web.id
}

output "ec2_instance_id" {
  description = "ID de l'instance EC2."
  value       = aws_instance.web.id
}

output "ec2_public_ip" {
  description = "Adresse IP publique de l'instance (site accessible en HTTP)."
  value       = aws_instance.web.public_ip
}

output "site_url" {
  description = "URL du site statique."
  value       = "http://${aws_instance.web.public_ip}"
}

output "cloudwatch_log_group_name" {
  description = "Nom du log group CloudWatch contenant les logs nginx."
  value       = aws_cloudwatch_log_group.nginx.name
}

output "github_actions_role_arn" {
  description = "ARN du rôle IAM à assumer par GitHub Actions via OIDC (à utiliser dans `permissions: id-token: write` + `role-to-assume` du workflow)."
  value       = aws_iam_role.github_actions.arn
}

output "ssm_connect_command" {
  description = "Commande pour se connecter à l'instance sans SSH, via AWS SSM Session Manager."
  value       = "aws ssm start-session --target ${aws_instance.web.id} --region ${var.aws_region}"
}
