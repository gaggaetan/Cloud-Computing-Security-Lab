terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    oci = { source = "oracle/oci", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "us-east-1"
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

# Example AWS EC2 Instance for Database & VPN
resource "aws_instance" "aws_db_vpn" {
  ami           = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS
  instance_type = "t2.micro"
  tags = { Name = "AWS-DB-VPN" }
}

# Example OCI Compute Instance for Web Service & VPN
# (Requires defining exact OCI availability domains and shapes in a full deployment)