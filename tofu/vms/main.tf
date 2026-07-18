# KVM VMs on n150-1 (192.168.1.42)
#
# These resources were imported from running VMs — do not destroy without
# first migrating the workload.
#
# Import (first-time setup):
#   tofu import libvirt_domain.gitlab_1 gitlab-1
#
# Disk and network are NOT managed here (they pre-exist on the host).
# Only the domain definition is imported so CPU/RAM/autostart changes
# go through git.

# ── gitlab-1 ──────────────────────────────────────────────────────────────────
# GitLab CE — Ubuntu 22.04 VM on n150-1
# IP: 192.168.1.50 (static via DHCP reservation)
# Disk: /var/lib/libvirt/images/gitlab-1.qcow2 (80 GiB virtual, ~23 GiB used)

resource "libvirt_domain" "gitlab_1" {
  name   = "gitlab-1"
  uuid   = "6ea193a5-61f9-4b65-8ee1-a90b343aec5f"
  memory = 8192   # MiB
  vcpu   = 4

  autostart = true

  disk {
    file = "/var/lib/libvirt/images/gitlab-1.qcow2"
  }

  # cloud-init seed ISO — present on disk, not managed by tofu
  disk {
    file   = "/var/lib/libvirt/images/gitlab-1-seed.iso"
    scsi   = false
  }

  network_interface {
    bridge     = "br0"
    mac        = "52:54:00:6b:ab:01"
    wait_for_lease = false
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type   = "vnc"
    listen_type = "address"
  }

  cpu {
    mode = "host-passthrough"
  }
}
