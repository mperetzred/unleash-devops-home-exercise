# Create an S3 bucket for storing Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "mperetz-backend"
}

# Create a DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

terraform {
  backend "s3" {
    bucket         = "mperetz-backend"
    key            = "terraform/state"
    region         = "us-east-2"
    dynamodb_table = "terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
}

# Route Table for Public Subnets
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Associate the Route Table with Public Subnets
resource "aws_route_table_association" "public_rt_assoc_1" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_rt_assoc_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# Create a VPC
resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public_subnet_1" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "Public Subnet 1"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "Public Subnet 2"
  }
}

# Create a security group
resource "aws_security_group" "app_lb" {
  name        = "unleash-devops-lb-sg"
  description = "Allow inbound traffic"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app_sg" {
  name        = "unleash-devops-sg"
  description = "Security group for ECS service allowing traffic from ALB"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    security_groups = [aws_security_group.app_lb.id]  # Replace with your ALB security group ID

    description = "Allow traffic from ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# Create an S3 bucket
resource "aws_s3_bucket" "app_bucket" {
  bucket = var.bucket_name
}

# Store the BUCKET_NAME and PORT in SSM Parameter Store
resource "aws_ssm_parameter" "bucket_name_param" {
  name  = "/unleash-devops/bucket_name"
  type  = "String"
  value = var.bucket_name
}

resource "aws_ssm_parameter" "port_param" {
  name  = "/unleash-devops/port"
  type  = "String"
  value = var.port
}

# Create an ECS Cluster
resource "aws_ecs_cluster" "app_cluster" {
  name = "unleash-devops-cluster"
}

# Data source for current AWS account ID
data "aws_caller_identity" "current" {}

# Create a user
resource "aws_iam_user" "s3_user" {
  name = "s3_bucket_user"
}

# Create an IAM policy for S3 access
resource "aws_iam_policy" "s3_bucket_access_policy" {
  name        = "S3BucketAccessPolicy"
  description = "Allows access to list and get objects in the S3 bucket"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      Resource = [
        "arn:aws:s3:::${var.bucket_name}",
        "arn:aws:s3:::${var.bucket_name}/*"
      ]
    }]
  })
}

# Attach the policy to the user
resource "aws_iam_user_policy_attachment" "s3_user_policy_attach" {
  user       = aws_iam_user.s3_user.name
  policy_arn = aws_iam_policy.s3_bucket_access_policy.arn
}

# Create access keys for the user
resource "aws_iam_access_key" "s3_user_key" {
  user = aws_iam_user.s3_user.name
}

# Store access keys in SSM Parameter Store
resource "aws_ssm_parameter" "s3_user_access_key" {
  name  = "/unleash-devops/s3_user_access_key"
  type  = "SecureString"
  value = aws_iam_access_key.s3_user_key.id
}

resource "aws_ssm_parameter" "s3_user_secret_key" {
  name  = "/unleash-devops/s3_user_secret_key"
  type  = "SecureString"
  value = aws_iam_access_key.s3_user_key.secret
}



# Task Definition for ECS
resource "aws_ecs_task_definition" "app_task" {
  family                   = "unleash-devops-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name  = "app-container"
    image = "mayape/unleash-devops-home-exercise:${var.image_tag}"
    essential = true
    portMappings = [{
      containerPort = tonumber(var.port)
      hostPort      = tonumber(var.port)
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options   = {
          "awslogs-create-group": "true",
          "awslogs-group": "awslogs-wordpress",
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
      }
    }
    environment = [
      {
        name  = "AWS_REGION"
        value = var.aws_region
      }
    ]
    secrets = [
      {
        name  = "BUCKET_NAME"
        valueFrom = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/unleash-devops/bucket_name"
      },
      {
        name  = "PORT"
        valueFrom = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/unleash-devops/port"
      },
      {
        name  = "AWS_ACCESS_KEY_ID"
        valueFrom = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/unleash-devops/s3_user_access_key"
      },
      {
        name  = "AWS_SECRET_ACCESS_KEY"
        valueFrom = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/unleash-devops/s3_user_secret_key"
      }
    ]
  }])

  tags = {
    Name = "unleash-devops-task"
  }
}

# IAM role for ECS Task
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs_task_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# IAM policy for SSM parameter access
resource "aws_iam_policy" "ssm_parameter_access_policy" {
  name        = "SSMParameterAccessPolicy"
  description = "Allows access to specific SSM parameter"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = "ssm:GetParameters",
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/unleash-devops/*"
    }]
  })
}


# Attach IAM policy to ECS task execution role
resource "aws_iam_role_policy_attachment" "ecs_task_execution_ssm_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ssm_parameter_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Service
resource "aws_ecs_service" "app_service" {
  name            = "unleash-devops-service"
  cluster         = aws_ecs_cluster.app_cluster.id
  task_definition = aws_ecs_task_definition.app_task.arn
  desired_count   = 1
  scheduling_strategy = "REPLICA"
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
    security_groups  = [aws_security_group.app_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "app-container"
    container_port   = tonumber(var.port)
  }

  depends_on = [
    aws_lb_listener.http
  ]
}

# Load Balancer
resource "aws_lb" "app_lb" {
  name               = "unleash-devops-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.app_lb.id]
  subnets            = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]

  enable_deletion_protection = false
}

# Target Group
resource "aws_lb_target_group" "app_tg" {
  name        = "unleash-devops-tg"
  port        = tonumber(var.port)
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main_vpc.id
  target_type = "ip"
}

# Load Balancer Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

output "load_balancer_dns" {
  value = aws_lb.app_lb.dns_name
}

output "bucket_name" {
  value = aws_s3_bucket.app_bucket.id
}

output "vpc_id" {
  value = aws_vpc.main_vpc.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
}
