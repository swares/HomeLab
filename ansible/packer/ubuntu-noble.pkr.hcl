# ubuntu-noble.pkr.hcl — Bake a fully-patched Ubuntu 24.04 (Noble) VM template
# on Proxmox using the Proxmox clone builder.
#
# Workflow:
#   1. Clone the existing cloud-init download into a temporary VM
#   2. Boot, run provision.sh (apt upgrade + hardening + cleanup)
#   3. Snapshot → convert to template
#   4. Template is tagged with build date for traceability
#   5. Update terraform/terraform.tfvars to point at the new template ID
#
# Run:
#   packer init .
#   packer build -var-file=proxmox.pkrvars.hcl ubuntu-noble.pkr.hcl
#
# Required variables (set in proxmox.pkrvars.hcl — DO NOT COMMIT that file):
#   proxmox_url            https://pve-n150-1.lab.home.arpa:8006/api2/json
#   proxmox_username       packer@pam!packer-token
#   proxmox_token          <token secret>
#   proxmox_node           pve-n150-1
#   iso_datastore          nfs-h4
#   ssh_private_key_file   path to key that matches the cloud-init user

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.8"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "proxmox_url"            { type = string }
variable "proxmox_username"       { type = string }
variable "proxmox_token"          { type = string; sensitive = true }
variable "proxmox_node"           { type = string; default = "pve-n150-1" }
variable "iso_datastore"          { type = string; default = "nfs-h4" }
variable "vm_datastore"           { type = string; default = "nfs-h4" }
variable "ssh_private_key_file"   { type = string }
variable "ssh_username"           { type = string; default = "ansible" }

locals {
  build_date    = formatdate("YYYYMMDD", timestamp())
  template_name = "ubuntu-noble-${local.build_date}"
}

# ── Source: clone the downloaded cloud image ──────────────────────────────────
source "proxmox-clone" "ubuntu_noble" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = true
  node                     = var.proxmox_node

  # Clone from the template that Terraform/cloud-init creates.
  # Update this ID if you reprovision the base template.
  clone_vm_id = 9000   # conventional Proxmox template VMID; adjust to match yours

  vm_name  = local.template_name
  vm_id    = 0          # 0 = auto-assign
  template = true       # convert to template on completion

  cores   = 2
  memory  = 2048
  os      = "l26"

  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  disks {
    type         = "virtio"
    disk_size    = "30G"
    storage_pool = var.vm_datastore
  }

  # Cloud-init drive so the first-boot SSH key injection works
  cloud_init              = true
  cloud_init_storage_pool = var.vm_datastore

  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "10m"
  ssh_handshake_attempts = 30
}

# ── Build: patch and clean up ─────────────────────────────────────────────────
build {
  name    = "ubuntu-noble-patched"
  sources = ["source.proxmox-clone.ubuntu_noble"]

  provisioner "shell" {
    script           = "scripts/provision.sh"
    execute_command  = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = true   # reboot inside script
    pause_after      = "30s"
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
