# terraform/ — the Proxmox IaaS layer (CASC)

Provisions VMs on the **3-node N150 Proxmox cluster** with the **`bpg/proxmox`** provider —
the bottom of the CASC loop. It imports an Ubuntu cloud image, seeds VMs via cloud-init, and
hands them to Ansible:

    Git → OpenTofu (here) → Proxmox VMs → Ansible (installs k3s) → Argo CD (in-cluster)

> Works with OpenTofu (`tofu`) or Terraform (`terraform`) ≥ 1.6. Provider pinned to
> `bpg/proxmox ~> 0.66` in `versions.tf` — I couldn't run `validate` here (no registry access),
> so run `tofu validate` against that version first; nudge the pin if an attribute moved.

## Layout

| File | Purpose |
|------|---------|
| `versions.tf` | Terraform + provider version pins |
| `providers.tf` | Proxmox endpoint, API token, SSH (bpg needs SSH for image import) |
| `variables.tf` | All inputs incl. the data-driven `vms` map (default: a 3-node k3s pool) |
| `images.tf` | Downloads the Ubuntu Noble cloud image to the shared datastore |
| `k3s.tf` | Calls `modules/vm` for each entry in `var.vms` |
| `outputs.tf` | `vms` map (name → id/node/tags/ipv4) to feed Ansible |
| `modules/vm/` | Reusable cloud-init VM (import image → cloud-init → SSH-ready) |
| `terraform.tfvars.example` | Copy to `terraform.tfvars` (git-ignored) and fill in |

## Prerequisites

1. **A 3-node Proxmox cluster** on the N150s, with the **H4's NFS export** added as a shared
   datastore (so images/disks are cluster-wide and VMs can live-migrate). Set its name in
   `iso_datastore` / `vm_datastore` (default `nfs-h4`).
2. **An API token** with VM-admin rights, e.g. on a node:
   ```
   pveum role add TofuProvision -privs "VM.Allocate VM.Clone VM.Config.Disk VM.Config.CPU \
     VM.Config.Memory VM.Config.Network VM.Config.Cloudinit VM.Config.Options VM.Monitor \
     VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit SDN.Use"
   pveum user add tofu@pve
   pveum aclmod / -user tofu@pve -role TofuProvision
   pveum user token add tofu@pve tf --privsep 0
   ```
   Put the resulting `tofu@pve!tf=<uuid>` in `terraform.tfvars`.
3. **SSH access** for `root` (key/agent) to each node — bpg uses it for the image import.

## Use

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit (token, ssh_keys, datastore names)
tofu init
tofu plan
tofu apply
tofu output vms                                # names → IPs once the guest agent reports
```

## Hand-off to Ansible (the division of labour)

Terraform stops at a reachable, SSH-ready VM with `qemu-guest-agent` and your key. **It does
not install k3s** — that's Ansible's job (and Argo owns everything inside the cluster). Feed
the `vms` output into an inventory, e.g.:

```bash
tofu output -json vms | jq -r '
  "[k3s_server]", (to_entries[] | select(.value.tags|index("server")) | .value.ipv4[0][0]),
  "[k3s_agent]",  (to_entries[] | select(.value.tags|index("agent"))  | .value.ipv4[0][0])
' > ../ansible/inventory/k3s.generated.ini
```

Then run your k3s role against it. The OPi 5 Pro AI nodes are **not** managed here — they're
bare-metal (Proxmox is x86-only; the NPUs want the metal), so Ansible handles those directly.

## Notes / caveats

- Cloud images download with `content_type = "iso"` in bpg; if your version rejects the `.img`
  extension, adjust `file_name`/`content_type` in `images.tf`.
- `ipv4` outputs are populated by the guest agent — empty on first apply, then `tofu output`
  again once the VM has booted.
- Default VMs use DHCP; switch to static CIDRs in `vms` once DNS/IPAM is settled.
- Keep VMs **stateless** where the disk is on SD-backed nodes; on the N150 NVMe/NFS this is
  fine for general workloads.
