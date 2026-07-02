# Hardware Inventory & Roles

Subnet: `192.168.1.0/24`. Gateway: `192.168.1.1`.
Last verified: 2026-06-29.

> **Security:** Default passwords (`pi`/`odroid`/`root`) have been rotated on all managed
> hosts via `ansible/playbooks/rotate-passwords.yml`. Credentials are in Ansible Vault —
> never committed in plaintext. Access is SSH key + sudo.

## Compute

| Device | CPU | RAM | Wired IP | WiFi IP | Role |
|--------|-----|-----|----------|---------|------|
| **Odroid-H4 Ultra** | i3-N305 8C/8T x86 | 64 GB DDR5 | `192.168.1.160` | — | **Core: k3s server + NAS** |
| **Orange Pi 5 Pro #1** | RK3588S 8C ARM | 16 GB | `192.168.1.168` | — | k3s agent · Ollama inference · Arch Linux ARM |
| **Orange Pi 5 Pro #2** | RK3588S 8C ARM | 16 GB | `192.168.1.172` | — | k3s agent · Ollama inference · Ubuntu 22.04 |
| **N150 mini PC #1** | Intel N150 4C x86 | 16 GB | `192.168.1.42` (br0) | — | KVM hypervisor · Ubuntu 24.04 · hosts ldap-1 VM |
| **N150 mini PC #2** | Intel N150 4C x86 | 16 GB | `192.168.1.21` (br0) | — | KVM hypervisor · Ubuntu 24.04 |
| **N150 mini PC #3 (HTPC)** | Intel N150 4C x86 | 16 GB | — | `192.168.1.176` | Living-room HTPC |
| **RPi 5** | Cortex-A76 4C | 8 GB | `192.168.1.128` | `192.168.1.124` (avoid) | HashiCorp Vault |
| **RPi 4B** | Cortex-A72 4C | 8 GB | `192.168.1.116` | — | DNS secondary (Pi-hole v6) |
| **RPi 3B #2** | Cortex-A53 4C | 1 GB | `192.168.1.148` | `192.168.1.152` (avoid) | DNS primary (Pi-hole pending — needs Bookworm flash) |
| **RPi 3B #1** | Cortex-A53 4C | 1 GB | — | — | ⚠ on-board power fault — retired |
| **Odroid-XU3 #1** | Exynos5422 8C | 2 GB | `192.168.1.64` | — | Build agent (Python <3.8 — excluded from Ansible auto-updates) |
| **Orange Pi Zero 2W #1** | H618 A53 4C | 4 GB | — | `192.168.1.184` | DNS secondary (dnsmasq) |
| **Orange Pi Zero 2W #2** | H618 A53 4C | 4 GB | — | `192.168.1.188` | MQTT broker (Mosquitto) |
| **Orange Pi Zero 2W #3** | H618 A53 4C | 4 GB | — | TBD | Unassigned |
| **Orange Pi Zero 2W #4** | H618 A53 4C | 4 GB | — | `192.168.1.99` | Unassigned |
| **M5Stack LLM** | ESP32-S3 | — | — | USB | Edge AI inference |
| **HostMon** | ESP32-S3 (Waveshare 4.3") | 8 MB PSRAM | LAN | — | Host prober + status panel |

## VMs

| VM | Host | IP | OS | Role |
|----|------|----|----|------|
| **ldap-1** | n150-1 | `192.168.1.70` | Ubuntu 24.04 | lldap v0.6.3 · LDAP/SSO directory |

## Network

| Device | MAC | Notes |
|--------|-----|-------|
| H4 Ultra | `00:1E:06:45:99:E5` | 2.5 Gbps wired |
| OPi 5 Pro #1 | `C0:74:2B:FB:46:B9` | 1 Gbps wired |
| N150 #1 br0 | `4A:6D:B5:BC:56:98` | 1 Gbps wired · KVM bridge MAC · `192.168.1.42` reserved |
| N150 #2 br0 | `16:3C:00:47:C0:6E` | 1 Gbps wired · KVM bridge MAC · `192.168.1.21` reserved |
| N150 #3 (HTPC) | `98:BD:80:5C:4C:D4` | WiFi 5 |
| RPi 5 (wired) | `2C:CF:67:EF:E2:B3` | Use wired `.128` for Vault |
| RPi 4B (wired) | `DC:A6:32:4E:4A:8B` | Use wired `.116` for DNS secondary |
| RPi 4B (WiFi)  | `DC:A6:32:4E:4A:8C` | Avoid — use wired |
| RPi 5 (WiFi) | `2C:CF:67:EF:E2:B4` | Avoid — use wired |
| RPi 3B #2 (wired) | `B8:27:EB:E7:43:73` | DNS primary |
| RPi 3B #2 (WiFi) | `B8:27:EB:B2:16:26` | Avoid |
| OPi Zero 2W #1 | `20:1A:F8:6B:D8:CB` | DNS secondary |
| OPi Zero 2W #2 | `E0:22:90:6E:5E:3A` | MQTT |
| OPi Zero 2W #4 | `38:BD:01:3B:8A:30` | — |
| XU3 #1 | `00:1E:06:61:7A:39` | 1 Gbps wired |
| HostMon (Waveshare ESP32-S3) | `DC:DA:0C:48:AB:D0` | 1 Gbps wired · `192.168.1.82` |
| M5Stack LLM (ESP32-S3, station) | `48:27:E2:79:0D:98` | wired `192.168.1.71` · use this for web UI |
| M5Stack LLM (ESP32-S3, AP mode) | `4E:DC:AD:93:76:5A` | `192.168.1.66` · only when in AP/config mode |

## Storage (H4 core)

| Tier | Device | Mount | Capacity | Purpose |
|------|--------|-------|----------|---------|
| OS | eMMC 256 GB | `/` | 256 GB | Host OS |
| Hot | NVMe 4 TB (LVM loop) | `/mnt/nvme0n1p2` | 4 TB | k3s PVs · live NAS (`/srv/nas`) |
| Cold primary | 8 TB RAID 1 (`/dev/md1`) | `/mnt/cold-8t` | 8 TB | restic repo · k3s SQLite backups · Immich library |
| Cold secondary | ~5.45 TB RAID 1 (`/dev/md0`) | `/mnt/cold-sec` | ~5.45 TB | `restic copy` of primary repo |

LVM VG `vg_microshift` is backed by a sparse loop device (`/mnt/nvme0n1p2/microshift-lvm.img`, `/dev/loop100`).
k3s PVs use the `local-path` StorageClass. Never provision against `lv_nas`.

## k3s Cluster

| Node | Role | IP | OS | Notes |
|------|------|----|-----|-------|
| `odroid-nas` | server | `192.168.1.160` | Ubuntu 22.04 | H4 Ultra |
| `opi5pro-1` | agent | `192.168.1.168` | Arch Linux ARM | `role=inference`; NVMe-backed Ollama PVC |
| `opi5pro-2` | agent | `192.168.1.172` | Ubuntu 22.04 | `role=inference`; NVMe-backed Ollama PVC |

Ingress: Traefik. DNS: `*.apps.lab.home.arpa` → `192.168.1.160`.
ArgoCD bootstraps all workloads from `gitops/` via `gitops/bootstrap/root-app.yaml`.
CoreDNS extended with `coredns-custom` ConfigMap for in-cluster `*.apps.lab.home.arpa` resolution.

## AI / Inference

| Device | Accelerator | Capacity |
|--------|-------------|----------|
| OPi 5 Pro ×2 | RK3588S NPU | 6 TOPS @ INT8 each |
| M5Stack LLM | NPU | ~6 TFLOPS |
| H4 Ultra | Intel iGPU (32 EU) | OpenVINO |
| N150 ×3 | Intel iGPU (24 EU) | OpenVINO (no NPU) |
| RPi 5 | VideoCore VII (12 EU) | light inference |

## Services Map

| Service | Host | Address |
|---------|------|---------|
| ArgoCD | H4 (k3s) | `https://argocd.apps.lab.home.arpa` |
| Immich | H4 (k3s) | `https://immich.apps.lab.home.arpa` |
| Authelia | H4 (k3s) | `https://authelia.apps.lab.home.arpa` |
| AI Gateway (LiteLLM) | H4 (k3s) | `https://ai.apps.lab.home.arpa` |
| Ollama #1 | opi5pro-1 (k3s) | ClusterIP `:11434` |
| Ollama #2 | opi5pro-2 (k3s) | ClusterIP `:11434` |
| lldap | ldap-1 VM (n150-1) | `http://192.168.1.70:17170` (UI) · `:3890` (LDAP) |
| HashiCorp Vault | RPi 5 | `http://192.168.1.128:8200` |
| DNS primary | RPi 3B #2 | `192.168.1.148` (Pi-hole pending) |
| DNS secondary | OPi Zero 2W #1 | `192.168.1.184` (dnsmasq fallback) |
| DNS secondary | RPi 4B | `192.168.1.116` (Pi-hole v6) |
| MQTT | OPi Zero 2W #2 | `192.168.1.188:1883` |

## Pending / TODO

- octopi (RPi 3B #2): flash Bookworm → run dns.yml → Pi-hole v6
- Rotate lldap JWT secret (exposed in terminal session 2026-06-29)
- Store n150-1/n150-2 sudo password in Ansible Vault
- RPi 4B: confirm OS is Raspberry Pi OS Bookworm before running dns.yml
- ArgoCD deploy key (`~/.ssh/argocd-deploy-key`): back up to Vault
- Apply zswap role to n150-1/n150-2 (Ubuntu 24.04 kernel 6.8 has zswap)
- N150 #3: WinRM credentials (wrong password on file)
