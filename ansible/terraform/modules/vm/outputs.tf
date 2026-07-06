output "id" { value = proxmox_virtual_environment_vm.this.id }
output "name" { value = proxmox_virtual_environment_vm.this.name }
# Reported by the guest agent once it's up; may be empty on the first apply.
output "ipv4_addresses" { value = proxmox_virtual_environment_vm.this.ipv4_addresses }
