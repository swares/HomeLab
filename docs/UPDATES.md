# Update & Patching Coverage

Current state of automated and manual update paths across every layer of the lab.
Last updated: 2026-07-18.

---

## Coverage at a glance

| Layer | Automation | Cadence | Human gate |
|-------|-----------|---------|------------|
| In-cluster images & Helm charts | Renovate → GitHub PR → ArgoCD | Nightly scan; patches auto-merge | Minor/major PRs only |
| k3s binary | Renovate opens PR; Ansible runs drain cycle | On new upstream release | Yes — review release notes, then run drain cycle |
| Linux OS packages (apt) | Ansible `update-hosts.yml` in GitHub Actions | Weekly (Sunday 03:00 Central)¹ | H4 reboot if flagged |
| Pi-hole application | Ansible `update-non-apt.yml -t pihole` in GitHub Actions | Weekly (Sunday 03:00 Central)¹ | No |
| HashiCorp Vault binary | apt (HashiCorp repo) — included in OS play; seal-check play runs after | Weekly¹ | Yes — unseal manually if sealed after restart |
| **KVM VMs (gitlab-1, etc.)** | **`sandbox-vm-update.yml` — clone-test-promote pipeline** | **Manual / on-demand** | **Yes — human runs promote step** |
| Windows OS (n150-3 / yikw) | None — Windows Update runs uncontrolled | Uncontrolled | Manual if policy required |

¹ GitHub Actions schedule runs on the **self-hosted runner on H4** (`runs-on: [self-hosted, lab]`)
which has direct LAN access. Register the runner:
```bash
ansible-playbook -i ansible/inventory/hosts.yml playbooks/github-runner.yml \
  -e runner_token=<token-from-github> --vault-password-file ansible/.vault_pass
```
Get the token at: Settings → Actions → Runners → New self-hosted runner.

---

## 1. In-cluster apps — Renovate + ArgoCD

