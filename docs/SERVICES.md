# Services & Software Catalog

Everything the design implies, so you can tick what's needed and spot gaps. Status:

- **✓** already running in your lab
- **●** chosen / built in this repo
- **○** suggested — a decision or gap

## Foundation / shared services

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| DNS (Pi-hole / dnsmasq) | ● | RPi 3B #2 (.59, **wired**) + Zero 2W secondary | Pi-hole on the dnsmasq engine; lab zone via Ansible `dns.yml`; ad-block scoped to household clients |
| OpenLDAP (directory) | ● | RPi 4B (.99) | `make ldap` |
| SSO (Keycloak / Authentik) | ○ | in-cluster | one login for Proxmox/Grafana/GitLab/Argo/Vault UIs |
| Vault (secrets / PKI) | ● | RPi 5 (.67) | `make vault` (init/unseal manual) |
| External Secrets Operator | ● | in-cluster | Vault → k8s |
| NAS (NFS / SMB) | ● | H4 (.64) | |
| MinIO (S3) | ● | H4 | models, datasets, registry, Glance images |
| restic backups | ● | H4 (md1 8TB → md0 ~5.45TB) → offsite | bulk library → offsite; critical set → local secondary; nightly `restic copy` via timers |
| smartd (SMART alerts) | ● | H4 | watches SMART 199 (UDMA CRC) + media attrs; email on failure |
| mdadm monitor | ● | H4 | alerts on a degraded / dropped RAID 1 mirror member |
| OpenTelemetry | ✓ | OPi 5 Pro #2 | |
| Grafana | ✓ | in-cluster | |
| Prometheus | ● | in-cluster | |
| HostMon (black-box prober) | ● | Waveshare ESP32-S3 (edge) | ping/DNS/port/HTTP/SSL-expiry/trace probes + LCD status panel; webhook alerts; behind proxy/VLAN |
| Loki (logs) | ○ | in-cluster | |
| Tempo (traces) | ○ | in-cluster | |
| Alertmanager | ○ | in-cluster | |
| cert-manager | ● | in-cluster | |
| Internal CA (step-ca / ACME) | ○ | TBD | for internal TLS |
| chrony / NTP | ○ | all hosts | trivial but load-bearing for LDAP/k8s |

## IaaS (L1)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| Proxmox VE | ● | N150 ×3 | the cluster |
| OpenTofu + `bpg/proxmox` | ● | `terraform/` | built |
| OpenNebula | ✓ | H4 | installed; optional/alt |
| OpenStack (Sunbeam) | ○ | nested VM | optional learning track |

## Platform / CaaS (L2)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| k3s (bare-metal ARM) | ● | OPi 5 Pro ×2 + Zero 2W agents | AI/NPU tier |
| Platform k3s / MicroShift (in VMs) | ● | Proxmox VMs | devops playground |
| Argo CD | ● | in-cluster | GitOps |
| Helm + Kustomize | ● | CASC | |
| Ingress (Traefik / nginx) | ○ | in-cluster | |
| Kyverno / OPA (policy) | ○ | in-cluster | |
| Linkerd (service mesh) | ○ | in-cluster | light mesh; optional |
| CSI (local-path / NFS-CSI / Longhorn) | ○ | in-cluster | pick a storage class |

## AI / Inference

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| RKLLama (NPU LLM) | ● | OPi 5 Pro ×2 | ~7–8 tok/s 3B |
| OpenVINO Model Server (iGPU) | ● | H4 + N150 iGPUs | embeddings/STT/vision |
| LiteLLM gateway | ● | in-cluster | unifies backends |
| m5stack-adapter | ● | in-cluster | built (OpenAI shim) |
| Claude Code orchestrator | ● | OPi 5 Pro #1 | escalation Tier 3 |
| M5Stack escalation router | ✓ | M5Stack | edge front-end |
| Whisper STT | ○ | OpenVINO | faster-than-realtime |
| Embedding model (bge-small) | ○ | OpenVINO | RAG |
| Vector DB (Qdrant / Chroma) | ○ | in-cluster | RAG store |
| JupyterHub | ○ | H4 | needs the RAM |
| MLflow (experiment tracking) | ○ | in-cluster / H4 | |
| DVC (data/version) | ○ | with Git | |
| Label Studio | ○ | in-cluster | annotation |
| Ollama / llama.cpp | ○ | H4 CPU | fallback engine |

