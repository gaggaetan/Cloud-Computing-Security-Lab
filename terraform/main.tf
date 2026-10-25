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
  region       = "us-ashburn-1" # Modifiez si votre instance OCI est ailleurs
}

variable "oci_tenancy_ocid" {}
variable "oci_user_ocid" {}
variable "oci_private_key" {}

# Récupération dynamique de la dernière image Ubuntu 22.04 pour eu-north-1
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
  owners = ["099720109477"] # Canonical (Ubuntu)
}

# Instance AWS pour la base de données et le VPN
resource "aws_instance" "aws_db_vpn" {
  ami               = data.aws_ami.ubuntu.id
  instance_type     = "t3.micro"
  availability_zone = "eu-north-1b"
  
  tags = { 
    Name = "AWS-DB-VPN" 
  }
}

# (Ajoutez ici votre bloc resource "oci_core_instance" pour la partie Oracle)