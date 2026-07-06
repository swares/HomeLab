# Map of created VMs. ipv4 populates once the guest agent reports (may be empty on first
# apply — re-run `tofu output` shortly after). Hand these to Ansible as the k3s inventory.
output "vms" {
  description = "name -> { id, node, role tags, ipv4 }"
  value = {
    for k, m in module.vms : k => {
      id   = m.id
      node = var.vms[k].node
      tags = var.vms[k].tags
      ipv4 = m.ipv4_addresses
    }
  }
}