## Software dev

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| GitLab (SCM / CI / registry) | ● | **Proxmox VM** (n150-1) | moved off OPi 5 Pro #2 to de-load the AI board; provisioned by OpenTofu, k3s/host by Ansible |
| GitLab Runners | ● | N150 VMs / k8s | |
| Multi-arch buildx | ● | runners | x86 + arm64 |
| Renovate (dep updates) | ○ | CI | |
| Coder / devcontainers | ○ | VMs | ephemeral dev envs |
| Claude Code | ● | orchestrator / dev | agentic |
| Harbor | ○ | — | optional; GitLab registry usually covers it |

## Provisioning (CASC)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| Ansible | ✓ | control node | host config |
| OpenTofu + cloud-init | ● | `terraform/` | VMs |
| rpi-imager / cloud-init | ● | flashing | SD-card SBCs, SSH-ready |
| PlatformIO / ESPHome / OTA | ● | firmware | microcontrollers |
| netboot.xyz | ○ | — | optional x86 PXE |

## Edge / IoT / single-purpose

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| M5Stack framework | ✓ | M5Stack | sensors + router |
| OctoPi | ✓ | — | **3D printer offline**; host repurposed to DNS |
| MQTT broker (Mosquitto) | ● | **lab Zero 2W** (`make mqtt`) | relocated off dad's laptop to an always-on broker; laptop kept as a dev target. Point the framework here |
| Home Assistant | ○ | TBD | natural MQTT consumer; optional |

> **HostMon vs. Prometheus.** HostMon is an *active prober* — it reaches out and asks "is this host/port/cert reachable from here, right now," from a fixed vantage point, and shows fleet health on its LCD. The in-cluster Prometheus/Grafana stack *pulls* rich internal metrics (CPU/RAM/disk/container health) over time. They're complementary: black-box reachability vs. white-box telemetry. HostMon complements, not replaces, the metrics stack — and its SSL-expiry check pairs well with the planned internal CA. Route its **webhook** at the lab's alert relay (MQTT/ntfy/Home Assistant), and front its HTTP-only dashboard with the **reverse proxy** (or keep it on a trusted/IoT VLAN).

## Applications

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| Immich — server | ● | H4 MicroShift · library on md1 (`/mnt/cold-8t`) | self-hosted photos/video; Argo workload |
| Immich — machine learning | ● | H4 **CPU default** (OpenVINO or OPi `rknn` optional) | Smart Search + face recog; accel is best-effort, see workload README |
| Immich — Postgres (vectorchord) | ● | NVMe hot (topolvm) | vector extension **mandatory**; nightly dump → md1 library |
| Immich — Redis | ● | H4 (ephemeral) | cache |

Immich is the first real end-user app. Its ML (Smart Search + face recog) runs on **CPU by
default**; acceleration is optional and best-effort — **OpenVINO** on the H4 iGPU (Immich warns
integrated graphics may have issues) or, more robustly, the **`rknn` backend on an OPi 5 Pro NPU**
via remote ML. So it's a *candidate* OpenVINO/NPU consumer, not a guaranteed one.

## Gaps worth a decision

1. ~~**MQTT broker (Mosquitto)**~~ — **DONE.** Relocated to an always-on lab Zero 2W (`make mqtt`); dad's laptop kept as a dev target.
2. **Home Assistant** — *deferred by choice (future improvement).* The natural MQTT consumer if/when you want the home-automation side.
3. **Reverse proxy + internal CA + SSO** — a dozen web UIs are coming; ingress + cert-manager/step-ca + Keycloak/Authentik keeps them sane.
4. **Remote access** — WireGuard or Tailscale to reach the lab from outside.
5. ~~**Offsite backup (the "1" in 3-2-1)**~~ — **DONE.** Nightly `restic copy` to an offsite repo (B2/rclone) via `backup-offsite.timer`; set `offsite_restic_repo` + creds in `/etc/restic/offsite.env` (from Vault).
6. **Shared database service** — CloudNativePG (Postgres) + Redis operators if apps need state beyond GitLab.
7. **UPS + NUT** — *deferred by choice (future improvement).* The H4 is a single storage point; a UPS + Network UPS Tools is cheap insurance when you're ready.
8. **Homepage / dashboard** — a landing page once 30+ services are running. *(Black-box uptime is now partly covered by **HostMon** — the ESP32-S3 prober + LCD panel; a software status page is still nice-to-have.)*
9. **k8s device plugins (rknpu / Intel-GPU)** — only if you run inference *in* k8s rather than bare-metal.
