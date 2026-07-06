#!/usr/bin/env bash
# provision.sh — called by Packer inside the VM being baked.
# Applies all OS patches, hardens the image, and cleans it for templating.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Packer provision: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── 1. Full package upgrade ────────────────────────────────────────────────────
echo "--- apt upgrade ---"
apt-get update -qq
apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
apt-get dist-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
apt-get autoremove -y --purge
apt-get autoclean -y

# ── 2. Ensure useful baseline tools are present ───────────────────────────────
echo "--- baseline packages ---"
apt-get install -y \
  curl \
  ca-certificates \
  gnupg \
  lsb-release \
  qemu-guest-agent \
  unattended-upgrades \
  apt-listchanges \
  ntp \
  open-vm-tools 2>/dev/null || true

# ── 3. Enable unattended security upgrades (belt + suspenders) ───────────────
echo "--- unattended-upgrades ---"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# ── 4. Harden SSH ─────────────────────────────────────────────────────────────
echo "--- sshd hardening ---"
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'         /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'    /etc/ssh/sshd_config

# ── 5. Start qemu-guest-agent so Proxmox can see the VM ──────────────────────
systemctl enable qemu-guest-agent --now 2>/dev/null || true

# ── 6. Template cleanup — must come LAST ─────────────────────────────────────
echo "--- template cleanup ---"

# Remove machine-specific IDs so clones start fresh
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Cloud-init reset — clears instance ID so cloud-init re-runs on first boot
cloud-init clean --logs

# Remove SSH host keys — will be regenerated on first boot
rm -f /etc/ssh/ssh_host_*

# Wipe bash history
unset HISTFILE
truncate -s 0 /root/.bash_history 2>/dev/null || true
find /home -name ".bash_history" -delete 2>/dev/null || true

# Wipe apt lists (will refresh on first boot)
rm -rf /var/lib/apt/lists/*

# Wipe temp files
rm -rf /tmp/* /var/tmp/*

# ── 7. Check if reboot required ───────────────────────────────────────────────
if [ -f /var/run/reboot-required ]; then
  echo "=== Rebooting to apply kernel update ==="
  reboot
fi

echo "=== Provision complete ==="
