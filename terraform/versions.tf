terraform {
  required_version = ">= 1.6" # OpenTofu >= 1.6 or Terraform >= 1.6
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111" # pin; validate your HCL against this version's docs
    }
  }
}
