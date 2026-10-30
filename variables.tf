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
  description = "Container image for phpMyAdmin. Leave empty to use the ECR repository created by this stack. The tasks have no internet egress, so a Docker Hub reference will not pull - mirror the image into ECR first."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Image tag to deploy from the ECR repository when container_image is empty."
  type        = string
  default     = "latest"
}

variable "domain_name" {
  description = "Fully qualified domain name served by the load balancer. Used for the ACM certificate when certificate_arn is empty."
  type        = string
  default     = "appevolve.intuitive.ai"
}

variable "certificate_arn" {
  description = "ARN of an existing ACM certificate. Leave empty to create one for domain_name."
  type        = string
  default     = ""
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks permitted to reach the internal load balancer. Defaults to the VPC itself; widen to your VPN or peered ranges as needed."
  type        = list(string)
  default     = ["10.0.0.0/16"]
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
