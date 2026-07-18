# Services & Software Catalog

Everything the design implies, so you can tick what's needed and spot gaps. Status:

- **✓** already running in your lab
- **●** chosen / built in this repo
- **○** suggested — a decision or gap

## Foundation / shared services

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| DNS (Pi-hole / dnsmasq) | ✓ | octopi RPi 3B #2 (.148, wired) primary · RPi 4B (.116) secondary | Pi-hole on dnsmasq; `lab.home.arpa` zone via custom records; ad-block for household clients |
| CoreDNS custom zone | ● | k3s kube-system | `coredns-custom` ConfigMap; wildcard `*.apps.lab.home.arpa → 192.168.1.160` for in-cluster pod resolution |
| lldap (directory) | ✓ | k3s · lldap namespace | lightweight LDAP; web UI `lldap.apps.lab.home.arpa`; LDAP :3890; `dc=lab,dc=home,dc=arpa`; SQLite on local-path PVC; ldap-1 VM decommissioned |
| Authelia (OIDC / SSO) | ✓ | k3s · authelia namespace | OIDC provider backed by lldap; gates Immich SSO; `authelia.apps.lab.home.arpa` |
| Vault (secrets / PKI) | ✓ | RPi 5 (.128) | auto-unseal via `vault-unseal.service` on H4; `secret/lab/*` for cluster secrets |
| External Secrets Operator | ✓ | k3s | Vault → k8s Secrets; all namespaces using ClusterSecretStore `vault-backend` |
| cert-manager + lab CA | ✓ | k3s | `lab-ca` ClusterIssuer (self-signed root); signs `*.apps.lab.home.arpa` TLS certs |
| NAS (NFS / SMB) | ✓ | H4 (.160) | `smbd` + `nfs-kernel-server`; **do not restart** |
| restic backups | ✓ | H4 (md1 8TB → md0 ~5.45TB) | NAS + Immich library daily; etcd weekly; offsite via `backup-offsite.timer` |
| Minio (object store) | ✓ | k3s · minio namespace (n150-1) | S3-compatible; `minio.apps.lab.home.arpa` (API) + `minio-console.apps.lab.home.arpa`; `tofu-state` bucket holds OpenTofu state; creds from Vault `secret/lab/minio` |
| smartd / mdadm monitor | ✓ | H4 | SMART 199 + media attrs; email + mdadm alerts on degraded mirror |
| Grafana | ✓ | k3s | `grafana.apps.lab.home.arpa` |
| Prometheus | ✓ | k3s · monitoring namespace (n150-1) | kube-prometheus-stack; `prometheus.apps.lab.home.arpa`; 30d / 40GB retention |
| OpenTelemetry | ○ | k3s | traces pipeline — deferred; no active use case driving it |
| Loki (logs) | ✓ | k3s · monitoring namespace (n150-1) | SingleBinary mode; `loki.apps.lab.home.arpa`; 30d retention; logs shipped via Alloy |
| Alertmanager | ✓ | k3s · monitoring namespace (n150-1) | part of kube-prometheus-stack; routes to m5stack-adapter webhook |
| MQTT broker (Mosquitto) | ✓ | opi-zero2w-2 (.188) primary · opi-zero2w-4 (.99) secondary | HA bridge — topics mirrored bidirectionally at QoS 1; M5Stack auto-fails over to secondary |
| chrony / NTP | ✓ | all Linux hosts | h4-core serves stratum 2 to LAN; all others peer against it; Arch hosts use timesyncd; xu3-1 excluded (old Python) |

## IaaS (L1)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| KVM / libvirt | ✓ | n150-1 (.42) + n150-2 (.21) | bare-metal Ubuntu 24.04 hypervisors; cloud-init VMs |
| NFS storage for VMs | ✓ | H4 exports `/srv/libvirt-shared` → n150-1 + n150-2 | `libvirt-shared` pool active on both nodes; enables VM live migration |
| n150-3 (yikw) | ✓ | Windows HTPC | TV/browse; not a hypervisor |

## Platform / CaaS (L2)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| k3s (3 servers + 2 agents) | ✓ | H4 (.160) + n150-1 (.42) + n150-2 (.21) servers · opi5pro-1 (.168) + opi5pro-2 (.172) arm64 agents | HA 3-node cluster; kube-vip VIP 192.168.1.200; `local-path` StorageClass on NVMe |
| Argo CD | ✓ | k3s | GitOps; app-of-apps + `workloads` ApplicationSet (git directory generator); selfHeal + prune on; notifications → M5Stack webhook on sync-fail/degraded |
| Traefik ingress | ✓ | k3s | k3s default; all `*.apps.lab.home.arpa` Ingresses; TLS via cert-manager |
| Helm + Kustomize | ● | CASC | used by ArgoCD |
| Kyverno (policy) | ✓ | k3s | 3 ClusterPolicies in Enforce mode: `disallow-privileged-containers`, `disallow-latest-tag`, `require-resource-limits` |
| Semaphore (Ansible UI) | ✓ | k3s · semaphore namespace (n150-1) | `semaphore.apps.lab.home.arpa`; BoltDB replaced by SQLite; creds from Vault `secret/lab/semaphore` |
| Linkerd (service mesh) | ○ | k3s | optional |

