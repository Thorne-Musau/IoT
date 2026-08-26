output "ecs_cluster_name" {
  description = "Name of the ECS cluster running the pilot Fargate service."
  value       = aws_ecs_cluster.app.name
}

output "ecs_service_name" {
  description = "Name of the Fargate service running the umbrella app."
  value       = aws_ecs_service.app.name
}

output "task_role_arn" {
  description = "ARN of the least-privilege IAM role assumed by the running task."
  value       = aws_iam_role.task.arn
}

output "db_endpoint" {
  description = "Connection endpoint of the RDS Postgres instance."
  value       = aws_db_instance.app.endpoint
}

output "db_name" {
  description = "Name of the PostgreSQL database."
  value       = aws_db_instance.app.db_name
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate issued for the domain."
  value       = aws_acm_certificate.app.arn
}
