# Services & Software Catalog

Everything the design implies, so you can tick what's needed and spot gaps. Status:

- **✓** already running in your lab
- **●** chosen / built in this repo
- **○** suggested — a decision or gap

## Foundation / shared services

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| DNS (Pi-hole / dnsmasq) | ✓ | octopi RPi 3B #2 (.148, wired) | Pi-hole on dnsmasq; `lab.home.arpa` zone via custom records; ad-block for household clients |
| CoreDNS custom zone | ● | k3s kube-system | `coredns-custom` ConfigMap; wildcard `*.apps.lab.home.arpa → 192.168.1.160` for in-cluster pod resolution |
| lldap (directory) | ✓ | k3s · lldap namespace | lightweight LDAP; web UI `lldap.apps.lab.home.arpa`; LDAP :3890; `dc=lab,dc=home,dc=arpa`; SQLite on local-path PVC; ldap-1 VM decommissioned |
| Authelia (OIDC / SSO) | ✓ | k3s · authelia namespace | OIDC provider backed by lldap; gates Immich SSO; `authelia.apps.lab.home.arpa` |
| Vault (secrets / PKI) | ✓ | RPi 5 (.128) | init/unseal manual; `secret/lab/*` for cluster secrets |
| External Secrets Operator | ● | k3s | Vault → k8s Secrets |
| cert-manager + lab CA | ✓ | k3s | `lab-ca` ClusterIssuer (self-signed root); signs `*.apps.lab.home.arpa` TLS certs |
| NAS (NFS / SMB) | ✓ | H4 (.160) | `smbd` + `nfs-kernel-server`; **do not restart** |
| restic backups | ✓ | H4 (md1 8TB → md0 ~5.45TB) | NAS + Immich library daily; etcd weekly; offsite via `backup-offsite.timer` |
| smartd / mdadm monitor | ✓ | H4 | SMART 199 + media attrs; email + mdadm alerts on degraded mirror |
| Grafana | ✓ | k3s | `grafana.apps.lab.home.arpa` |
| Prometheus | ● | k3s | metrics scrape |
| OpenTelemetry | ○ | k3s | traces pipeline |
| Loki (logs) | ○ | k3s | |
| Alertmanager | ○ | k3s | |
| MQTT broker (Mosquitto) | ✓ | opi-zero2w-2 (.188) primary · opi-zero2w-4 (.99) secondary | HA bridge — topics mirrored bidirectionally at QoS 1; M5Stack auto-fails over to secondary |
| chrony / NTP | ○ | all hosts | load-bearing for LDAP/k8s cert validity |

## IaaS (L1)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| KVM / libvirt | ✓ | n150-1 (.42) + n150-2 (.21) | bare-metal Ubuntu 24.04 hypervisors; cloud-init VMs |
| NFS storage for VMs | ○ | H4 exports → n150 hosts | shared VM disk storage |
| n150-3 (yikw) | ✓ | Windows HTPC | TV/browse; not a hypervisor |

## Platform / CaaS (L2)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| k3s (H4 server + opi5pro-2 agent) | ✓ | H4 (.160) server · opi5pro-2 (.172) arm64 agent | single-server cluster; `local-path` StorageClass on NVMe |
| Argo CD | ✓ | k3s | GitOps; app-of-apps from `gitops/apps/`; selfHeal + prune on |
| Traefik ingress | ✓ | k3s | k3s default; all `*.apps.lab.home.arpa` Ingresses; TLS via cert-manager |
| Helm + Kustomize | ● | CASC | used by ArgoCD |
| Kyverno / OPA (policy) | ○ | k3s | |
| Linkerd (service mesh) | ○ | k3s | optional |

## AI / Inference

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| RKLLama (NPU LLM) | ✓ | opi5pro-1 (.168) | ~7–8 tok/s 3B on RK3588 NPU |
| OpenVINO Model Server | ● | H4 + N150 iGPUs | embeddings / STT / vision |
| LiteLLM gateway | ✓ | k3s · `ai.apps.lab.home.arpa` | unifies backends |
| m5stack-adapter | ● | k3s | OpenAI shim for M5Stack |
| Claude Code orchestrator | ● | opi5pro-1 | escalation Tier 3 |
| M5Stack escalation router | ✓ | M5Stack | edge front-end; 3-tier escalation |
| Whisper STT | ○ | OpenVINO | faster-than-realtime |
| Embedding model (bge-small) | ○ | OpenVINO | RAG |
| Vector DB (Qdrant / Chroma) | ○ | k3s | RAG store |
| Ollama / llama.cpp | ○ | H4 CPU | fallback engine |

## Software dev

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| GitLab (SCM / CI / registry) | ● | KVM VM on n150-1 | provisioned by cloud-init/Ansible |
| GitLab Runners | ● | N150 VMs / k3s | |
| Multi-arch buildx | ● | runners | x86 + arm64 |
| Renovate (dep updates) | ● | `renovate.json` in repo | Mend hosted |
| Claude Code | ● | orchestrator / dev | agentic |

## Provisioning (CASC)

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| Ansible | ✓ | control node | host config; `ansible/playbooks/`; vault-encrypted secrets |
| KVM + cloud-init | ✓ | n150-1/2 | VMs via `virt-install`; SSH-ready |
| rpi-imager / cloud-init | ● | flashing | SD-card SBCs |
| PlatformIO / ESPHome / OTA | ● | firmware | microcontrollers |

## Edge / IoT / single-purpose

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| M5Stack framework | ✓ | M5Stack | sensors + escalation router |
| Pi-hole | ✓ | octopi (.148) | DNS + ad-block |
| MQTT (Mosquitto) | ✓ | opi-zero2w-2 (.188) | always-on broker |
| Home Assistant | ○ | TBD | natural MQTT consumer; optional |

## Applications

| Service | Status | Placement | Notes |
|---------|:------:|-----------|-------|
| Immich — server | ✓ | k3s · immich namespace | self-hosted photos/video; SSO via Authelia OIDC; `immich.apps.lab.home.arpa` |
| Immich — machine learning | ✓ | k3s (CPU default) | Smart Search + face recog |
| Immich — Postgres (vectorchord) | ✓ | NVMe hot (`local-path` PV) | vector extension mandatory; nightly dump → md1 |
| Immich — Redis | ✓ | k3s (ephemeral) | cache |

Immich authenticates via **Authelia OIDC** (SSO) or direct login. The Node.js runtime
trusts the lab root CA via `NODE_EXTRA_CA_CERTS`, so TLS to `authelia.apps.lab.home.arpa`
validates correctly.

## Gaps worth a decision

1. **Home Assistant** — *deferred.* Natural MQTT consumer if/when you want home-automation.
2. **Remote access** — WireGuard or Tailscale to reach the lab from outside.
3. ~~**Reverse proxy + internal CA + SSO**~~ — **DONE.** Traefik ingress + cert-manager lab-ca + Authelia OIDC all deployed.
4. ~~**MQTT broker**~~ — **DONE.** Relocated to always-on Zero 2W.
5. ~~**Offsite backup**~~ — **DONE.** Nightly `restic copy` via `backup-offsite.timer`.
6. **UPS + NUT** — *deferred.* The H4 is a single storage point; a UPS is cheap insurance.
7. **Homepage / dashboard** — landing page once 30+ services are running.
8. **Shared DB service** — CloudNativePG + Redis operators if more apps need state.
9. **k8s device plugins (rknpu / Intel-GPU)** — only if inference runs *in* k8s rather than bare-metal.
10. **RPi 4B reassignment** — now spare (lldap took over LDAP from what was planned for it).
