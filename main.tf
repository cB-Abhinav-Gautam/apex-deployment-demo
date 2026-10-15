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

  certificate_arn = var.certificate_arn != "" ? var.certificate_arn : aws_acm_certificate.this[0].arn

  # The ECR repository URL is fully deterministic, so it is built from the
  # account and region rather than read from the module output. The module
  # output is only known after apply, which would make the ECS module's
  # container_definitions for_each keys unknown at plan time.
  ecr_repository_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${local.name}"

  # The tasks have no route to the internet, so the image must come from the
  # ECR repository created below unless an explicit reference is supplied.
  container_image = var.container_image != "" ? var.container_image : "${local.ecr_repository_url}:${var.image_tag}"

  # The RDS module returns these through try(), which produces an unknown of
  # dynamic type. Feeding that into the ECS module's any-typed services
  # variable makes the whole container_definitions map unknown at plan time
  # and breaks its for_each. tostring() pins the type so only the value is
  # unknown, which for_each tolerates.
  db_address    = tostring(module.rds.db_instance_address)
  db_port       = tostring(module.rds.db_instance_port)
  db_secret_arn = tostring(module.rds.db_instance_master_user_secret_arn)

  # Same treatment for the other module outputs consumed by the ECS service.
  # The security-group module returns try(...) over several candidates, which
  # is likewise a dynamically typed unknown.
  ecs_security_group_id = tostring(module.ecs_sg.security_group_id)
  ecs_target_group_arn  = tostring(module.alb.target_groups["ecs"].arn)
  ecs_subnet_ids        = [for s in module.vpc.private_subnets : tostring(s)]
}

################################################################################
# KMS - customer managed key used for RDS storage, the RDS master user secret,
# the ECR repository and the CloudWatch log groups.
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
# TLS certificate
#
# DNS validation records must be published in the appevolve.intuitive.ai zone
# before the certificate issues; the listener cannot attach an unissued
# certificate. The validation records are exposed as an output.
################################################################################

resource "aws_acm_certificate" "this" {
  count = var.certificate_arn == "" ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

################################################################################
# Network
#
# No NAT gateway and no internet route from the private subnets. Everything the
# tasks need (ECR, Secrets Manager, CloudWatch Logs, S3) is reached over VPC
# endpoints, which is what allows the 0.0.0.0/0 egress rule to be removed.
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

  enable_nat_gateway = false

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

# The VPC endpoints are declared as native resources rather than through
# terraform-aws-modules/vpc/aws//modules/vpc-endpoints. The Apex module
# registry matches approved sources by exact string and cannot represent a
# "//modules/..." submodule path, so the module form is rejected by the
# governance stage. These resources are what that module would have created.

locals {
  # Interface endpoints reached by the tasks over HTTPS. Key is the local
  # name, value is the AWS service short name.
  interface_endpoints = {
    ecr_api        = "ecr.api"
    ecr_dkr        = "ecr.dkr"
    secretsmanager = "secretsmanager"
    logs           = "logs"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.tags, { Name = "${local.name}-s3" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [module.vpc_endpoints_sg.security_group_id]

  # Lets the tasks use the ordinary public service hostnames and have them
  # resolve to the endpoint ENIs inside the VPC.
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${local.name}-${replace(each.key, "_", "-")}" })
}

################################################################################
# Security groups
#
# Dependency order is strictly alb_sg -> ecs_sg -> {rds_sg, vpc_endpoints_sg}.
# Egress is expressed with CIDRs scoped to the VPC rather than peer security
# groups, which keeps the graph acyclic and avoids any 0.0.0.0/0 rule.
################################################################################

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-alb"
  description = "Internal load balancer for phpMyAdmin"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS from permitted internal ranges"
      cidr_blocks = join(",", var.allowed_cidr_blocks)
    },
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP from permitted internal ranges, redirected to HTTPS"
      cidr_blocks = join(",", var.allowed_cidr_blocks)
    },
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "To the phpMyAdmin tasks"
      cidr_blocks = local.vpc_cidr
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

  egress_with_cidr_blocks = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "To the ECR, Secrets Manager and CloudWatch Logs VPC endpoints"
      cidr_blocks = local.vpc_cidr
    },
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "To the MySQL instance"
      cidr_blocks = local.vpc_cidr
    },
  ]

  tags = var.tags
}

