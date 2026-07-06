# Download the Ubuntu cloud image once to the SHARED datastore so any node can import it.
# NOTE: cloud images (.img/.qcow2) are pulled with content_type = "iso" in bpg. If your
# pinned provider version rejects the extension, rename via file_name or adjust content_type.
resource "proxmox_virtual_environment_download_file" "ubuntu_noble" {
  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = var.template_node
  url          = var.ubuntu_image_url
  file_name    = "noble-server-cloudimg-amd64.img"
  overwrite    = false
}
