# Home Lab — DevOps Environment

A GitOps-managed home lab built around an **Odroid-H4 Ultra** that serves double duty as
a NAS and a single-node **k3s** cluster, with an ARM inference fleet. Infrastructure is
defined as code: **Ansible** stands hosts up, **Argo CD** runs everything inside the
cluster from this git repo, and a two-tier storage model (hot NVMe + two cold SATA RAID 1
mirrors) keeps data safe.

## Why it's shaped this way

- **k3s, not full Kubernetes** — the H4 is also the NAS. k3s runs as a single systemd
  service alongside Samba/NFS and leaves most of the box free. Traefik is the default
  ingress; workloads use `networking.k8s.io/v1 Ingress`, not OpenShift Routes.
- **Argo CD, not imperative ops** — change the cluster by editing git and opening PRs.
  Argo reconciles with `selfHeal` on, so drift reverts and rollback is `git revert`.
  Never `kubectl apply` to `main` directly.
- **Two cold tiers** — a fast 4 TB NVMe for etcd/PVs/live NAS (OS on the 256 GB eMMC),
  and two SATA RAID 1 mirrors (8 TB primary + ~5.45 TB secondary) for backups and cold
  storage. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repo map

| Path | What it is |
|------|------------|
| `ansible/` | Host provisioning: storage, k3s install, backups, Argo bootstrap, password rotation |
| `gitops/` | What Argo deploys — `bootstrap/` (app-of-apps), `apps/`, `workloads/` |
| `docs/` | Architecture, hardware, runbook, security, AI inference, service catalog, updates |
| `scripts/` | One-shot helpers (`enable-winrm.ps1`, `lab-check.sh`, flannel FDB service) |
| `CLAUDE.md` | Operating rules — read before touching anything |

## What's running

### Cluster workloads (managed by Argo CD)

| App | Namespace | Notes |
|-----|-----------|-------|
| Immich | `immich` | Photo server + Postgres + Redis + ML; library on cold RAID at `/mnt/cold-8t/immich` |
| LiteLLM gateway | `ai-gateway` | Load-balances `chat` across both Ollama instances (simple-shuffle) |
| Ollama | `ai-gateway` | qwen2.5:3b on opi5pro-1, pinned via nodeSelector |
| Ollama-2 | `ai-gateway` | qwen2.5:3b on opi5pro-2, pinned via nodeSelector |
| kube-prometheus-stack | `monitoring` | Prometheus (30d/50GB), Grafana, Alertmanager, node-exporter on all nodes |
| external-secrets | `external-secrets` | Pulls secrets from Vault (KV v2 at `secret/lab/`) |
| cert-manager | `cert-manager` | TLS certificate management |
| Argo CD | `argocd` | GitOps controller — manages all of the above |

### Host services (outside k3s)

| Service | Host | IP |
|---------|------|----|
| HashiCorp Vault v1.21.0 | rpi5 | 192.168.1.128 |
| Mosquitto MQTT | opi-zero2w-2 | 192.168.1.188 |
| Pi-hole DNS (primary) | octopi | 192.168.1.148 |
| Samba / NFS (NAS) | H4 (host) | 192.168.1.160 |

### Ingress endpoints

| URL | Service |
|-----|---------|
| `grafana.apps.lab.home.arpa` | Grafana |
| `argocd.apps.lab.home.arpa` | Argo CD |
| `immich.apps.lab.home.arpa` | Immich |
| `*.apps.lab.home.arpa` | → 192.168.1.160 (Traefik) |

## Fleet