module "vpc_endpoints_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.name}-vpc-endpoints"
  description = "Interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = 443
      to_port                  = 443
      protocol                 = "tcp"
      description              = "HTTPS from the phpMyAdmin tasks"
      source_security_group_id = module.ecs_sg.security_group_id
    },
  ]

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
# Load balancer - internal, HTTPS only
################################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.12.0"

  name = "${local.name}-alb"

  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id

  # Internal: a database administration console is not exposed to the
  # internet. Reachable over VPN or from peered networks only.
  internal = true
  subnets  = module.vpc.private_subnets

  security_groups       = [module.alb_sg.security_group_id]
  create_security_group = false

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true

  listeners = {
    http_redirect = {
      port     = 80
      protocol = "HTTP"

      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    https = {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      certificate_arn = local.certificate_arn

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

  # The cluster only. The task definition and service are declared natively
  # below: this module routes container_definitions through
  # try(each.value.container_definitions, {}), which collapses to a
  # dynamically typed unknown as soon as any value inside is not known at
  # plan time. The RDS endpoint and the AWS managed secret ARN both carry
  # generated suffixes, so they can never be known during plan, and the
  # module's inner for_each then fails with "Invalid for_each argument".
  create_cloudwatch_log_group = false

  tags = var.tags
}

################################################################################
# Task execution role - used by the ECS agent to pull the image and inject
# secrets. Scoped to this stack's key and secret rather than wildcards.
################################################################################

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    sid     = "ECSTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "task_exec" {
  name               = "${local.name}-task-exec"
  description        = "Task execution role for ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "task_exec_managed" {
  role       = aws_iam_role.task_exec.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_exec" {
  statement {
    sid       = "ReadDatabaseSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.db_secret_arn]
  }

  statement {
    sid    = "DecryptWithStackKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "task_exec" {
  name   = "${local.name}-task-exec"
  role   = aws_iam_role.task_exec.id
  policy = data.aws_iam_policy_document.task_exec.json
}

################################################################################
# Task role - the application itself calls no AWS APIs, so it carries no
# permissions. It exists so the task has a distinct identity from the agent.
################################################################################

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  description        = "Task role for ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = var.tags
}

################################################################################
# Task definition and service
################################################################################

resource "aws_ecs_task_definition" "phpmyadmin" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "phpmyadmin"
      image     = local.container_image
      essential = true

      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        },
      ]

      environment = [
        {
          name  = "PMA_HOST"
          value = local.db_address
        },
        {
          name  = "PMA_PORT"
          value = local.db_port
        },
      ]

      # Injected by the agent from the AWS managed RDS secret.
      secrets = [
        {
          name      = "PMA_USER"
          valueFrom = "${local.db_secret_arn}:username::"
        },
        {
          name      = "PMA_PASSWORD"
          valueFrom = "${local.db_secret_arn}:password::"
        },
      ]

      # The root filesystem is read only. Everything the image needs to write
      # is mounted as a writable ephemeral volume below.
      readonlyRootFilesystem = true

      mountPoints = [
        {
          sourceVolume  = "tmp"
          containerPath = "/tmp"
          readOnly      = false
        },
        {
          sourceVolume  = "sessions"
          containerPath = "/sessions"
          readOnly      = false
        },
        {
          sourceVolume  = "apache-run"
          containerPath = "/var/run/apache2"
          readOnly      = false
        },
        {
          sourceVolume  = "apache-lock"
          containerPath = "/var/lock/apache2"
          readOnly      = false
        },
        {
          sourceVolume  = "pma-tmp"
          containerPath = "/var/www/html/tmp"
          readOnly      = false
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
  ])

  # Writable ephemeral volumes backing the read only root filesystem.
  # Fargate provisions these from the task's ephemeral storage.
  volume {
    name = "tmp"
  }

  volume {
    name = "sessions"
  }

  volume {
    name = "apache-run"
  }

  volume {
    name = "apache-lock"
  }

  volume {
    name = "pma-tmp"
  }

  tags = var.tags
}

resource "aws_ecs_service" "phpmyadmin" {
  name            = local.name
  cluster         = module.ecs.cluster_id
  task_definition = aws_ecs_task_definition.phpmyadmin.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.ecs_subnet_ids
    security_groups  = [local.ecs_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = local.ecs_target_group_arn
    container_name   = "phpmyadmin"
    container_port   = 80
  }

  # The target group must be attached to a listener before the service can
  # register targets against it.
  depends_on = [module.alb]

  tags = var.tags
}