## AI / Inference

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| RKLLama (NPU LLM) | ✓ | opi5pro-1 (.168) + opi5pro-2 (.172) | DeepSeek-R1-Distill-Qwen-1.5B_w8a8_g128; driver 0.9.6 limits NPU alloc to ~2.2 GB (blocks 3B+); upgrade to 0.9.7 to unlock |
| OpenVINO Model Server | ● | H4 + N150 iGPUs | embeddings / STT / vision — suspended; crash-looping on n150-1, scaled to 0 pending fix |
| LiteLLM gateway | ✓ | k3s · `ai.apps.lab.home.arpa` | unifies backends |
| m5stack-adapter | ✓ | k3s · odroid-nas node | OpenAI shim for M5Stack; image 0.1.1 (2026-07-11); models: m5, m5-llm, m5-claude |
| Claude Code orchestrator | ✓ | opi5pro-1 | escalation Tier 3; HTTPS :8443; TLS self-signed; Claude Code 2.1.204 |
| M5Stack escalation router | ✓ | M5Stack | edge front-end; 3-tier escalation |
| Whisper STT | ✓ | k3s · whisper namespace (n150-1, CPU) | `https://stt.apps.lab.home.arpa/v1/audio/transcriptions`; base model; TLS via lab-ca |
| Embedding model (nomic-embed-text) | ● | Ollama on H4 | configured in LiteLLM as `openai/nomic-embed-text`; bge-small via OpenVINO deferred |
| Vector DB (Qdrant / Chroma) | ○ | k3s | RAG store — deferred; embeddings ready (nomic-embed-text via Ollama) but no RAG use case yet |
| Ollama / llama.cpp | ✓ | k3s · ai-gateway namespace (opi5pro-1/2, arm64) | fallback engine + nomic-embed-text embeddings; pinned to `ollama/ollama:0.32.0`; both nodes pre-staged before pin |

## Software dev

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| GitLab (SCM / CI / registry) | ● | gitlab-1 VM (.50) on n150-1 | provision-gitlab-vm.yml → install-gitlab.yml; gitlab.lab.home.arpa; runner token → Vault secret/lab/gitlab |
| GitLab Runners | ● | k3s · gitlab-runner namespace | kubernetes executor; Helm via ArgoCD; needs runner token in Vault before sync |
| Multi-arch buildx | ● | runners | x86 + arm64 |
| Renovate (dep updates) | ● | `renovate.json` in repo | Mend hosted |
| Claude Code | ● | orchestrator / dev | agentic |

## Provisioning (CASC)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| Ansible | ✓ | control node | host config; `ansible/playbooks/`; vault-encrypted secrets |
| OpenTofu — VMs | ✓ | `tofu/vms/` | gitlab-1 VM codified (UUID `6ea193a5`); `ignore_changes = all` + `prevent_destroy`; state in Minio `tofu-state/vms/terraform.tfstate`; init with `~/.tofu-backend.hcl` |
| OpenTofu — DNS | ● | `tofu/dns/` | Parked — `ryanwholey/pihole v0.2` uses Pi-hole v5 session API; incompatible with Pi-hole v6 on octopi. DNS managed via Ansible `playbooks/dns.yml` instead. |
| KVM + cloud-init | ✓ | n150-1/2 | VMs via `virt-install`; SSH-ready |
| rpi-imager / cloud-init | ● | flashing | SD-card SBCs |
| PlatformIO / ESPHome / OTA | ● | firmware | microcontrollers |

## Edge / IoT / single-purpose

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| M5Stack framework | ✓ | M5Stack | sensors + escalation router |
| Pi-hole | ✓ | octopi (.148) | DNS + ad-block |
| MQTT (Mosquitto) | ✓ | opi-zero2w-2 (.188) | always-on broker |
| Pi-hole secondary DNS | ✓ | RPi 4B (.116) | Pi-hole secondary DNS; wired only; see Foundation table for primary |

## Applications

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| Home Assistant | ✓ | k3s · home-assistant namespace | `ha.apps.lab.home.arpa`; MQTT consumer (broker at opi-zero2w-2 .188) |
| Immich — server | ✓ | k3s · immich namespace | self-hosted photos/video; SSO via Authelia OIDC; `immich.apps.lab.home.arpa` |
| Immich — machine learning | ✓ | k3s (CPU default) | Smart Search + face recog |
| Immich — Postgres (vectorchord) | ✓ | NVMe hot (`local-path` PV) | vector extension mandatory; nightly dump → md1 |
| Immich — Redis | ✓ | k3s (ephemeral) | cache |

Immich authenticates via **Authelia OIDC** (SSO) or direct login. The Node.js runtime
trusts the lab root CA via `NODE_EXTRA_CA_CERTS`, so TLS to `authelia.apps.lab.home.arpa`
validates correctly.

## Gaps worth a decision

1. ~~**Home Assistant**~~ — **DONE.** Running as a k3s Deployment in the `home-assistant` namespace (`ha.apps.lab.home.arpa`); MQTT consumer via broker at opi-zero2w-2 (.188).
2. **Remote access** — WireGuard or Tailscale to reach the lab from outside. *Very low priority.*
3. ~~**Reverse proxy + internal CA + SSO**~~ — **DONE.** Traefik ingress + cert-manager lab-ca + Authelia OIDC all deployed.
4. ~~**MQTT broker**~~ — **DONE.** Relocated to always-on Zero 2W.
5. ~~**Offsite backup**~~ — **DONE.** Nightly `restic copy` via `backup-offsite.timer`.
6. **UPS + NUT** — *deferred.* The H4 is a single storage point; a UPS is cheap insurance.
7. **Grafana dashboard** — basic lab health dashboard exists and working. Improvement need