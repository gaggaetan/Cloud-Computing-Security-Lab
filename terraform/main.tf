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
  region       = "eu-paris-1" # CORRECTED REGION
}

variable "oci_tenancy_ocid" {}
variable "oci_user_ocid" {}
variable "oci_private_key" {}
variable "oci_fingerprint" {}
variable "ssh_public_key" {}

# ==========================================
# AWS INFRASTRUCTURE (Database & VPN Node)
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

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.aws_db_vpn.id
  public_ip     = "13.61.252.157"
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
  operating_system_version = "20.04" # MATCHING MANUAL SETUP
  shape                    = "VM.Standard.E3.Flex" 
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "oci_web_vpn" {
  compartment_id      = var.oci_tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  fault_domain        = "FAULT-DOMAIN-3" # MATCHING MANUAL SETUP
  shape               = "VM.Standard.E3.Flex" 

  shape_config {
    ocpus         = 1
    memory_in_gbs = 16 # MATCHING MANUAL SETUP
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

# Récupération de l'ID de l'IP privée de l'instance
data "oci_core_private_ips" "oci_private_ip" {
  ip_address = oci_core_instance.oci_web_vpn.private_ip
  subnet_id  = oci_core_subnet.lab_subnet.id
}

# Création de l'IP publique statique et attachement
resource "oci_core_public_ip" "oci_reserved_ip" {
  compartment_id = var.oci_tenancy_ocid
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.oci_private_ip.private_ips[0].id
  display_name   = "OCI-Static-IP"
}

# Affichage de l'IP fixe à la fin de l'exécution
output "oci_static_ip" {
  value = oci_core_public_ip.oci_reserved_ip.ip_address
}