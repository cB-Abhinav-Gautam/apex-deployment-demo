data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  name     = "phpmyadmin-${var.tags["environment"]}"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)

  log_group_name = "/ecs/${local.name}/phpmyadmin"
}

################################################################################
# KMS - customer managed key used for RDS storage, the RDS master user secret,
# the ECR repository and the ECS log group.
################################################################################

data "aws_iam_policy_document" "kms" {
  # Without this the key becomes unmanageable.
  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    # A KMS key policy can only express its resource as "*", which means
    # "this key". The call is therefore constrained to principals in this
    # account so the grant cannot be exercised cross-account.
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # CloudWatch Logs must be able to use the key or the encrypted log group
  # cannot be created.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "CMK for ${local.name} (RDS, ECR, Secrets Manager, CloudWatch Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json

  tags = var.tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

################################################################################
# Network
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.16.0"

  name = local.name
  cidr = local.vpc_cidr

  azs              = local.azs
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]

  create_database_subnet_group = true

  # Fargate tasks run in the private subnets and need egress to pull the image.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Deny-all on the default security group.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Network traffic auditing.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.main.arn

  tags = var.tags
}

################################################################################
# Security groups
################################################################################

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-alb"
  description = "Ingress to the phpMyAdmin load balancer"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP from the internet"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  egress_with_source_security_group_id = [
    {
      from_port                = 80
      to_port                  = 80
      protocol                 = "tcp"
      description              = "To the phpMyAdmin tasks"
      source_security_group_id = module.ecs_sg.security_group_id
    },
  ]

  tags = var.tags
}

module "ecs_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-ecs"
  description = "phpMyAdmin Fargate tasks"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = 80
      to_port                  = 80
      protocol                 = "tcp"
      description              = "HTTP from the load balancer"
      source_security_group_id = module.alb_sg.security_group_id
    },
  ]

  # Egress to the internet is required to pull the container image and to
  # reach the Secrets Manager and ECR endpoints via the NAT gateway.
  egress_rules = ["all-all"]

  tags = var.tags
}

module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-rds"
  description = "phpMyAdmin MySQL instance"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = 3306
      to_port                  = 3306
      protocol                 = "tcp"
      description              = "MySQL from the phpMyAdmin tasks"
      source_security_group_id = module.ecs_sg.security_group_id
    },
  ]

  tags = var.tags
}

################################################################################
# Container registry
################################################################################

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "2.3.1"

  repository_name = local.name

  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true

  repository_encryption_type = "KMS"
  repository_kms_key         = aws_kms_key.main.arn

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      },
    ]
  })

  tags = var.tags
}

################################################################################
# Database
################################################################################

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.10.0"

  identifier = "${local.name}-mysql"

  engine               = "mysql"
  engine_version       = "8.0"
  family               = "mysql8.0"
  major_engine_version = "8.0"
  instance_class       = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5

  storage_encrypted = true
  kms_key_id        = aws_kms_key.main.arn

  db_name  = "phpmyadmin"
  username = "admin"
  port     = 3306

  # The master password is generated and held by AWS in Secrets Manager, so no
  # credential is ever written to Terraform state or to this repository.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.arn

  iam_database_authentication_enabled = true

  multi_az               = false
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.rds_sg.security_group_id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  backup_retention_period         = 7
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]

  auto_minor_version_upgrade = true
  deletion_protection        = var.enable_deletion_protection
  skip_final_snapshot        = true

  tags = var.tags
}

################################################################################
# Load balancer
################################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.12.0"

  name = "${local.name}-alb"

  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_sg.security_group_id]

  create_security_group = false

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true

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
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "ip"

      deregistration_delay = 30

      health_check = {
        enabled             = true
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        matcher             = "200-399"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 3
        unhealthy_threshold = 3
      }

      # ECS registers its own tasks as targets.
      create_attachment = false
    }
  }

  tags = var.tags
}

################################################################################
# Compute
################################################################################

resource "aws_cloudwatch_log_group" "phpmyadmin" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn

  tags = var.tags
}

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "5.12.0"

  cluster_name = local.name

  cluster_settings = [
    {
      name  = "containerInsights"
      value = "enabled"
    },
  ]

  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }

  services = {
    phpmyadmin = {
      cpu           = var.task_cpu
      memory        = var.task_memory
      desired_count = var.desired_count

      subnet_ids       = module.vpc.private_subnets
      assign_public_ip = false

      create_security_group = false
      security_group_ids    = [module.ecs_sg.security_group_id]

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups["ecs"].arn
          container_name   = "phpmyadmin"
          container_port   = 80
        }
      }

      container_definitions = {
        phpmyadmin = {
          image     = var.container_image
          essential = true

          port_mappings = [
            {
              name          = "phpmyadmin"
              containerPort = 80
              hostPort      = 80
              protocol      = "tcp"
            },
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
          ]

          # Pulled at task start from the AWS managed RDS secret.
          secrets = [
            {
              name      = "PMA_USER"
              valueFrom = "${module.rds.db_instance_master_user_secret_arn}:username::"
            },
            {
              name      = "PMA_PASSWORD"
              valueFrom = "${module.rds.db_instance_master_user_secret_arn}:password::"
            },
          ]

          readonly_root_filesystem = false

          enable_cloudwatch_logging = false

          log_configuration = {
            logDriver = "awslogs"
            options = {
              "awslogs-region"        = var.region
              "awslogs-group"         = aws_cloudwatch_log_group.phpmyadmin.name
              "awslogs-stream-prefix" = "ecs"
            }
          }
        }
      }

      tasks_iam_role_statements = {
        read_db_secret = {
          effect    = "Allow"
          actions   = ["secretsmanager:GetSecretValue"]
          resources = [module.rds.db_instance_master_user_secret_arn]
        }
        decrypt_db_secret = {
          effect    = "Allow"
          actions   = ["kms:Decrypt"]
          resources = [aws_kms_key.main.arn]
        }
      }

      tags = var.tags
    }
  }

  tags = var.tags
}
