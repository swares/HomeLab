# ---- Connection ----
variable "proxmox_endpoint" {
  type = string
}
variable "proxmox_api_token" {
  type      = string
  sensitive = true
}
variable "proxmox_insecure" {
  type    = bool
  default = true
}
variable "proxmox_ssh_user" {
  type    = string
  default = "root"
}

# ---- Placement / storage ----
variable "template_node" {
  type        = string
  description = "Node that downloads the cloud image (any cluster node)."
  default     = "pve-n150-1"
}
variable "iso_datastore" {
  type        = string
  description = "Datastore for the downloaded cloud image. Use the SHARED NFS (from the H4) so every node can import it."
  default     = "nfs-h4"
}
variable "vm_datastore" {
  type        = string
  description = "Datastore for VM disks (shared NFS enables live migration)."
  default     = "nfs-h4"
}

# ---- Guest defaults ----
variable "bridge" {
  type    = string
  default = "vmbr0"
}
variable "gateway" {
  type    = string
  default = "10.136.151.1"
}
variable "dns_servers" {
  type    = list(string)
  default = ["10.136.151.1"] # point at your DNS host once assigned
}
variable "ci_user" {
  type    = string
  default = "ansible"
}
variable "ssh_keys" {
  type        = list(string)
  description = "Public keys injected into the cloud-init user."
  default     = []
}
variable "ubuntu_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

# ---- The VMs to create (data-driven; override in tfvars) ----
variable "vms" {
  type = map(object({
    node      = string
    cores     = number
    memory    = number
    disk_size = number
    ip        = string # "dhcp" or "10.136.151.x/24"
    tags      = list(string)
  }))
  # Default: a small k3s pool spread across the three N150s. Keep it stateless;
  # k3s itself is installed by Ansible, not here.
  default = {
    k3s-server-1 = { node = "pve-n150-1", cores = 2, memory = 4096, disk_size = 30, ip = "dhcp", tags = ["k3s", "server"] }
    k3s-agent-1  = { node = "pve-n150-2", cores = 2, memory = 4096, disk_size = 30, ip = "dhcp", tags = ["k3s", "agent"] }
    k3s-agent-2  = { node = "pve-n150-3", cores = 2, memory = 4096, disk_size = 30, ip = "dhcp", tags = ["k3s", "agent"] }
    # GitLab moved off OPi 5 Pro #2 onto a Proxmox VM (de-loads the AI board).
    gitlab       = { node = "pve-n150-1", cores = 4, memory = 8192, disk_size = 80, ip = "dhcp", tags = ["gitlab"] }
  }
}