Renovate (hosted at [developer.mend.io](https://developer.mend.io/github/swares/HomeLab))
scans nightly and opens GitHub PRs when upstream Helm chart versions or image tags change.
ArgoCD reconciles automatically after merge.

```
Renovate (nightly 2–6 AM Central)
  └─ detects new chart or image version in gitops/workloads/
  └─ opens PR against main

GitHub Actions — validate.yml (on every PR and push to main)
  ├─ yamllint
  └─ kubectl --dry-run=server

Human reviews + merges (or auto-merge fires for patches)
  └─ ArgoCD selfHeal picks up change within ~30s
  └─ Kubernetes rolling update (maxSurge=1, maxUnavailable=0)
```

### Renovate policy

| Update type | Action |
|-------------|--------|
| Digest pin | Auto-merge immediately |
| Patch | Auto-merge (except Immich and k3s) |
| Minor | PR opened, human review required |
| Major | PR opened, `major-update` label, human review |
| Immich stack | Grouped into one PR, Monday 2–4 AM window, no auto-merge |
| k3s | PR opened, never auto-merge (drain cycle required) |
| `registry.apps.lab.home.arpa` | Disabled — Renovate cannot reach private registry |

Config lives in `renovate.json`.

### Rollback

```bash
git revert HEAD && git push origin main
# ArgoCD selfHeal restores previous state within ~60s
```

---

## 2. k3s binary — Renovate PR + manual drain cycle

Renovate watches `rancher/k3s` releases and bumps `k3s_version` in
`ansible/inventory/group_vars/all/k3s.yml`. Upgrades are never auto-merged because
they require a sequential drain/upgrade/uncordon across every node.

### Process

```
Renovate opens PR bumping k3s_version in group_vars/all/k3s.yml

Review release notes → merge PR on GitHub

On H4, run the Ansible play (handles server then agents, serial: 1):

  cd ~/lab/homelab/homelab/ansible
  ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
    --tags k3s --vault-password-file .vault_pass

  For each node (k3s_server first, then k3s_agents, one at a time):
    1. Skip if already at target version
    2. kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=120s
    3. curl https://get.k3s.io | INSTALL_K3S_VERSION=... K3S_URL=... K3S_TOKEN=... sh -
    4. kubectl wait node/<node> --for=condition=Ready --timeout=180s
    5. kubectl uncordon <node>
```

**Important — agent nodes require K3S_URL and K3S_TOKEN.** If the play fails with
`Error: --server is required`, the installer ran without the required env vars.
See `docs/TROUBLESHOOTING.md` → *k3s Agent Upgrade Fails*.

### Rollback

Re-run the play with the previous `k3s_version` value (revert the Renovate PR commit).

---

## 3. Linux OS packages — Ansible `update-hosts.yml`

Covers all bare-metal Linux hosts. Three tiers with different reboot strategies:

```
ansible-playbook playbooks/update-hosts.yml --vault-password-file .vault_pass
```

### Tier A — H4 (odroid-nas) — no auto-reboot

H4 co-locates the k3s server and NAS (smbd/nfs). A reboot briefly drops NAS services,
so reboots are not automatic. The play runs `apt dist-upgrade` and flags if a reboot
is needed. When flagged, schedule a maintenance window manually:

```bash
kubectl drain odroid-nas --ignore-daemonsets --delete-emptydir-data
sudo reboot
# wait for SSH to come back
kubectl uncordon odroid-nas
```

### Tier B — opi5pro-1, opi5pro-2 — drain → upgrade → uncordon

```
For each agent (serial: 1 — one at a time):
  1. kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
  2. apt dist-upgrade + autoremove
  3. reboot if /var/run/reboot-required exists
  4. kubectl wait node/<node> --for=condition=Ready --timeout=180s
  5. kubectl uncordon <node>
```

Running `serial: 1` keeps one agent schedulable throughout.

### Tier C — standalone Linux hosts — upgrade + reboot

Covers: rpi5 (Vault), octopi (Pi-hole OS), opi-zero2w-2 (MQTT), xu3-1 (build agent).

```
For each host (serial: 1):
  1. apt dist-upgrade + autoremove
  2. reboot if /var/run/reboot-required exists
  3. wait for SSH
```

No drain cycle — these hosts are not cluster nodes.

### Tags

```bash
# All hosts
ansible-playbook playbooks/update-hosts.yml --vault-password-file .vault_pass

# Specific tier
ansible-playbook playbooks/update-hosts.yml --tags standalone --vault-password-file .vault_pass
ansible-playbook playbooks/update-hosts.yml --tags k3s_agents --vault-password-file .vault_pass
ansible-playbook playbooks/update-hosts.yml --tags k3s_server --vault-password-file .vault_pass

# Dry-run
ansible-playbook playbooks/update-hosts.yml --check --vault-password-file .vault_pass
```

---

## 4. Pi-hole application — `update-non-apt.yml -t pihole`

Pi-hole ships its own `pihole -up` updater and is not managed by apt.
The play updates the **secondary DNS node first** to preserve DNS availability;
if the secondary breaks, the primary is still serving.

```
1. pihole -up on dns-2 (opi-zero2w-1, secondary)
2. pihole status — fail here if broken, primary untouched
3. pihole -up on dns-1 (octopi, primary)
4. pihole status
```

```bash
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags pihole --vault-password-file .vault_pass
```

---

## 5. HashiCorp Vault binary

Vault is installed from the HashiCorp apt repo (`apt.releases.hashicorp.com`), so
the OS update play (Tier C above) upgrades its binary automatically when a new package
is published. After any restart Vault may start **sealed** — secrets backends silently
fail until it is unsealed.

The Ansible play checks seal status but does **not** auto-unseal:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags vault --vault-password-file .vault_pass
```

If sealed, unseal manually on rpi5:

```bash
export VAULT_ADDR=http://192.168.1.128:8200
vault operator unseal   # enter unseal key shares
```

Vault is configured to auto-unseal via a systemd service (`vault-unseal.service`) on
rpi5 that reads keys from an on-disk file (`root:root 0400`). If that file is present
and intact, the service fires automatically after a restart. Run the seal-check play
to confirm before assuming External Secrets and dependent workloads are healthy.

---

## 6. Windows OS (n150-3 / yikw only — n150-1/2 are Ubuntu)

**Not currently automated.** Windows Update runs on its own schedule (or not, depending
on local policy). The Ansible `windows-bootstrap.yml` playbook handles initial setup but
does not run Windows Update.

To run Windows Update via Ansible:

```bash
# One-off — check mode first
ansible -i inventory/hosts.yml x86_nodes \
  -m ansible.windows.win_updates \
  -a "category_names=SecurityUpdates,CriticalUpdates state=searched" \
  --vault-password-file .vault_pass

# Apply
ansible-playbook -i inventory/hosts.yml playbooks/windows-updates.yml \
  --vault-password-file .vault_pass
```

`ansible/playbooks/windows-updates.yml` does not yet exist — create it when this
becomes a priority. The `ansible.windows.win_updates` module handles reboot sequencing.

---

## Running manually

The GitHub Actions schedule runs from the **self-hosted runner registered on H4** (`runs-on: [self-hosted, lab]`),
which has direct LAN access. GitLab CI is the authoritative pipeline. GitHub Actions handles yaml-lint + client-side dry-run only.
To run jobs manually from H4:

```bash
cd ~/lab/homelab/homelab/ansible

# Full OS update pass (all bare-metal Linux)
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --vault-password-file .vault_pass

# Pi-hole + k3s + Vault (non-apt apps)
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --vault-password-file .vault_pass

# k3s only (after merging Renovate PR)
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags k3s --vault-password-file .vault_pass
```

---

## GitHub Actions schedule

Defined in `.github/workflows/scheduled-updates.yml`. Runs every Sunday at 03:00
Central (09:00 UTC). All jobs are independent; a failure in one does not block others.

| Job | What it does |
|-----|-------------|
| `check-vault` | Checks Vault seal status via Ansible |
| `update-pihole` | Runs `pihole -up` secondary-first via Ansible |
| `apt-upgrade` | Runs `update-hosts.yml` against all bare-metal Linux |
| `lab-health-check` | Runs `scripts/lab-check.sh` — pings all hosts |

Manual trigger: GitHub → Actions → "Scheduled updates" → Run workflow.

---

## Rollback summary

| Layer | How | Time |
|-------|-----|------|
| Container image / Helm chart | `git revert HEAD && git push` → ArgoCD selfHeal | ~60s |
| k3s binary | Re-run upgrade play with previous `k3s_version` | ~5 min/node |
| Linux OS packages | Restore from restic backup (manual) | Varies |
| Pi-hole | `pihole -up` again (Pi-hole supports in-place rollback) | ~2 min |
| Vault | Restart service + manual unseal | ~1 min |

---

## 6. KVM VM updates — `sandbox-vm-update.yml`

A clone-test-promote pipeline for OS package updates on KVM VMs (e.g. `ldap-1`).

```
Validate only (default):
  ansible-playbook -i inventory/hosts.yml playbooks/sandbox-vm-update.yml \
    -e target_vm=gitlab-1 --vault-password-file .vault_pass --ask-become-pass

Validate + promote (swaps production disk):
  ansible-playbook -i inventory/hosts.yml playbooks/sandbox-vm-update.yml \
    -e "target_vm=gitlab-1 promote_on_pass=true" \
    --vault-password-file .vault_pass --ask-become-pass
```

Pipeline phases:
1. **Phase 1 (n150-1)** — suspend VM briefly, `cp` disk to standalone sandbox image, resume; patch sandbox netplan to DHCP; boot `gitlab-1-sandbox` on isolated NAT network (`10.99.0.0/24`)
2. **Phase 2 (sandbox-clone)** — `apt dist-upgrade`, reboot if needed; HTTP health check
3. **Phase 3 (n150-1)** — destroy sandbox VM; if `promote_on_pass=true` and healthy: compact sandbox disk → shut production briefly → swap disk → restart; always delete sandbox disk

Old production disk is saved as `gitlab-1-pre-YYYY-MM-DD.qcow2`.

Requires per-VM inventory vars (`kvm_host`, `libvirt_vm_name`, `health_check_url`) in the `standalone_vms` group.

---

## Gaps and next steps

| Gap | Priority | Notes |
|-----|----------|-------|
| Authelia → PostgreSQL | High | SQLite PVC blocks `replicas: 2`; PostgreSQL migration enables true Authelia HA |
| Windows Update automation (`windows-updates.yml`) | Medium | `ansible.windows.win_updates` module is ready; playbook not yet written |
| Vault TLS | Medium | Currently plain HTTP; add before exposing beyond LAN |
| ~~octopi OS upgrade (Raspbian Buster → Bookworm)~~ | ✅ Done (2026-07-13) | Bookworm + Pi-hole v6.4.3/FTL v6.7 confirmed running |
| ~~zswap on n150-1/n150-2~~ | ✅ Done (2026-07-03) | zswap enabled: zstd compressor, zsmalloc zpool, 20% max pool |
| ~~Shared storage (n150-1 ↔ n150-2)~~ | ✅ Done (2026-07-03) | NFS `/srv/libvirt-shared` exported from H4; libvirt-shared pool active on both nodes; VM live migration ready |
