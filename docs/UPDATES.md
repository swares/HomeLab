# Update Workflows

Zero-downtime patching for containers and VMs.  Two independent pipelines — one
per layer — each with its own validation gate and fast rollback.

---

## Container updates (GitLab CI + Renovate + ArgoCD)

```
Renovate bot
   └─ detects new image tag in upstream registry
   └─ opens MR in GitLab with bumped tag in gitops/workloads/

GitLab CI (on MR)
   ├─ yaml-lint       — validates all YAML under gitops/
   └─ dry-run-apply   — oc apply --dry-run=server against the cluster

Human reviews + merges MR
   └─ ArgoCD selfHeal picks up the change within ~30s
   └─ Kubernetes rolling update (maxSurge=1 / maxUnavailable=0)

GitLab CI (post-merge, on main)
   └─ argocd-sync-wait
        ├─ waits for every ArgoCD Application: Synced + Healthy
        ├─ confirms all pods Running/Succeeded
        └─ HTTP-probes every Route (2xx/3xx = pass; 401/403 = auth-gated, pass)

        ┌─ PASS ──→ done
        └─ FAIL ──→ auto-rollback job
                       git revert HEAD && git push origin main
                       ArgoCD selfHeal reconciles back within ~60s
```

### Renovate behaviour

| Update type | Action |
|-------------|--------|
| Digest pin (`:release` → `:vX.Y.Z@sha256:…`) | Auto-merged immediately |
| Patch (`v1.2.3` → `v1.2.4`) | Auto-merged |
| Minor (`v1.2` → `v1.3`) | MR opened, human review required |
| Major (`v1` → `v2`) | MR opened, `major-update` label, human review |
| Immich stack (all components) | Grouped into one MR, Monday 2–4 AM window |

Renovate runs nightly 2–6 AM Central.  Configure in `renovate.json`.

### Prerequisites

