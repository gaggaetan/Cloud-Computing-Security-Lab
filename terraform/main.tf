terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    oci = { source = "oracle/oci", version = "~> 5.0" }
  }
}

# AWS Provider Configuration
provider "aws" {
  region = "eu-north-1"
}

# OCI Provider Configuration
provider "oci" {
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  private_key  = var.oci_private_key
  region       = "us-ashburn-1" # Modify based on your Oracle account region
}

# Variables injected by GitHub Actions Secrets
variable "oci_tenancy_ocid" {}
variable "oci_user_ocid" {}
variable "oci_private_key" {}
variable "ssh_public_key" {}

# Dynamic retrieval of the latest Ubuntu 22.04 image for eu-north-1
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Official Canonical (Ubuntu) ID
}

# Inject the public SSH key into AWS for Ansible authentication
resource "aws_key_pair" "ansible_key" {
  key_name   = "ansible_key"
  public_key = var.ssh_public_key
}

# Security Group (Firewall) to allow SSH access for configuration
resource "aws_security_group" "lab_sg" {
  name        = "lab_sg"
  description = "Allow SSH from GitHub Actions"

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

# AWS Instance Creation (Database + VPN)
resource "aws_instance" "aws_db_vpn" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  availability_zone      = "eu-north-1b"
  
  key_name               = aws_key_pair.ansible_key.key_name
  vpc_security_group_ids = [aws_security_group.lab_sg.id]
  
  tags = { 
    Name = "AWS-DB-VPN" 
  }
}

# Fixed IP Creation (Elastic IP) linked to the instance
resource "aws_eip" "vpn_ip" {
  instance = aws_instance.aws_db_vpn.id
  domain   = "vpc"
}

# Output the fixed IP at the end of execution
output "aws_static_ip" {
  value = aws_eip.vpn_ip.public_ip
}

# --------------------------------------------------------
# Placeholder for future OCI instance configuration
# resource "oci_core_instance" "oci_web_vpn" {
#   ...
# }
# --------------------------------------------------------