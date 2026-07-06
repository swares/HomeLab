# modules/vm — one cloud-init VM on the Proxmox cluster (bpg/proxmox).
# Imports a downloaded cloud image directly (no manual template needed) and seeds it via
# cloud-init. Terraform's job stops at a reachable, SSH-ready VM; Ansible takes it from there.

terraform {
  required_providers {
    proxmox = { source = "bpg/proxmox" }
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vm_id != 0 ? var.vm_id : null
  tags      = var.tags

  # Clean teardown for a lab.
  stop_on_destroy = true

  agent {
    enabled = true # requires qemu-guest-agent in the guest (cloud-init installs it below)
  }

  cpu {
    cores = var.cores
    type  = "host" # expose native N150 features (QuickSync, AES-NI, AVX2) to the guest
  }

  memory {
    dedicated = var.memory # MiB
  }

  # Import the downloaded cloud image as the boot disk, then resize it.
  disk {
    datastore_id = var.datastore_id
    import_from  = var.image_id
    interface    = "scsi0"
    size         = var.disk_size # GiB
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge  = var.bridge
    vlan_id = var.vlan_id # null = untagged
  }

  initialization {
    datastore_id = var.datastore_id
    ip_config {
      ipv4 {
        address = var.ip_cidr                                  # "dhcp" or "10.136.151.x/24"
        gateway = var.ip_cidr == "dhcp" ? null : var.gateway
      }
    }
    dns {
      servers = var.dns_servers
    }
    user_account {
      username = var.ci_user
      keys     = var.ssh_keys
    }
  }

  operating_system {
    type = "l26" # Linux 2.6+/modern
  }

  lifecycle {
    # SSH keys re-ordering shouldn't force replacement.
    ignore_changes = [initialization[0].user_account[0].keys]
  }
}
