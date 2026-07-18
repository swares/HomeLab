# KVM VMs on n150-1 (192.168.1.42)
#
# These resources were imported from running VMs — do not destroy without
# first migrating the workload.
#
# Import (first-time setup):
#   tofu import libvirt_domain.gitlab_1 gitlab-1
#
# Disk, network, and console config live in the domain XML on the host.
# This declaration tracks identity + compute sizing so changes go through git.

# ── gitlab-1 ──────────────────────────────────────────────────────────────────
# GitLab CE — Ubuntu 22.04 VM on n150-1
# IP: 192.168.1.50 (DHCP reservation)
# Disk: /var/lib/libvirt/images/gitlab-1.qcow2 (80 GiB virtual, ~23 GiB used)
# MAC: 52:54:00:6b:ab:01  Bridge: br0

resource "libvirt_domain" "gitlab_1" {
  name      = "gitlab-1"
  # uuid: 6ea193a5-61f9-4b65-8ee1-a90b343aec5f (read-only, set by libvirt)
  type      = "kvm"
  memory    = 8192   # MiB
  vcpu      = 4
  autostart = true
  running   = true

  lifecycle {
    # Track identity + prevent accidental destroy only.
    # Full domain config (devices, cpu, clock, networking) lives in the
    # domain XML managed by libvirt on n150-1 — not here.
    prevent_destroy = true
    ignore_changes  = all
  }
}
