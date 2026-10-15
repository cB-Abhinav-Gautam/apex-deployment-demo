output "alb_dns_name" {
  description = "Public DNS name of the phpMyAdmin load balancer."
  value       = module.alb.dns_name
}

output "phpmyadmin_url" {
  description = "URL to reach phpMyAdmin."
  value       = "http://${module.alb.dns_name}/"
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets running the Fargate tasks."
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "IDs of the isolated database subnets."
  value       = module.vpc.database_subnets
}

output "ecr_repository_url" {
  description = "ECR repository URL for a custom phpMyAdmin image."
  value       = module.ecr.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = module.ecs.cluster_name
}

output "db_instance_endpoint" {
  description = "Connection endpoint of the MySQL instance."
  value       = module.rds.db_instance_endpoint
}

output "db_master_user_secret_arn" {
  description = "ARN of the AWS managed Secrets Manager secret holding the MySQL master credentials."
  value       = module.rds.db_instance_master_user_secret_arn
}

output "kms_key_arn" {
  description = "ARN of the customer managed key protecting RDS, ECR and the log group."
  value       = aws_kms_key.main.arn
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group receiving phpMyAdmin container logs."
  value       = aws_cloudwatch_log_group.phpmyadmin.name
}
