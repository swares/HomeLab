# Provision each VM from var.vms using the reusable module. Spreads across the cluster
# by `node`. Output feeds Ansible (which installs k3s) — see outputs.tf and ../ansible.
module "vms" {
  source   = "./modules/vm"
  for_each = var.vms

  name      = each.key
  node_name = each.value.node
  cores     = each.value.cores
  memory    = each.value.memory
  disk_size = each.value.disk_size
  ip_cidr   = each.value.ip
  tags      = each.value.tags

  datastore_id = var.vm_datastore
  image_id     = proxmox_virtual_environment_download_file.ubuntu_noble.id
  bridge       = var.bridge
  gateway      = var.gateway
  dns_servers  = var.dns_servers
  ci_user      = var.ci_user
  ssh_keys     = var.ssh_keys
}
