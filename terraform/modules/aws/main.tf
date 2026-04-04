# Terraform module to deploy a Canton node (Participant or Validator) within an Auto Scaling Group on AWS.
# This module sets up networking, IAM roles, a launch template with Canton installation,
# and an Auto Scaling Group with an ELB health check targeting the Canton admin API.

# ---------------------------------------------------------------------------------------------------------------------
# Module Input Variables
# ---------------------------------------------------------------------------------------------------------------------

variable "name_prefix" {
  description = "A prefix used for naming all created resources."
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC where resources will be created."
  type        = string
}

variable "subnet_ids" {
  description = "A list of subnet IDs where the Canton nodes will be deployed."
  type        = list(string)
}

variable "instance_type" {
  description = "The EC2 instance type for the Canton nodes."
  type        = string
  default     = "t3.large"
}

variable "ami_id" {
  description = "The AMI ID to use for the EC2 instances. Should be an Amazon Linux 2 or similar."
  type        = string
}

variable "key_name" {
  description = "The name of the EC2 key pair to allow SSH access to the instances."
  type        = string
}

variable "kms_key_arn" {
  description = "The ARN of the AWS KMS key used for signing transactions."
  type        = string
}

variable "ssh_access_cidr" {
  description = "CIDR block to allow SSH access from."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "canton_version" {
  description = "The version of Canton Enterprise to deploy."
  type        = string
  default     = "3.1.0"
}

variable "canton_node_type" {
  description = "The type of Canton node to configure. Either 'participant' or 'validator'."
  type        = string
  default     = "participant"
  validation {
    condition     = contains(["participant", "validator"], var.canton_node_type)
    error_message = "The node type must be either 'participant' or 'validator'."
  }
}

variable "canton_node_name" {
  description = "The alias for the Canton node inside the configuration."
  type        = string
  default     = "participant1"
}

variable "canton_admin_port" {
  description = "The port for the Canton admin API."
  type        = number
  default     = 5012
}

variable "canton_public_port" {
  description = "The port for the Canton public/ledger API."
  type        = number
  default     = 5011
}

variable "asg_min_size" {
  description = "The minimum number of instances in the Auto Scaling Group."
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "The maximum number of instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "The desired number of instances in the Auto Scaling Group."
  type        = number
  default     = 1
}

variable "tags" {
  description = "A map of tags to assign to all resources."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------------------------------------------------
# Local Variables
# ---------------------------------------------------------------------------------------------------------------------

locals {
  canton_node_config_plural = var.canton_node_type == "participant" ? "participants" : "validators"
  common_tags = merge(var.tags, {
    Project = "canton-naas-reference-stack"
    Tier    = "CantonNode"
  })
}

# ---------------------------------------------------------------------------------------------------------------------
# IAM Role and Instance Profile for Canton EC2 Nodes
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "canton_node" {
  name = "${var.name_prefix}-canton-node-role"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "canton_kms_access" {
  name = "${var.name_prefix}-canton-kms-access-policy"
  role = aws_iam_role.canton_node.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action = [
          "kms:Sign",
          "kms:GetPublicKey"
        ]
        Effect   = "Allow"
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.canton_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "canton_node" {
  name = "${var.name_prefix}-canton-node-profile"
  role = aws_iam_role.canton_node.name
  tags = local.common_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# Security Group for Canton Nodes
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "canton_node" {
  name        = "${var.name_prefix}-canton-node-sg"
  description = "Security group for Canton nodes"
  vpc_id      = var.vpc_id
  tags        = local.common_tags

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_access_cidr
    description = "Allow SSH access"
  }

  ingress {
    from_port   = var.canton_public_port
    to_port     = var.canton_public_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow Canton Public/Ledger API access"
  }

  ingress {
    from_port   = var.canton_admin_port
    to_port     = var.canton_admin_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # For ELB health checks
    description = "Allow Canton Admin API access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Application Load Balancer and Target Group for Health Checks
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_lb" "canton" {
  name               = "${var.name_prefix}-canton-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.canton_node.id]
  subnets            = var.subnet_ids
  tags               = local.common_tags
}

resource "aws_lb_target_group" "canton_health_check" {
  name        = "${var.name_prefix}-canton-tg"
  port        = var.canton_admin_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"
  tags        = local.common_tags

  health_check {
    enabled             = true
    path                = "/v1/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "canton_public" {
  load_balancer_arn = aws_lb.canton.arn
  port              = var.canton_public_port
  protocol          = "TCP" # Use TCP for gRPC traffic to the Ledger API

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.canton_health_check.arn
  }
}


# ---------------------------------------------------------------------------------------------------------------------
# EC2 Launch Template with User Data
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_launch_template" "canton_node" {
  name_prefix   = "${var.name_prefix}-canton-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name
  tags          = local.common_tags

  iam_instance_profile {
    arn = aws_iam_instance_profile.canton_node.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.canton_node.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    CANTON_VERSION            = var.canton_version
    CANTON_NODE_TYPE_PLURAL   = local.canton_node_config_plural
    CANTON_NODE_NAME          = var.canton_node_name
    KMS_KEY_ARN               = var.kms_key_arn
    AWS_REGION                = data.aws_region.current.name
    ADMIN_PORT                = var.canton_admin_port
    PUBLIC_PORT               = var.canton_public_port
  }))

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_region" "current" {}

# ---------------------------------------------------------------------------------------------------------------------
# Auto Scaling Group for Canton Nodes
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_autoscaling_group" "canton" {
  name                      = "${var.name_prefix}-canton-asg"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = var.subnet_ids
  health_check_type         = "ELB"
  health_check_grace_period = 300 # Give Canton time to start and become healthy
  target_group_arns         = [aws_lb_target_group.canton_health_check.arn]

  launch_template {
    id      = aws_launch_template.canton_node.id
    version = "$Latest"
  }

  # Ensure instances are replaced if the launch template changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Module Outputs
# ---------------------------------------------------------------------------------------------------------------------

output "autoscaling_group_name" {
  description = "The name of the Canton Auto Scaling Group."
  value       = aws_autoscaling_group.canton.name
}

output "load_balancer_dns_name" {
  description = "The DNS name of the Application Load Balancer."
  value       = aws_lb.canton.dns_name
}

output "iam_role_arn" {
  description = "The ARN of the IAM role created for the Canton nodes."
  value       = aws_iam_role.canton_node.arn
}