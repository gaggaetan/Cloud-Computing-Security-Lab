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
  fingerprint  = var.oci_fingerprint
  region       = "us-ashburn-1"
}

variable "oci_tenancy_ocid" {}
variable "oci_user_ocid" {}
variable "oci_private_key" {}
variable "oci_fingerprint" {}
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


#
#
#
#

# Fetch OCI Availability Domain
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_tenancy_ocid
}

# Create a Virtual Cloud Network (VCN)
resource "oci_core_vcn" "lab_vcn" {
  compartment_id = var.oci_tenancy_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "OCI-Lab-VCN"
}

# Create Internet Gateway
resource "oci_core_internet_gateway" "lab_ig" {
  compartment_id = var.oci_tenancy_ocid
  vcn_id         = oci_core_vcn.lab_vcn.id
  enabled        = true
}

# Create Route Table
resource "oci_core_route_table" "lab_rt" {
  compartment_id = var.oci_tenancy_ocid
  vcn_id         = oci_core_vcn.lab_vcn.id
  route_rules {
    network_entity_id = oci_core_internet_gateway.lab_ig.id
    destination       = "0.0.0.0/0"
  }
}

# Create Subnet (Default Security List allows port 22/SSH)
resource "oci_core_subnet" "lab_subnet" {
  compartment_id    = var.oci_tenancy_ocid
  vcn_id            = oci_core_vcn.lab_vcn.id
  cidr_block        = "10.0.1.0/24"
  route_table_id    = oci_core_route_table.lab_rt.id
  security_list_ids = [oci_core_vcn.lab_vcn.default_security_list_id] 
}

# Fetch latest Ubuntu 22.04 Image for OCI
data "oci_core_images" "ubuntu_images" {
  compartment_id           = var.oci_tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Create OCI Instance (Web + VPN)
resource "oci_core_instance" "oci_web_vpn" {
  compartment_id      = var.oci_tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  shape               = "VM.Standard.E2.1.Micro" # OCI Always Free Tier

  source_details {
    source_id   = data.oci_core_images.ubuntu_images.images[0].id
    source_type = "image"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.lab_subnet.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

# Output the dynamic OCI IP
output "oci_public_ip" {
  value = oci_core_instance.oci_web_vpn.public_ip
}