1. Install Renovate as a GitLab CI job or self-hosted bot (`make renovate` — not yet wired; see [Renovate self-hosted docs](https://docs.renovatebot.com/self-hosted-configuration/)).
2. **Pin image tags** — `gitops/workloads/immich/server.yaml` uses `:release` (floating). Renovate's first MR will pin it to a digest; merge that MR first.
3. Set CI/CD variables in GitLab (Settings → CI/CD → Variables):

| Variable | Description |
|----------|-------------|
| `ARGOCD_SERVER` | `argocd.apps.lab.home.arpa` |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token (Protected + Masked) |
| `KUBECONFIG_B64` | `base64 < ~/.kube/config` |
| `GIT_PUSH_TOKEN` | GitLab project token, `write_repository` scope |

4. Build or pull the CI runner image (`registry.lab.home.arpa/tools/homelab-ci`) with `oc`, `argocd`, `kubectl`, `yq`, `curl`.  Until that's ready, swap the `image:` line in `.gitlab-ci.yml` to `quay.io/openshift/origin-cli:4.15`.

---

## VM updates (Ansible rolling drain)

### k3s cluster nodes

```
make update-vms  (or: ansible-playbook playbooks/update-vms.yml -l k3s)

For each node (serial: 1 — one at a time):
  1. kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
  2. apt-get dist-upgrade
  3. reboot (if kernel/libc changed)
  4. kubectl wait node/<node> --for=condition=Ready --timeout=180s
  5. kubectl uncordon <node>
  6. Verify node is schedulable
```

Rolling serial ensures the cluster always has N-1 nodes available.  Never
touches the H4/MicroShift node — that's a separate host-layer concern managed
by `ansible/playbooks/microshift.yml`.

### Standalone VMs (GitLab, etc.)

```
make update-vms  (or: -l standalone_vms)

For each VM:
  1. Proxmox snapshot → pre-update-YYYY-MM-DD
  2. apt-get dist-upgrade
  3. reboot (if needed)
  4. HTTP health check (retries for health_check_timeout seconds)
  5. PASS → done
  6. FAIL → proxmox_snap rollback to snapshot (rescue block)
```

Rollback is instantaneous (Proxmox snapshot restore).  The snapshot is kept
until the next update cycle — `update-vms.yml` does **not** auto-delete old
snapshots; prune manually or add a separate cleanup play.

### Inventory requirements

Add these groups and variables to `ansible/inventory/hosts.yml`:

```yaml
k3s:
  children:
    k3s_server:
      hosts:
        k3s-server-1:
          ansible_host: 10.136.151.x
    k3s_agent:
      hosts:
        k3s-agent-1:
          ansible_host: 10.136.151.x
        k3s-agent-2:
          ansible_host: 10.136.151.x

standalone_vms:
  hosts:
    gitlab:
      ansible_host: 10.136.151.x
      proxmox_vmid: 101          # match the VMID in Proxmox
      health_check_url: https://gitlab.lab.home.arpa
```

Also set `proxmox_api_token_id` and `proxmox_api_token_secret` in Vault and
pull them via the existing External Secrets Operator or an Ansible vault file.

---

## Non-apt application updates (Pi-hole, k3s, Vault)

Some services install outside the OS package manager and need their own update paths.

### Pi-hole (`make update-pihole`)

Pi-hole ships its own `pihole -up` updater.  The play updates the **secondary DNS
node first**, then the primary — so DNS remains available throughout.  If the
secondary breaks, the primary is still serving and you can intervene before
touching it.

```
make update-pihole
  1. pihole -up on dns-2 (secondary)
  2. pihole status check — fail here if broken, primary untouched
  3. pihole -up on dns-1 (primary)
  4. pihole status check
```

### k3s (`make update-k3s`)

k3s is installed via its own installer script, not apt.  The target version is
pinned in `ansible/inventory/group_vars/all/k3s.yml` with a Renovate comment
marker — Renovate watches `rancher/k3s` GitHub releases and opens a PR bumping
that value when a new version is tagged.  Because k3s upgrades require a drain
cycle, the Renovate rule **never** auto-merges — it always requires human review.

```
Renovate detects new rancher/k3s release
   └─ opens PR bumping k3s_version in group_vars/all/k3s.yml

Human reviews release notes + merges PR

make update-k3s
  For each k3s_server (serial: 1):
    1. Skip if already at target version
    2. kubectl drain
    3. curl get.k3s.io | INSTALL_K3S_VERSION=... sh -
    4. kubectl wait node/... --for=condition=Ready
    5. kubectl uncordon

  For each k3s_agent (serial: 1, after all servers done):
    Same drain → install → ready → uncordon cycle
```

Rollback: re-run with the previous `k3s_version` value (git revert the Renovate PR).

### Vault seal check (`make check-vault`)

Vault is installed from the HashiCorp apt repo, so `update-vms.yml` upgrades the
binary.  After a service restart the Vault process may start **sealed** — secrets
backends will fail silently until unsealed.  This play checks and alerts:

```
make check-vault
  1. Confirm vault service is running
  2. GET /v1/sys/seal-status
  3. If sealed → print prominent warning with unseal instructions
  4. If unsealed → confirm + print version
```

Vault auto-unseals on boot via `vault-unseal.service` on rpi5 (reads keys from an
on-disk file, `root:root 0400`). After an upgrade that triggers a restart, the
service fires automatically — but run `make check-vault` to confirm before assuming
dependent services (External Secrets, anything pulling from Vault) are healthy.
If the keys file is missing or corrupt, Vault will start sealed; unseal manually with
`vault operator unseal`.

---

## VM base image refresh (Packer)

Baking a fresh template ensures **new** VMs start from a patched baseline —
complementary to the Ansible patching of running VMs.

```
make bake-image
  1. Clone Proxmox template VMID 9000 (existing Noble cloud image)
  2. apt-get dist-upgrade inside the VM
  3. Harden SSH, enable unattended-upgrades, install qemu-guest-agent
  4. Clean machine IDs, SSH host keys, cloud-init state (template hygiene)
  5. Convert to Proxmox template named ubuntu-noble-YYYYMMDD
  6. Output: packer/packer-manifest.json with new template VMID
  7. Update terraform/terraform.tfvars: ubuntu_image_url or clone_vm_id
```

### Setup

1. Create a Proxmox API token for Packer: `packer@pam` with VM.Clone, VM.Config.*, Datastore.AllocateSpace.
2. Copy and fill in credentials:
   ```
   cp packer/proxmox.pkrvars.hcl.example packer/proxmox.pkrvars.hcl
   # edit proxmox.pkrvars.hcl — DO NOT COMMIT (already in .gitignore)
   ```
3. Run `make bake-image`.
4. After the build, note the new template VMID from `packer/packer-manifest.json`
   and update `terraform/terraform.tfvars` so new VMs use the fresh image.

---

## Rollback summary

| Layer | How | Speed |
|-------|-----|-------|
| Container (GitOps) | `git revert HEAD && git push` → ArgoCD selfHeal | ~60s |
| k3s binary | Re-run play with previous `k3s_version` (revert Renovate PR) | ~5 min |
| k3s node OS | Re-drain → restore OS from backup (manual) | minutes |
| Pi-hole | Re-run `pihole -up` (Pi-hole supports rollback via its own mechanism) | ~2 min |
| Vault | Restart service + manual unseal | ~1 min |
| Standalone VM | Proxmox snapshot restore (automatic in rescue block) | ~30s |
| Base image (Packer) | Keep previous template VMID; revert `terraform.tfvars` | next `tofu apply` |

---

## Suggested schedule

| Task | Frequency | How |
|------|-----------|-----|
| Container image scan | Nightly | Renovate (automatic) |
| VM OS patches (apt) | Weekly | `make update-vms` in GitLab scheduled pipeline |
| Pi-hole update | Weekly | `make update-pihole` in GitLab scheduled pipeline |
| k3s binary upgrade | On Renovate PR merge | `make update-k3s` (manual trigger after PR review) |
| Vault seal check | After any VM OS patch | `make check-vault` |
| Base image bake | Monthly | `make bake-image` in GitLab scheduled pipeline |
| MicroShift host patches | Monthly, maintenance window | `ansible-playbook microshift.yml` (manual) |