| Host | Ansible name | IP | Role |
|------|--------------|----|------|
| Odroid-H4 Ultra | h4-core | 192.168.1.160 | k3s server + NAS |
| Orange Pi 5 Pro #1 | opi5pro-1 | 192.168.1.168 | k3s agent, Ollama inference |
| Orange Pi 5 Pro #2 | opi5pro-2 | 192.168.1.172 | k3s agent, Ollama-2 inference |
| Raspberry Pi 5 | rpi5 | 192.168.1.128 | Vault |
| N150 mini PC #1 | n150-1 | 192.168.1.42  | Ubuntu 24.04, k3s server + KVM hypervisor |
| N150 mini PC #2 | n150-2 | 192.168.1.21  | Ubuntu 24.04, k3s server + KVM hypervisor |
| N150 mini PC #3 | n150-3 | 192.168.1.176 | Windows HTPC (WinRM managed, sleep disabled) |
| OPi Zero 2W #2 | opi-zero2w-2 | 192.168.1.188 | MQTT broker |
| OctoPi (RPi 3B #2) | octopi | 192.168.1.148 | Pi-hole DNS (Bookworm, Pi-hole v6.4.3) |
| Odroid XU3 | xu3-1 | 192.168.1.64 | Build agent (flagged unstable) |

## Quickstart (fresh bootstrap)

> Full step-by-step is in [docs/RUNBOOK.md](docs/RUNBOOK.md).

1. **Prereqs** — Ubuntu 22.04 on eMMC, NVMe + SATA disks ready, SSH key access, DNS
   records for `api.lab.home.arpa` and `*.apps.lab.home.arpa` → 192.168.1.160.
2. **Set your repo URL** — replace the `repoURL` in `gitops/bootstrap/root-app.yaml`.
3. **Bootstrap:**
   ```bash
   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/storage.yml --check
   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/storage.yml
   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k3s.yml
   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/backup.yml
   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/argocd.yml
   ```
4. **Verify** — `kubectl get nodes`, then open `https://argocd.apps.lab.home.arpa`.

## Day-to-day operations

Add a workload: add a directory under `gitops/workloads/` and an `Application` in
`gitops/apps/`, then merge to `main`. Argo deploys it within ~30 seconds.

Change anything: edit git, never poke the cluster directly. Secrets: store in Vault under `secret/lab/<name>`, then create an `ExternalSecret` in
the workload namespace. See `gitops/workloads/immich/external-secret.yaml` for an example.

## Updates and rollback

See [docs/UPDATES.md](docs/UPDATES.md) for the full update workflow. Short version:

| Layer | Update | Rollback |
|-------|--------|----------|
| Container image | Renovate PR → merge → Argo syncs | `git revert HEAD && git push` (~60s) |
| k3s binary | `make update-k3s` after Renovate PR | Re-run with previous version |
| OS packages | `make update-vms` (drain → apt → uncordon) | Restore from backup |
| Pi-hole | `make update-pihole` (secondary first) | Re-run `pihole -up` |
| Vault | Upgrade via apt; run `make check-vault` after | Restart + unseal |
| Windows nodes | Ansible `windows-bootstrap.yml` | Manual |

## Secrets and security

- Ansible Vault: `immich_db_password`, `lab_user_password_hash`, `windows_ansible_password`
- Vault KV v2: `secret/lab/immich`, `secret/lab/grafana`, `secret/lab/argocd-deploy-key`
- SSH password auth disabled on all Linux hosts; root locked
- Vault auto-unseal via systemd service on rpi5 (keys file on-disk, `root:root 0400`)
- Never commit: `/etc/restic/password`, `ansible/.vault_pass`, any kubeconfig or k3s token

See [docs/SECURITY.md](docs/SECURITY.md) for the full security model.

## Storage rules

- **Never** `mkfs`/`wipefs` the cold disks (`/dev/md0`, `/dev/md1`)
- **Never** run `restic forget`/`prune` by hand — retention is handled by backup timers only
- **Never** stop `smbd`, `nfs`, `backup-nas`, or `backup-etcd`
- Before any hot-tier storage change: confirm last backup succeeded

## TODO

### Actionable now
- [ ] Rotate octopi Pi-hole credentials (currently plaintext)
- [ ] Flash octopi to Raspberry Pi OS Bookworm → upgrade to Pi-hole v6
- [ ] Move photo library (~1.3TB) into `/mnt/cold-8t/immich` so Immich can serve it

### Longer term
- [ ] Vault TLS — currently plain HTTP; wire cert-manager before exposing beyond LAN
- [ ] LDAP integration with Immich SSO once OpenLDAP is up
- [ ] n150-1/2 → OVMS Intel iGPU for embeddings (`embeddings` model in LiteLLM config already wired)
- [ ] Offsite restic backup target
- [ ] Pin Immich image tag (currently `:release` floating) — Renovate will open the first PR
