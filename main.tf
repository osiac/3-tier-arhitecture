
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.16.0"

  name = "filiposiac-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  private_subnets = ["10.0.201.0/24", "10.0.202.0/24"]
}

resource "aws_eip" "nat_eip" {
  vpc = true
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = module.vpc.public_subnets[0]  

  depends_on = [
    aws_eip.nat_eip  
  ]
}

resource "aws_route_table" "private_route_table" {
  vpc_id = module.vpc.vpc_id
}

resource "aws_route" "private_route" {
  route_table_id         = aws_route_table.private_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gateway.id
  depends_on = [
    aws_nat_gateway.nat_gateway  
  ]
}

# Security Group 
resource "aws_security_group" "filiposiac_sg" {
  name        = "filiposiac-sg"
  description = "Allow HTTP and SSH access"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  ingress {
    from_port   = 22
    to_port     = 22
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


resource "aws_key_pair" "filiposiac_key" {
  key_name   = var.key_pair_name
  public_key = file(var.public_key_path)
}

# Backend
data "template_file" "nginx_backend" {
  template = <<EOF
#!/bin/bash
apt update -y && apt upgrade -y
apt install -y nginx
IP_PUBLIC=$(curl -s ifconfig.me)
index="<html><body><h1>Instanta EC2 ruleaza pe IP-ul: $IP_PUBLIC</h1></body></html>"
echo $index > /var/www/html/index.html
systemctl start nginx
systemctl enable nginx
EOF
}

# Template pentru Nginx
data "template_file" "nginx_frontend" {
  template = <<EOF
#!/bin/bash
apt update -y && apt upgrade -y
apt install -y nginx
IP_PUBLIC=$(curl -s ifconfig.me)
index="<html><body><h1>Instanta EC2 ruleaza pe IP-ul: $IP_PUBLIC</h1></body></html>"
echo $index > /var/www/html/index.html
systemctl start nginx
systemctl enable nginx
EOF
}

# Launch Template pentru EC2 (backend)
resource "aws_launch_template" "filiposiac_templateEc2_backend" {
  name          = "filiposiac-templateEc2-backend"
  image_id      = "ami-0866a3c8686eaeeba"  
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = false  
    security_groups             = [aws_security_group.filiposiac_sg.id]
  }

  key_name = aws_key_pair.filiposiac_key.key_name

  user_data = "${base64encode(data.template_file.nginx_backend.rendered)}"
}

# Launch Template pentru EC2 (frontend)
resource "aws_launch_template" "filiposiac_templateEc2_frontend" {
  name          = "filiposiac-templateEc2-frontend"
  image_id      = "ami-0866a3c8686eaeeba"  
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.filiposiac_sg.id]
  }

  key_name = aws_key_pair.filiposiac_key.key_name
  user_data = "${base64encode(data.template_file.nginx_frontend.rendered)}"
}

# Auto Scaling Group pentru instanțele EC2 în subneturile private
resource "aws_autoscaling_group" "filiposiac_asg_backend" {
  name                = "filiposiac-asg-backend"
  max_size            = 3
  min_size            = 1
  desired_capacity    = 2
  vpc_zone_identifier = module.vpc.private_subnets 

  launch_template {
    id      = aws_launch_template.filiposiac_templateEc2_backend.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.filiposiac_tg_backend.arn] 

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "filiposiac_ec2_backend"
    propagate_at_launch = true
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "filiposiac_asg" {
  name                = "filiposiac-asg"
  max_size            = 3
  min_size            = 1
  desired_capacity    = 2
  vpc_zone_identifier = module.vpc.public_subnets

  launch_template {
    id      = aws_launch_template.filiposiac_templateEc2_frontend.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.filiposiac_tg1.arn]  

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "filiposiac_ec2_frontend"
    propagate_at_launch = true
  }
}

# Load Balancer
resource "aws_lb" "filiposiac_lb" {
  name               = "filiposiac-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.filiposiac_sg.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false
}
# Load Balancer
resource "aws_lb" "filiposiac_lb_backend" {
  name               = "filiposiac-lb-backend"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.filiposiac_sg.id]
  subnets            = module.vpc. private_subnets

  enable_deletion_protection = false
}
# Target Group pentru Load Balancer-Frontend
resource "aws_lb_target_group" "filiposiac_tg1" {
  name     = "filiposiac-tg1"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    protocol             = "HTTP"
    path                 = "/"
    interval             = 30
    timeout              = 5
    healthy_threshold    = 3
    unhealthy_threshold  = 3
  }
}

# Target Group pentru Load Balancer-Backend
resource "aws_lb_target_group" "filiposiac_tg_backend" {
  name     = "filiposiac-tg-backend"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    protocol             = "HTTP"
    path                 = "/"
    interval             = 30
    timeout              = 5
    healthy_threshold    = 3
    unhealthy_threshold  = 3
  }
}

# Listener pentru Load Balancer
resource "aws_lb_listener" "filiposiac_lb_listener" {
  load_balancer_arn = aws_lb.filiposiac_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.filiposiac_tg1.arn
  }
}
# Listener pentru Load Balancer-Backend
resource "aws_lb_listener" "filiposiac_lb_listener_backend" {
  load_balancer_arn = aws_lb.filiposiac_lb_backend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.filiposiac_tg_backend.arn
  }
}

resource "aws_subnet" "private_db_subnet_1" {
  vpc_id                  = module.vpc.vpc_id
  cidr_block              = "10.0.203.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "Private Subnet 1 | Db Tier"
  }
}

resource "aws_subnet" "private_db_subnet_2" {
  vpc_id                  = module.vpc.vpc_id
  cidr_block              = "10.0.204.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "Private Subnet 2 | Db Tier"
  }
}

resource "aws_db_subnet_group" "database_subnet_group" {
  name        = "database subnets"
  subnet_ids  = [aws_subnet.private_db_subnet_1.id, aws_subnet.private_db_subnet_2.id]
  description = "Subnet group for database instance"

  tags = {
    Name = "Database Subnets"
  }
}

resource "aws_db_instance" "database_instance" {
  allocated_storage      = 10
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "sqldb"
  username               = "filip"
  password               = "filip1234"
  parameter_group_name = "default.mysql8.0"
  skip_final_snapshot    = true
  availability_zone      = "us-east-1b"
  db_subnet_group_name   = aws_db_subnet_group.database_subnet_group.name
  multi_az               = false
  vpc_security_group_ids = [aws_security_group.database_security_group.id]
}

resource "aws_route_table_association" "nat_route_db_1" {
  subnet_id      = aws_subnet.private_db_subnet_1.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "nat_route_db_2" {
  subnet_id      = aws_subnet.private_db_subnet_2.id
  route_table_id = aws_route_table.private_route_table.id
}


resource "aws_security_group" "database_security_group" {
  name        = "Database server Security Group"
  description = "Enable MYSQL access on port 3306"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MYSQL access"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = ["${aws_security_group.filiposiac_sg.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Database Security group"
  }
}