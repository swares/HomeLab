provider "proxmox" {
  endpoint  = var.proxmox_endpoint  # https://10.136.151.71:8006/
  api_token = var.proxmox_api_token # "tofu@pve!tf=<uuid>" — least-privilege token
  insecure  = var.proxmox_insecure  # true for the cluster's self-signed cert

  # bpg uses SSH to the node for a few operations (image import, snippets).
  # Use an SSH key/agent for root (or a sudo-capable user) on each node.
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}
