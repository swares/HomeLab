output "vms" {
  description = "KVM VM names and UUIDs"
  value = {
    gitlab_1 = {
      name = libvirt_domain.gitlab_1.name
      uuid = libvirt_domain.gitlab_1.uuid
    }
  }
}
