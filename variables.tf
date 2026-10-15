variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Default tags applied to all resources"
  type        = map(string)
  default = {
    owner       = "abhinav.gautam"
    environment = "dev"
  }
}

variable "container_image" {
  description = "The container image to deploy (update this to your ECR image after pushing)"
  type        = string
  default     = "phpmyadmin:5.2-apache"
}
