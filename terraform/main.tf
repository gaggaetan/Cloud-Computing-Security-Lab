terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    oci = { source = "oracle/oci", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "eu-north-1"
}

provider "oci" {
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  private_key  = var.oci_private_key
  region       = "us-ashburn-1"
}

variable "oci_tenancy_ocid" {}
variable "oci_user_ocid" {}
variable "oci_private_key" {}
variable "ssh_public_key" {}

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
  owners = ["099720109477"]
}

resource "aws_key_pair" "ansible_key" {
  key_name   = "ansible_key"
  public_key = var.ssh_public_key
}

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

# Association de votre IP existante à la nouvelle instance
resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.aws_db_vpn.id
  public_ip     = "13.61.252.157"
}