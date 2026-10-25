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
  region       = "eu-paris-1" 
}

variable "oci_tenancy_ocid" {}
variable "oci_user_ocid" {}
variable "oci_private_key" {}
variable "oci_fingerprint" {}
variable "ssh_public_key" {}

# ==========================================
# AWS INFRASTRUCTURE (Network Segmentation)
# ==========================================
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

# 1. Custom VPC & Subnets
resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "AWS-Lab-VPC" }
}

resource "aws_internet_gateway" "lab_igw" {
  vpc_id = aws_vpc.lab_vpc.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.1.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-north-1b"
}

resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.1.2.0/24"
  map_public_ip_on_launch = false # No public IP for the database
  availability_zone       = "eu-north-1b"
}

# 2. Routing
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.lab_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab_igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 3. Security Groups
resource "aws_security_group" "vpn_sg" {
  name        = "aws_vpn_sg"
  description = "Allow SSH and WireGuard"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["141.145.212.135/32"] # OCI Public IP
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  name        = "aws_db_sg"
  description = "Allow MySQL and SSH from VPN only"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.vpn_sg.id] # SSH only via VPN Jump Host
  }
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    cidr_blocks     = ["10.0.1.0/24"] # Allow MySQL from OCI via VPN
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4. Instances
resource "aws_instance" "aws_vpn" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_subnet.id
  key_name               = aws_key_pair.ansible_key.key_name
  vpc_security_group_ids = [aws_security_group.vpn_sg.id]
  source_dest_check      = false 

  # Updated to use ens5 for Ubuntu 22.04 on AWS
  user_data = <<-EOF
              #!/bin/bash
              sysctl -w net.ipv4.ip_forward=1
              iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
              EOF

  # Force Terraform to recreate the instance to apply the new script
  user_data_replace_on_change = true

  tags = { Name = "AWS-VPN-Node" }
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.aws_vpn.id
  public_ip     = "13.61.252.157"
}

resource "aws_instance" "aws_db" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_subnet.id
  key_name               = aws_key_pair.ansible_key.key_name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  
  private_ip             = "10.1.2.50" # Fixes the DB private IP permanently

  tags = { Name = "AWS-Private-DB" }
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.lab_vpc.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.aws_vpn.primary_network_interface_id
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

output "aws_private_db_ip" {
  value = aws_instance.aws_db.private_ip
}

# ==========================================
# OCI INFRASTRUCTURE (Web App & VPN Node)
# ==========================================
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_tenancy_ocid
}

resource "oci_core_vcn" "lab_vcn" {
  compartment_id = var.oci_tenancy_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "OCI-Lab-VCN"
}

resource "oci_core_internet_gateway" "lab_ig" {
  compartment_id = var.oci_tenancy_ocid
  vcn_id         = oci_core_vcn.lab_vcn.id
  enabled        = true
}

resource "oci_core_route_table" "lab_rt" {
  compartment_id = var.oci_tenancy_ocid
  vcn_id         = oci_core_vcn.lab_vcn.id
  route_rules {
    network_entity_id = oci_core_internet_gateway.lab_ig.id
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "lab_subnet" {
  compartment_id    = var.oci_tenancy_ocid
  vcn_id            = oci_core_vcn.lab_vcn.id
  cidr_block        = "10.0.1.0/24"
  route_table_id    = oci_core_route_table.lab_rt.id
  security_list_ids = [oci_core_vcn.lab_vcn.default_security_list_id] 
}

data "oci_core_images" "ubuntu_images" {
  compartment_id           = var.oci_tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04" 
  shape                    = "VM.Standard.E3.Flex" 
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "oci_web_vpn" {
  compartment_id      = var.oci_tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  fault_domain        = "FAULT-DOMAIN-3"
  shape               = "VM.Standard.E3.Flex" 

  shape_config {
    ocpus         = 1
    memory_in_gbs = 16 
  }

  source_details {
    source_id   = data.oci_core_images.ubuntu_images.images[0].id
    source_type = "image"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.lab_subnet.id
    assign_public_ip = false
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

data "oci_core_private_ips" "oci_private_ip" {
  ip_address = oci_core_instance.oci_web_vpn.private_ip
  subnet_id  = oci_core_subnet.lab_subnet.id
}

import {
  to = oci_core_public_ip.existing_reserved_ip
  id = "ocid1.publicip.oc1.eu-paris-1.amaaaaaa7va3wmyabui2vp3obnzyu55dgyuc27x66tpt5ggyo6nremz7kuvq"
}

resource "oci_core_public_ip" "existing_reserved_ip" {
  compartment_id = var.oci_tenancy_ocid
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.oci_private_ip.private_ips[0].id
}

output "oci_static_ip" {
  value = oci_core_public_ip.existing_reserved_ip.ip_address
}