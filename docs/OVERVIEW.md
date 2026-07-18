# Lab Overview

Current as of 2026-07-18. Detailed service catalog in [services.md](services.md), hardware in [HARDWARE.md](HARDWARE.md).

## Infrastructure & Platform

- **k3s cluster** — 3-node HA control plane: H4, n150-1, n150-2 as servers; opi5pro-1 and opi5pro-2 as ARM64 agents; `local-path` StorageClass on NVMe
- **ArgoCD** — GitOps from `gitops/`; selfHeal + prune on all apps; git-directory ApplicationSet for workloads
- **Traefik** — ingress for all `*.apps.lab.home.arpa`; TLS via cert-manager lab CA
- **kube-vip** — control-plane HA VIP (`192.168.1.200`)
- **KVM/libvirt** — bare-metal hypervisors on n150-1 and n150-2; shared NFS storage at `/srv/libvirt-shared` for VM live migration
- **OpenTofu** — VMs module codifies gitlab-1; state in Minio `tofu-state` bucket
- **Semaphore** — Ansible UI at `semaphore.apps.lab.home.arpa`; runs playbooks from a k3s pod
- **Kyverno** — 3 ClusterPolicies in Enforce mode: disallow-latest-tag, require-resource-limits, disallow-privileged-containers

## Identity & Security

- **lldap** — lightweight LDAP directory (`lldap.apps.lab.home.arpa`)
- **Authelia** — OIDC/SSO backed by lldap (`authelia.apps.lab.home.arpa`)
- **HashiCorp Vault** — secrets and PKI on RPi 5
- **External Secrets Operator** — syncs Vault secrets into k8s

## Networking & DNS

- **Pi-hole** — primary DNS + ad-blocking on octopi (192.168.1.148); secondary on RPi 4B (192.168.1.116); dnsmasq fallback on opi-zero2w-1
- **CoreDNS custom zone** — wildcard `*.apps.lab.home.arpa → 192.168.1.160` for in-cluster resolution
- **Mosquitto MQTT** — opi-zero2w-2 primary, opi-zero2w-4 HA bridge

## Observability

- **Grafana + Prometheus** — metrics (`grafana.apps.lab.home.arpa`)
- **Loki + Alloy** — log aggregation; Alloy runs as a DaemonSet (Promtail removed)
- **Alloy** — Grafana telemetry agent
- **node-exporter** — on non-cluster hosts
- **smartd / mdadm** — disk health and RAID alerting on H4

## AI & Inference

- **LiteLLM gateway** — unified OpenAI-compatible API across all backends (`ai.apps.lab.home.arpa`)
- **RKLLama** — NPU-native LLM on opi5pro-1 and opi5pro-2; running DeepSeek-R1-Distill-Qwen-1.5B_w8a8_g128 (~7–8 tok/s); rknpu driver 0.9.6 caps NPU alloc to ~2.2 GB (upgrade to 0.9.7 to unlock 3B+ models)
- **Ollama** — in-cluster fallback engine on opi5pro-1/2; pinned to `ollama/ollama:0.32.0`
- **Whisper STT** — speech-to-text at `https://stt.apps.lab.home.arpa/v1/audio/transcriptions`; CPU on n150-1; base model
- **OpenVINO Model Server** — currently disabled; crash-looping on n150-1, scaled to 0; planned for H4 + n150s Intel iGPU
- **M5Stack escalation router** — 3-tier edge AI: local NPU → Claude API → Claude Code orchestrator
- **m5stack-adapter** — OpenAI-compatible shim for M5Stack `/api/*` protocol (image 0.1.1)
- **Claude Code orchestrator** — live on opi5pro-1, HTTPS :8443; Tier 3 escalation

## Applications

- **Immich** — self-hosted photo/video library; SSO via Authelia OIDC; smart search + face recognition; Postgres with vectorchord extension; library on NFS ReadWriteMany PV (`immich.apps.lab.home.arpa`)
- **Home Assistant** — k3s Deployment in `home-assistant` namespace (`ha.apps.lab.home.arpa`); MQTT consumer (broker at opi-zero2w-2 .188)
- **Minio** — S3-compatible object store; `tofu-state` bucket for OpenTofu state; `minio.apps.lab.home.arpa`
- **GitLab CE** — gitlab-1 VM on n150-1; `gitlab.lab.home.arpa`; runner token in Vault

## Storage & Backup

- **NAS** — SMB/NFS on H4; 4TB NVMe hot tier
- **Cold tier** — RAID-1: 8TB primary (`/mnt/cold-8t`) + ~5.45TB secondary (`/mnt/cold-sec`)
- **restic** — NAS + Immich daily, etcd weekly, offsite via systemd timer

## Provisioning & CI

- **Ansible** — all host config; playbooks for bootstrap, updates, k3s, DNS, zswap, KVM bootstrap, sandbox-vm-update, password rotation, secrets sync
- **Semaphore** — Ansible UI; runs playbooks against the lab from inside the cluster
- **GitHub Actions** — self-hosted runner on H4; weekly scheduled maintenance (OS updates, Pi-hole, Vault seal check, lab health check)
- **OpenTofu** — VMs module (`tofu/vms/`) codifies gitlab-1; DNS module parked (Pi-hole v5 provider incompatible with v6)

## Deferred / Gaps

- Remote access — WireGuard or Tailscale (very low priority)
- UPS + NUT — H4 is a single-point storage risk; cheap insurance
- Vault TLS — currently plain HTTP; add cert-manager cert before exposing beyond LAN
- Windows Update automation — `windows-updates.yml` playbook not yet written
- rknpu driver 0.9.7 upgrade — unlocks 3B+ model support on opi5pro NPUs
- OpenVINO OVMS — crash-looping on n150-1, scaled to 0; blocked on GPU runtime fix
