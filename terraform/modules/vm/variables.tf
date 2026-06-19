variable "name" {
  type = string
}
variable "node_name" {
  type = string
}
variable "vm_id" {
  type    = number
  default = 0 # 0 = let Proxmox auto-assign
}
variable "cores" {
  type    = number
  default = 2
}
variable "memory" {
  type    = number
  default = 4096 # MiB
}
variable "disk_size" {
  type    = number
  default = 30 # GiB
}
variable "datastore_id" {
  type = string # e.g. shared NFS from the H4
}
variable "image_id" {
  type = string # download_file resource id to import
}
variable "bridge" {
  type    = string
  default = "vmbr0"
}
variable "vlan_id" {
  type    = number
  default = null
}
variable "ip_cidr" {
  type    = string
  default = "dhcp" # or "10.136.151.x/24"
}
variable "gateway" {
  type    = string
  default = null
}
variable "dns_servers" {
  type    = list(string)
  default = []
}
variable "ci_user" {
  type    = string
  default = "ansible"
}
variable "ssh_keys" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = list(string)
  default = []
}
