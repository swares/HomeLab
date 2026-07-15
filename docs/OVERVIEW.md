# Lab Overview

Current as of 2026-07-07. Detailed service catalog in [SERVICES.md](SERVICES.md), hardware in [HARDWARE.md](HARDWARE.md).

## Infrastructure & Platform

- **k3s cluster** — H4, n150-1, n150-2 as servers; opi5pro-1 and opi5pro-2 as agents; `local-path` StorageClass on NVMe
- **ArgoCD** — GitOps from `gitops/`; selfHeal + prune on all apps
- **Traefik** — ingress for all `*.apps.lab.home.arpa`; TLS via cert-manager lab CA
- **kube-vip** — control-plane HA VIP (`192.168.1.200`)
- **KVM/libvirt** — bare-metal hypervisors on n150-1 and n150-2

## Identity & Security

- **lldap** — lightweight LDAP directory (`lldap.apps.lab.home.arpa`)
- **Authelia** — OIDC/SSO backed by lldap (`authelia.apps.lab.home.arpa`)
- **HashiCorp Vault** — secrets and PKI on RPi 5
- **External Secrets Operator** — syncs Vault secrets into k8s

## Networking & DNS

- **Pi-hole** — primary DNS + ad-blocking on octopi; dnsmasq fallback on opi-zero2w-1
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
- **RKLLama** — NPU-native LLM on opi5pro-1 and opi5pro-2 (~7–8 tok/s, RK3588S)
- **OpenVINO Model Server** — currently disabled (pending GPU runtime + model IR setup); planned for H4 + n150s Intel iGPU
- **Ollama** — in-cluster CPU fallback (opi5pro-1 and opi5pro-2)
- **M5Stack escalation router** — 3-tier edge AI: local NPU → Claude API → Claude Code
- **m5stack-adapter** — OpenAI-compatible shim for M5Stack `/api/*` protocol

## Applications

- **Immich** — self-hosted photo/video library; SSO via Authelia OIDC; smart search + face recognition; Postgres with vector extension (`immich.apps.lab.home.arpa`)
- **Private container registry** — in-cluster image hosting

## Storage & Backup

- **NAS** — SMB/NFS on H4; 4TB NVMe hot tier
- **Cold tier** — RAID-1: 8TB primary (`/mnt/cold-8t`) + ~5.45TB secondary (`/mnt/cold-sec`)
- **restic** — NAS + Immich daily, etcd weekly, offsite via systemd timer

## Provisioning & CI

- **Ansible** — all host config; playbooks for bootstrap, updates, k3s, DNS, zswap, etc.
- **GitHub Actions** — self-hosted runner on H4; weekly scheduled maintenance (OS updates, Pi-hole, Vault seal check, zswap)

## Deferred / Gaps

- Home Assistant (natural MQTT consumer)
- Remote access — WireGuard or Tailscale
- UPS + NUT (H4 is a single-point storage risk)
- Homepage / dashboard
- CloudNativePG + Redis operators for shared DB
- RPi 4B runs Home Assistant (standalone, Debian 12)
