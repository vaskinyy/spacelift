# providers
provider "aws" {
  version = "~> 2.0"
  region = "eu-west-2"
}

terraform {
  required_providers {
    spacelift = {
      source = "spacelift.io/spacelift-io/spacelift"
    }
  }
}

# ECR
resource "aws_ecr_repository" "spacelift" {
  name = "spacelift"
}

# ECS

# Providing a reference to our default VPC
resource "aws_default_vpc" "default_vpc" {
}

# Providing a reference to our default subnets
resource "aws_default_subnet" "default_subnet_a" {
  availability_zone = "eu-west-2a"
}

resource "aws_default_subnet" "default_subnet_b" {
  availability_zone = "eu-west-2b"
}

resource "aws_default_subnet" "default_subnet_c" {
  availability_zone = "eu-west-2c"
}

resource "aws_ecs_cluster" "spacelift_cluster" {
  name = "spacelift-cluster" # Naming the cluster
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_alb" "application_load_balancer" {
  name               = "test-lb-tf" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    "${aws_default_subnet.default_subnet_a.id}",
    "${aws_default_subnet.default_subnet_b.id}",
    "${aws_default_subnet.default_subnet_c.id}"
  ]
  # Referencing the security group
  security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
}

# Creating a security group for the load balancer:
resource "aws_security_group" "load_balancer_security_group" {
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic in from all sources
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${aws_default_vpc.default_vpc.id}" # Referencing the default VPC
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = "${aws_alb.application_load_balancer.arn}" # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.target_group.arn}" # Referencing our tagrte group
  }
}

resource "aws_security_group" "service_security_group" {
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the load balancer security group
    security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# CloudFormation

locals {

  task_definition_properties = {
    Family = "spacelift-task"
    ContainerDefinitions = [
      {
        Name                   = "spacelift-task"
        Image                  = {"Ref" : "Image" }
        Essential              = true
        PortMappings           = [
          {
            ContainerPort: 8080,
            HostPort: 8080
          }
        ]
        Memory                 = 512
        Cpu                    = 256
      }
    ]
    RequiresCompatibilities = ["FARGATE"]
    NetworkMode = "awsvpc",
    Memory = "512"
    Cpu = "256"
    ExecutionRoleArn = aws_iam_role.ecsTaskExecutionRole.arn
  }


  service_properties = {
    ServiceName = "spacelift-service"
    Cluster = aws_ecs_cluster.spacelift_cluster.id
    TaskDefinition = { "Ref" = "TaskDefinition" }
    LaunchType = "FARGATE"
    DesiredCount = 1

    LoadBalancers = [
      {
        TargetGroupArn = aws_lb_target_group.target_group.arn
        ContainerName = "spacelift-task"
        ContainerPort = "8080"
      }
    ]
    NetworkConfiguration = {
      "AwsvpcConfiguration" = {
        "Subnets"        = [aws_default_subnet.default_subnet_a.id, aws_default_subnet.default_subnet_b.id, aws_default_subnet.default_subnet_c.id]
        "AssignPublicIp" = "ENABLED"
        "SecurityGroups" = [aws_security_group.service_security_group.id]
      }
    }
  }

  resources = {
    ECSService = {
      Type       = "AWS::ECS::Service"
      Properties = local.service_properties
    }
    TaskDefinition = {
      Type = "AWS::ECS::TaskDefinition"
      Properties = local.task_definition_properties
    }
  }

  parameters = {
    Image : {
      "Type" : "String",
      "Default" : "${aws_ecr_repository.spacelift.repository_url}:dev-24ce50e5b1ac2ea4f7bbe4ccd4c0bf906c60340a",
      "Description" : "Image to be deployed."
    }
  }

  # https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ecs-service.html#cfn-ecs-service-cluster
  cloudformation_definition = {
    Conditions = {}
    Resources  = local.resources
    Parameters = local.parameters
    Outputs    = {}
  }

  cloudformation_definition_json_map = jsonencode(local.cloudformation_definition)
}


resource "aws_cloudformation_stack" "app" {
  name          = "SpaceliftServiceDeployment"
  template_body = local.cloudformation_definition_json_map
}
