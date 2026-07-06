#!/usr/bin/env bash
# Emit an Ansible inventory (YAML) from the OpenTofu `vms` output, grouped by tag.
#   ./inventory-from-tofu.sh > ../ansible/inventory/tofu-vms.yml
# NOTE: adjust the .ip field below to match your terraform/outputs.tf (ip_address / ip / ipv4).
set -euo pipefail
cd "$(dirname "$0")"
echo "all:"
echo "  children:"
tofu output -json vms 2>/dev/null | jq -r '
  "    vm_k3s_server:\n      hosts:",
  (to_entries[] | select(.value.tags|index("server")) | "        \(.key): { ansible_host: \"\(.value.ip_address // .value.ip)\" }"),
  "    vm_k3s_agents:\n      hosts:",
  (to_entries[] | select(.value.tags|index("agent"))  | "        \(.key): { ansible_host: \"\(.value.ip_address // .value.ip)\" }"),
  "    gitlab_vm:\n      hosts:",
  (to_entries[] | select(.value.tags|index("gitlab")) | "        \(.key): { ansible_host: \"\(.value.ip_address // .value.ip)\" }")
'
