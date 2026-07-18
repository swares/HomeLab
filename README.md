# Home Lab — DevOps Environment

A GitOps-managed home lab built around an **Odroid-H4 Ultra** NAS core and a
**3-node HA k3s cluster** (H4 + two N150 mini PCs), with an ARM64 inference fleet
(two Orange Pi 5 Pros). Infrastructure is defined as code: **Ansible** stands hosts up,
**Argo CD** runs everything inside the cluster from this git repo, and a two-tier storage
model (hot NVMe + two cold SATA RAID 1 mirrors) keeps data safe.

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
| Immich | `immich` | Photo server + Postgres (vectorchord) + Redis + ML; library on NFS ReadWriteMany PV |
| LiteLLM gateway | `ai-gateway` | Unified OpenAI-compatible API (`ai.apps.lab.home.arpa`) across all backends |
| RKLLama | `ai-gateway` | NPU-native LLM on opi5pro-1/2 (DeepSeek-R1-Distill-Qwen-1.5B, ~7–8 tok/s) |
| Ollama | `ai-gateway` | In-cluster fallback engine on opi5pro-1/2; pinned to `ollama/ollama:0.32.0` |
| m5stack-adapter | `ai-gateway` | OpenAI shim for M5Stack `/api/*` protocol; image 0.1.1 |
| Whisper STT | `whisper` | Speech-to-text at `https://stt.apps.lab.home.arpa`; CPU on n150-1 |
| lldap | `lldap` | Lightweight LDAP directory; web UI at `lldap.apps.lab.home.arpa` |
| Authelia | `authelia` | OIDC/SSO backed by lldap; PostgreSQL backend; `authelia.apps.lab.home.arpa` |
| Home Assistant | `home-assistant` | `ha.apps.lab.home.arpa`; MQTT consumer (broker at opi-zero2w-2 .188) |
| Minio | `minio` | S3-compatible object store; `tofu-state` bucket holds OpenTofu state |
| Semaphore | `semaphore` | Ansible UI at `semaphore.apps.lab.home.arpa` |
| Kyverno | `kyverno` | 3 ClusterPolicies in Enforce mode (no-latest-tag, resource-limits, no-privileged) |
| kube-prometheus-stack | `monitoring` | Prometheus (30d/40GB), Grafana, Alertmanager, Loki, Alloy on all nodes |
| external-secrets | `external-secrets` | Pulls secrets from Vault (KV v2 at `secret/lab/`) |
| cert-manager | `cert-manager` | TLS via `lab-ca` ClusterIssuer (self-signed root CA) |
| Argo CD | `argocd` | GitOps controller — selfHeal + prune on all apps |

### Host services (outside k3s)

