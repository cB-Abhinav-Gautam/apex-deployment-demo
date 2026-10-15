variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags applied to every resource. Must include owner and environment to satisfy the tagging-standard policy."
  type        = map(string)
  default = {
    owner       = "abhinav.gautam"
    environment = "dev"
  }

  validation {
    condition     = can(var.tags["owner"]) && can(var.tags["environment"])
    error_message = "tags must include both an owner and an environment key."
  }
}

variable "container_image" {
  description = "Container image for phpMyAdmin. Switch to the ECR repository URL once an image has been pushed."
  type        = string
  default     = "phpmyadmin:5.2-apache"
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Number of phpMyAdmin tasks to run."
  type        = number
  default     = 1
}

variable "db_instance_class" {
  description = "RDS instance class. Performance Insights is not supported on micro/small classes."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GiB."
  type        = number
  default     = 20
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days. Must be at least 365 to satisfy the log-retention control."
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be at least 365."
  }
}

variable "enable_deletion_protection" {
  description = "Deletion protection for the ALB and the RDS instance. Must be false before a destroy run can succeed."
  type        = bool
  default     = true
}
