variable "libvirt_uri" {
  description = "libvirt connection URI for the KVM host"
  type        = string
  default     = "qemu+ssh://swares@192.168.1.42/system"
}
