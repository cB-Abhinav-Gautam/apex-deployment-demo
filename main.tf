terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

data "aws_availability_zones" "available" {}

locals {
  name     = "phpmyadmin-${var.tags.environment}"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.16.0"

  name = local.name
  cidr = local.vpc_cidr

  azs              = local.azs
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]

  create_database_subnet_group = true

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = var.tags
}

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP access from internet"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  egress_rules = ["all-all"]
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.12.0"

  name = "${local.name}-alb"

  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_sg.security_group_id]

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "ecs"
      }
    }
  }

  target_groups = {
    ecs = {
      backend_protocol                  = "HTTP"
      backend_port                      = 80
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      create_attachment = false
    }
  }

  tags = var.tags
}

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "2.3.1"

  repository_name = local.name

  repository_image_tag_mutability = "MUTABLE"
  repository_force_delete         = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 10 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 10
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = var.tags
}

module "ecs_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-ecs-sg"
  description = "Security group for ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = 80
      to_port                  = 80
      protocol                 = "tcp"
      description              = "HTTP from ALB"
      source_security_group_id = module.alb_sg.security_group_id
    }
  ]
  egress_rules = ["all-all"]
}

resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_kms_key" "secrets" {
  description             = "KMS key for Secrets Manager"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = var.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${local.name}-db-password"
  recovery_window_in_days = 0
  kms_key_id              = aws_kms_key.secrets.arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result
}

module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-rds-sg"
  description = "Security group for RDS"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = 3306
      to_port                  = 3306
      protocol                 = "tcp"
      description              = "MySQL from ECS"
      source_security_group_id = module.ecs_sg.security_group_id
    }
  ]
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.10.0"

  identifier = "${local.name}-db"

  engine               = "mysql"
  engine_version       = "8.0"
  family               = "mysql8.0"
  major_engine_version = "8.0"
  instance_class       = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.secrets.arn

  db_name  = "phpmyadmin"
  username = "admin"
  password = random_password.db_password.result
  port     = 3306

  multi_az               = false
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [module.rds_sg.security_group_id]

  maintenance_window      = "Mon:00:00-Mon:03:00"
  backup_window           = "03:00-06:00"
  backup_retention_period = 7

  skip_final_snapshot = true
  deletion_protection = false

  tags = var.tags
}

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "5.12.0"

  cluster_name = local.name

  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }

  services = {
    phpmyadmin = {
      cpu    = 512
      memory = 1024

      container_definitions = {
        phpmyadmin = {
          cpu       = 512
          memory    = 1024
          essential = true
          image     = var.container_image
          port_mappings = [
            {
              name          = "phpmyadmin"
              containerPort = 80
              hostPort      = 80
              protocol      = "tcp"
            }
          ]
          environment = [
            {
              name  = "PMA_HOST"
              value = module.rds.db_instance_address
            },
            {
              name  = "PMA_PORT"
              value = tostring(module.rds.db_instance_port)
            },
            {
              name  = "PMA_USER"
              value = module.rds.db_instance_username
            }
          ]
          secrets = [
            {
              name      = "PMA_PASSWORD"
              valueFrom = aws_secretsmanager_secret.db_password.arn
            }
          ]
          log_configuration = {
            logDriver = "awslogs"
            options = {
              "awslogs-region"        = var.region
              "awslogs-group"         = "/ecs/${local.name}/phpmyadmin"
              "awslogs-stream-prefix" = "ecs"
              "awslogs-create-group"  = "true"
            }
          }
        }
      }

      subnet_ids = module.vpc.private_subnets
      security_group_rules = {
        alb_ingress = {
          type                     = "ingress"
          from_port                = 80
          to_port                  = 80
          protocol                 = "tcp"
          description              = "Service port"
          source_security_group_id = module.alb_sg.security_group_id
        }
        egress_all = {
          type        = "egress"
          from_port   = 0
          to_port     = 0
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups["ecs"].arn
          container_name   = "phpmyadmin"
          container_port   = 80
        }
      }

      tasks_iam_role_statements = {
        secrets_manager = {
          actions   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
          resources = [aws_secretsmanager_secret.db_password.arn, aws_kms_key.secrets.arn]
        }
      }
    }
  }

  tags = var.tags
}
