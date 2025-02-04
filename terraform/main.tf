provider "aws" {
  region = "us-east-1"
}

# Select the workspace (dev, prod, stage)
terraform {
  required_version = ">= 0.12"
}

#Create an S3 bucket for the Terraform state file
resource "aws_s3_bucket" "terraform_state_bucket" {
  bucket = "gab-terraform-state-bucket-${terraform.workspace}"
  acl    = "private"

  tags = {
    Name = "terraform-state-bucket-${terraform.workspace}"
  }
  lifecycle {
    prevent_destroy = false
  }



}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.terraform_state_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}




terraform {
  backend "s3" {
    bucket = "gab-terraform-state-bucket-dev2" ## actual bucket name
    key    = "terraform/state/default.tfstate"
    region = "us-east-1"
  }
}

# Create a VPC for EKS and EC2 instances
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr_block

  tags = {
    Name = "vpc-${terraform.workspace}"
  }
}

resource "aws_subnet" "main" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "subnet-${count.index}-${terraform.workspace}"
  }
}

data "aws_availability_zones" "available" {}

# Create an Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "igw-${terraform.workspace}"
  }
}

# Create Route Table
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "route-table-${terraform.workspace}"
  }
}

# Associate Route Table to Subnets
resource "aws_route_table_association" "main" {
  count          = 2
  subnet_id      = aws_subnet.main[count.index].id
  route_table_id = aws_route_table.main.id
}

# EKS Cluster
resource "aws_eks_cluster" "eks_cluster" {
  name     = "eks-cluster-${terraform.workspace}"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.main[*].id
    security_group_ids = [aws_security_group.eks_cluster_sg.id]
  }
}

# EKS Node Group
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "eks-node-group-${terraform.workspace}"
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  subnet_ids      = aws_subnet.main[*].id

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  instance_types = ["t2.medium"]

  remote_access {
    ec2_ssh_key               = var.ssh_key_name
    source_security_group_ids = [aws_security_group.eks_node_sg.id]
  }
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role-${terraform.workspace}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node_group_role" {
  name = "eks-node-group-role-${terraform.workspace}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_node_group_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_security_group" "eks_cluster_sg" {
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-cluster-sg-${terraform.workspace}"
  }
}

resource "aws_security_group" "eks_node_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-node-sg-${terraform.workspace}"
  }
}

# AWS ECR Repository for Docker images
resource "aws_ecr_repository" "app_repo" {
  name                 = "gabapprepo${terraform.workspace}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  tags = {
    Name = "app-repo-${terraform.workspace}"
  }
}
# EC2 instance configuration
resource "aws_instance" "ubuntu_instance" {
  ami           = "ami-0e1bed4f06a3b463d"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.main[0].id # Subnets

  tags = {
    Name = "gab-ec2-${terraform.workspace}"
  }




  # security group with this instance
  vpc_security_group_ids = [aws_security_group.eks_node_sg.id]
}
// the code is ok