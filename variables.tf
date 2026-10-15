###############################################################################
# General
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy the phpMyAdmin platform into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix for all resource names."
  type        = string
  default     = "phpmyadmin"
}

variable "environment" {
  description = "Deployment environment. Applied as the required 'environment' tag."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owning team or individual. Applied as the required 'owner' tag."
  type        = string
  default     = "abhinav.gautam"
}

variable "additional_tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "Retention in days for all CloudWatch log groups created by this stack."
  type        = number
  default     = 30
}

###############################################################################
# Networking
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be between 2 and 3."
  }
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway. Cheaper for non-production; set to false for HA egress."
  type        = bool
  default     = true
}

variable "allowed_ingress_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the phpMyAdmin load balancer.
    phpMyAdmin is a database administration console and must NOT be exposed to
    the public internet. Set this to your office or VPN egress range.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

###############################################################################
# Container / ECS
###############################################################################

variable "container_image" {
  description = <<-EOT
    Container image for phpMyAdmin. Defaults to the upstream image so the stack
    is usable immediately. Switch this to the ECR repository URL created by this
    stack once you have pushed your own build of cB-Abhinav-Gautam/phpmyadmin.
  EOT
  type        = string
  default     = "phpmyadmin:5.2-apache"
}

variable "container_port" {
  description = "Port the phpMyAdmin container listens on."
  type        = number
  default     = 80
}

variable "task_cpu" {
  description = "Fargate task CPU units (512 = 0.5 vCPU)."
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

variable "upload_limit" {
  description = "PHP upload_max_filesize / post_max_size for phpMyAdmin imports."
  type        = string
  default     = "64M"
}

###############################################################################
# Database
###############################################################################

variable "db_name" {
  description = "Name of the initial database created on the MySQL instance."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for the MySQL instance."
  type        = string
  default     = "dbadmin"
}

variable "db_port" {
  description = "Port the MySQL instance listens on."
  type        = number
  default     = 3306
}

variable "db_engine_version" {
  description = "MySQL engine version."
  type        = string
  default     = "8.0"
}

variable "db_family" {
  description = "RDS parameter group family."
  type        = string
  default     = "mysql8.0"
}

variable "db_major_engine_version" {
  description = "RDS option group major engine version."
  type        = string
  default     = "8.0"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper bound for RDS storage autoscaling in GiB."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Run the MySQL instance across multiple availability zones."
  type        = bool
  default     = true
}

variable "db_backup_retention_period" {
  description = "Number of days to retain automated backups."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Prevent the database from being destroyed by Terraform."
  type        = bool
  default     = true
}