| Service | Host | IP |
|---------|------|----|
| HashiCorp Vault | rpi5 | 192.168.1.128 |
| Mosquitto MQTT (primary) | opi-zero2w-2 | 192.168.1.188 |
| Mosquitto MQTT (secondary, HA bridge) | opi-zero2w-4 | 192.168.1.99 |
| Pi-hole DNS (primary, v6.4.3) | octopi (RPi 3B #2) | 192.168.1.148 |
| Pi-hole DNS (secondary, v6) | rpi4b (RPi 4B) | 192.168.1.116 |
| dnsmasq DNS (tertiary fallback) | opi-zero2w-1 | 192.168.1.184 |
| Samba / NFS (NAS) | H4 (host) | 192.168.1.160 |
| GitLab CE | gitlab-1 VM on n150-1 | 192.168.1.50 |

### Ingress endpoints

| URL | Service |
|-----|---------|
| `argocd.apps.lab.home.arpa` | Argo CD |
| `grafana.apps.lab.home.arpa` | Grafana |
| `immich.apps.lab.home.arpa` | Immich |
| `ai.apps.lab.home.arpa` | LiteLLM gateway |
| `ha.apps.lab.home.arpa` | Home Assistant |
| `authelia.apps.lab.home.arpa` | Authelia (SSO) |
| `lldap.apps.lab.home.arpa` | lldap (LDAP directory UI) |
| `semaphore.apps.lab.home.arpa` | Semaphore (Ansible UI) |
| `minio.apps.lab.home.arpa` | Minio (S3 API) |
| `minio-console.apps.lab.home.arpa` | Minio console |
| `stt.apps.lab.home.arpa` | Whisper STT |
| `*.apps.lab.home.arpa` | → 192.168.1.160 (Traefik ingress) |

## Fleet

| Host | Ansible name | IP | Role |
|------|--------------|----|------|
| Odroid-H4 Ultra | h4-core | 192.168.1.160 | k3s server + NAS (smbd/NFS) |
| N150 mini PC #1 | n150-1 | 192.168.1.42 | k3s server + KVM hypervisor (Ubuntu 24.04) |
| N150 mini PC #2 | n150-2 | 192.168.1.21 | k3s server + KVM hypervisor (Ubuntu 24.04) |
| Orange Pi 5 Pro #1 | opi5pro-1 | 192.168.1.168 | k3s agent, RKLLama/Ollama inference, NPU |
| Orange Pi 5 Pro #2 | opi5pro-2 | 192.168.1.172 | k3s agent, RKLLama/Ollama inference, NPU |
| Raspberry Pi 5 | rpi5 | 192.168.1.128 | HashiCorp Vault |
| Raspberry Pi 4B | rpi4b | 192.168.1.116 | Pi-hole secondary DNS (v6, Bookworm) |
| RPi 3B #2 (octopi) | octopi | 192.168.1.148 | Pi-hole primary DNS (v6.4.3, Bookworm) |
| N150 mini PC #3 | n150-3 | 192.168.1.176 | Windows HTPC (WinRM managed) |
| OPi Zero 2W #1 | opi-zero2w-1 | 192.168.1.184 | dnsmasq DNS tertiary fallback |
| OPi Zero 2W #2 | opi-zero2w-2 | 192.168.1.188 | MQTT primary broker |
| OPi Zero 2W #3 | opi-zero2w-3 | 192.168.1.217 | dnsmasq DNS secondary (Armbian Trixie) |
| OPi Zero 2W #4 | opi-zero2w-4 | 192.168.1.99 | MQTT secondary broker (HA bridge) |
| Odroid XU3 | xu3-1 | 192.168.1.64 | Build agent |

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
- [ ] Rotate sudo passwords on n150-1/n150-2 (exposed in terminal output 2026-07-18 — run `rotate-passwords.yml`)
- [ ] Upgrade rknpu driver 0.9.6 → 0.9.7 to unlock 3B+ model support on opi5pro-1/2
- [ ] Fix Ollama image pin + Whisper versioned tag (required by Kyverno `disallow-latest-tag` policy)
- [ ] Investigate Authelia health stuck Progressing in ArgoCD

### Longer term
- [ ] Vault TLS — currently plain HTTP; wire cert-manager before exposing beyond LAN
- [ ] Windows Update automation (`windows-updates.yml`) — `ansible.windows.win_updates` module ready, playbook not yet written
- [ ] Remote access — WireGuard or Tailscale

### Done ✅
- [x] octopi flashed to Bookworm, Pi-hole v6.4.3 running (2026-07-13)
- [x] RPi 4B: Pi-hole v6 secondary DNS live at 192.168.1.116 (2026-07-02)
- [x] n150-1/n150-2 joined as k3s server nodes, kube-vip VIP 192.168.1.200 (2026-07-02)
- [x] lldap migrated from ldap-1 VM to k3s Deployment in `lldap` namespace (2026-07-04)
- [x] Authelia → PostgreSQL backend (2026-07-03)
- [x] Immich library → NFS ReadWriteMany PV (schedules on any node) (2026-07-04)
- [x] Shared NFS storage between n150-1/n150-2 for VM live migration (2026-07-03)
- [x] Monitoring stack migrated to n150-1 (2026-07-04)
- [x] zswap on n150-1/n150-2 (zstd, zsmalloc, 20%) (2026-07-03)
- [x] MQTT HA: opi-zero2w-4 secondary broker with bidirectional bridge (2026-07-10)
- [x] Kyverno 3 ClusterPolicies in Enforce mode (2026-07-14)
- [x] ArgoCD notifications + git-directory ApplicationSet (2026-07-14)
- [x] Semaphore Ansible UI live (2026-07-18)
- [x] OpenTofu state in Minio; gitlab-1 VM codified (2026-07-18)
- [x] Offsite restic backup target (backup-offsite.timer)
