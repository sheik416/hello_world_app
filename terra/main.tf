data "aws_availability_zones" "available_zones" {
  state = "available"
}

## add the resource definition
resource "aws_vpc" "default" {
  cidr_block = "10.32.0.0/16"
}

## Add the subnet resource definitions

resource "aws_subnet" "public" {
  count                   = 2
  cidr_block              = cidrsubnet(aws_vpc.default.cidr_block, 8, 2 + count.index)
  availability_zone       = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id                  = aws_vpc.default.id
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.default.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id            = aws_vpc.default.id
}

## six networking resources with the following blocks

resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.default.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gateway.id
}

resource "aws_eip" "gateway" {
  count      = 2
  vpc        = true
  depends_on = [aws_internet_gateway.gateway]
}

resource "aws_nat_gateway" "gateway" {
  count         = 2
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.gateway.*.id, count.index)
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gateway.*.id, count.index)
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

##  load balancer security group resource 

resource "aws_security_group" "lb" {
  name   = "example-alb-security-group"
  vpc_id = aws_vpc.default.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

## three resources for the load balancer 
resource "aws_lb" "default" {
  name            = "example-lb"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.lb.id]
}

resource "aws_lb_target_group" "hello_world" {
  name        = "example-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.default.id
  target_type = "ip"
}

resource "aws_lb_listener" "hello_world" {
  load_balancer_arn = aws_lb.default.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.hello_world.id
    type             = "forward"
  }
}

##  ECS cluster

resource "aws_ecs_task_definition" "hello_world" {
  family                   = "hello-world-app"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048

  container_definitions = <<DEFINITION
[
  {
    "image": "349896756653.dkr.ecr.us-east-2.amazonaws.com/nodejs:nodejs_simple_app",
    "cpu": 1024,
    "memory": 2048,
    "name": "hello-world-app",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80
      }
    ]
  }
]
DEFINITION
}

# IAM ROLE

resource "aws_iam_role" "ecs_task_execution" {
  name = "ecs_task_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Create a custom IAM policy with full access to ECS and ECR
data "aws_iam_policy_document" "ecs_full_access_policy" {
  statement {
    effect = "Allow"
    actions = [
      "ecs:*",
      "ecr:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_full_access" {
  name        = "ECSFullAccessPolicy"
  description = "Policy granting full access to ECS and ECR"
  policy      = data.aws_iam_policy_document.ecs_full_access_policy.json
}

# Attach the custom policy to the ecs_task_execution role
resource "aws_iam_role_policy_attachment" "ecs_full_access_attachment" {
  policy_arn = aws_iam_policy.ecs_full_access.arn
  role       = aws_iam_role.ecs_task_execution.name
}

## security group for the ECS service

resource "aws_security_group" "hello_world_task" {
  name   = "example-task-security-group"
  vpc_id = aws_vpc.default.id

  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

## ECS service and cluster blocks

resource "aws_ecs_cluster" "main" {
  name = "example-cluster"
}

resource "aws_ecs_service" "hello_world" {
  name            = "hello-world-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hello_world.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.hello_world_task.id]
    subnets         = aws_subnet.private.*.id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hello_world.id
    container_name   = "hello-world-app"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.hello_world]
}

# Create a new VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # Replace with your desired VPC CIDR block
  tags = {
    Name = "Main VPC"
  }
}

# Create a private subnet within the VPC
resource "aws_subnet" "private_subnet_a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.10.0/24" # Replace with your desired subnet CIDR block
  availability_zone = "us-east-2a" # Replace with your desired availability zone

  tags = {
    Name = "Private Subnet"
  }
}

# Create another private subnet within the VPC in us-east-2b (replace with your desired availability zones)
resource "aws_subnet" "private_subnet_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.20.0/24" # Replace with your desired subnet CIDR block
  availability_zone = "us-east-2b"

  tags = {
    Name = "Private Subnet B"
  }
}

# Create a security group to allow RDS MySQL traffic from within the VPC
resource "aws_security_group" "rds_security_group" {
  name_prefix = "rds_security_group_"

  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create a DB subnet group for the private subnets
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "my-rds-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_a.id, aws_subnet.private_subnet_b.id]
}

# Create an RDS MySQL instance in the private subnet
resource "aws_db_instance" "rds_mysql" {
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  identifier           = "my-rds-mysql-instance"
  db_name              = "mydb"
  username             = "dbadmin"
  password             = "dbpassword" # Replace with your desired password

  vpc_security_group_ids = [aws_security_group.rds_security_group.id]

  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name

  apply_immediately = true
}

# Create VPC peering between the new VPC and default VPC
resource "aws_vpc_peering_connection" "peer" {
  peer_vpc_id      = data.aws_vpc.default.id
  vpc_id           = aws_vpc.main.id
  auto_accept      = true
}

# Create a route in the new VPC's route table to route traffic to the default VPC via VPC peering
resource "aws_route" "peer_route" {
  route_table_id            = aws_vpc.main.default_route_table_id
  destination_cidr_block    = data.aws_vpc.default.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
}

data "aws_vpc" "default" {
  default = true
}
