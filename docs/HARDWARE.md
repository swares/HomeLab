# Hardware Inventory & Roles

Updated to the **Hardware2** map. The fleet grew and shifted meaningfully since the first
pass — most importantly two **Orange Pi 5 Pro** boards (8C/16GB/NPU) and a changed storage
layout on the core. Real addressing is `10.136.151.0/24`.

> **Security note:** the source mindmap stored plaintext logins (e.g. shared
> `swares`/`pi`/`odroid`/`root` passwords). Those are **not** reproduced in this repo —
> rotate them and move to SSH keys + Ansible Vault. See [SECURITY.md](SECURITY.md).

## Compute

| Device | CPU | RAM | Storage | Wired IP | Observed services | Role |
|--------|-----|-----|---------|----------|-------------------|------|
| **Odroid-H4 Ultra** | i3-N305 8C/8T x86 | 64 GB¹ | NVMe 4 TB · eMMC 256 GB · 8 TB RAID1 (md1) · ~5.45 TB RAID1 | `.64` (2.5 Gbps) | Ansible✓, Docker✓, OpenNebula✓, OneAI | **Core: NAS + MicroShift** |
| **N150 mini PC ×2 (lab)** ³ | Intel N150 4C/4T x86 | 16 GB DDR4 | 512 GB M.2 | `.71` / `.72` (TBD) | — | **Proxmox cluster nodes** / OpenVINO iGPU inference |
| **N150 #3 (living-room)** ³ | Intel N150 4C/4T x86 | 16 GB DDR4 | 512 GB M.2 | TBD | — | **Proxmox node** running the TV/browse VM (cores/disk/iGPU passthrough) |
| **Orange Pi 5 Pro #1** | RK3588S 8C ARM | 16 GB | SD 64 · eMMC 256 · NVMe 30 GB | `.83` | Apps/Containers/VMs, AI GPU+NPU | k3s **server** / heavy ARM |
| **Orange Pi 5 Pro #2** | RK3588S 8C ARM | 16 GB | SD 64 · eMMC 256 · NVMe 30 GB | `.97` | **RKLLama, OpenTelemetry** (GitLab moved to a VM) | k3s **server** / AI |
| RPi 5 | Cortex-A76 4C | 8 GB | SD 64 | `.67` | **Vault✓**, AI GPU | k3s agent / secrets |
| RPi 4B | Cortex-A72 4C | 8 GB | SD 64 | `.99` | **OpenLDAP✓** | k3s agent / directory |
| RPi 3B #1 | Cortex-A53 4C | 1 GB | SD 64 | `.73` (WiFi) | — | ⚠ **on-board power fault** (low-voltage even on 5V/5A) — retire / RMA |
| RPi 3B #2 | Cortex-A53 4C | 1 GB | SD 64 | `.59` (**wired**) | — | **DNS (Pi-hole)** — repurposed; 3D printer offline |
| Odroid-XU3 #1 ⚠ | Exynos5422 8C (A15×4+A7×4) | 2 GB | eMMC 64 | `.51` | Containers | build agent / light pods |
| RPi Zero W ×3 (standalone) | 1C @ 1 GHz, **32-bit ARMv6** | 512 MB | SD | WiFi, own IP (TBD) | — | ultra-light single tasks only (1 DOA; 32-bit limits images) |
| **Orange Pi Zero 2W ×4** (standalone) | Allwinner H618, A53 4C 64-bit @1.5GHz | **4 GB** LPDDR4 | microSD + 16 MB SPI (no eMMC/M.2) | WiFi5, own IP (TBD) | — | viable **k3s agents** / service nodes (Mali-G31, no NPU; SD-only → keep stateless) |
| M5Stack LLM | ESP32-S3 2C | — | USB | — | AI NPU | edge AI inference |
| HostMon | ESP32-S3 (Waveshare 4.3" LCD) | 8 MB PSRAM | 8 MB flash | LAN | edge | black-box host prober + status panel |

¹ H4 officially specs 48 GB DDR5; 64 GB is over spec and generally works.
³ **Three** N150 mini PCs total (none in the Hardware2 map): two dedicated lab boxes plus the
living-room HTPC, which joins as a Proxmox node running its TV/browse workload as a VM. N150 =
Twin Lake (Alder Lake-N), 4 Gracemont cores, 24-EU UHD iGPU, **no NPU**; AI runs on the iGPU
via OpenVINO. Together with the H4 they form the x86 Proxmox cluster (the H4 stays storage/AI).

² The "Zero 2 W" units are **Orange Pi Zero 2W (4 GB)** — Allwinner H618, not the 512 MB
Raspberry Pi Zero 2 W. Capable little ARM64 nodes; the constraint is storage (microSD + SPI
only, USB 2.0, WiFi5 / 100M-via-addon) — keep them stateless.

**ClusterHAT failed** — the Zero W and Zero 2 W boards are now **standalone WiFi nodes**, each
with its own IP (the old shared slot IPs no longer apply). They're single-task appliances, not
cluster members: the **Orange Pi Zero 2W (4 GB)** are real lightweight nodes — a viable k3s **agent pool** (4× ≈
16 C / 16 GB) or solid single-service hosts (one is a fine **DNS** host); the 32-bit ARMv6 RPi
Zero W are the weakest and largely retirement-grade. **RPi 3B
#1**, freed from ClusterHAT-host duty, is the better always-on board — earmark it for DNS or the
Proxmox **QDevice**. Confirm physical counts (≈3 working Zero W + 4 Zero 2 W).

**Dropped from the first map:** Atomic Pi, ESP8266, and Dad's laptop don't appear in
Hardware2 — assumed retired from the lab unless you say otherwise.

## AI / accelerators

A real local-inference tier now exists, separate from the cluster:

| Device | Accelerator |
|--------|-------------|
| Orange Pi 5 Pro ×2 | NPU 6 TOPS @ INT8 each + 6-EU GPU |
| M5Stack LLM | NPU ~6 TFLOPS |
| Odroid-H4 Ultra | iGPU, 32 execution units |
| RPi 5 | 12-EU GPU |

~18 TOPS of **NPU** across the OPi boards + M5Stack — enough for small-model inference and
vision workloads that cluster services can call. The Intel parts (H4 N305, N150 ×3) have
**no NPU**; their iGPUs do AI via OpenVINO (embeddings, STT, OCR, vision). How to serve and
route all of it is in [AI-INFERENCE.md](AI-INFERENCE.md).

## Storage tiers (H4 core) — CHANGED

| Tier | Media | Capacity | Purpose |
|------|-------|----------|---------|
| Boot | eMMC | 256 GB | Host OS (frees the NVMe entirely) |
| Hot | NVMe (US75) | 4 TB | etcd, k8s PVs, live NAS data |
| Cold — primary | **8 TB RAID 1** (`md1`, 2×8 TB) | 8 TB usable | restic repo + etcd snapshots + **Immich library** |
| Cold — secondary | **~5.45 TB RAID 1** (2×6 TB) | ~5.45 TB usable | `restic copy` (critical set) + archive; rebuilt from ex-Synology disks |
| Off-box | Git | — | cluster + host **config** |

Cold storage is **two mdadm RAID 1 mirrors**: the **8 TB mirror** (`md1`, 2×8 TB — primary restic repo + etcd snapshots + the **Immich library** at `/mnt/cold-8t`) and a **~5.45 TB mirror** (2×6 TB, `/mnt/cold-sec` — `restic copy` of the critical set + archive). The secondary is being **rebuilt clean from the disks inherited off an old Synology** (was an ext4 LVM concat over two mirrors). Each tier survives a single-disk failure in place. The **NVMe hot tier is a single disk** (not mirrored), so it stays the one point of failure for *live* data — backed up onto the mirrors and offsite. The 8 TB mirror **passed re-attach burn-in** (SMART 199 flat under a full scrub), so it's trusted as primary. Because the secondary (~5.45 TB) can't locally hold the whole multi-TB photo library, the **bulk library's offsite restic copy is its redundant copy**, while the secondary holds the critical-but-small set (DB dumps, configs, irreplaceable originals). Putting the OS on the
**256 GB eMMC** lets the whole NVMe go
to etcd + PVs + live NAS.

## Network

Flat `10.136.151.0/24`. The H4 is wired at 2.5 Gbps (Intel I226-V); most other nodes are
1 Gbps wired plus WiFi 5. The updated map does not show the 2.5GbE switch or a DNS host
(see below) — confirm the switch placement and gateway (`.1` assumed).

## DNS — needs a home

The first map ran **Pi-hole** on a Zero W; the updated map shows that Zero W running
**Grafana** instead, and no node is clearly assigned to DNS. DNS is load-bearing for
MicroShift (`api.lab.home.arpa` + `*.apps.lab.home.arpa`). Pick a stable always-on host —
a Zero 2 W, an Orange Pi 5 Pro, or `dnsmasq` on the H4 — and set it in the inventory's `dns`
group. See [RUNBOOK.md → DNS records](RUNBOOK.md#dns-records).

## Capacity (approx.)

For aggregate totals and the accelerator classification, see [CAPABILITY.md](CAPABILITY.md).


| Class | Count | Cores | RAM |
|-------|-------|-------|-----|
| x86 (H4) | 1 | 8C/8T | 64 GB |
| x86 (N150) | 3 | 12C/12T | 48 GB |
| ARM 16 GB (OPi 5 Pro) | 2 | 16C | 32 GB |
| ARM 4 GB (OPi Zero 2W) | 4 | 16C | 16 GB |
| ARM 8 GB (RPi 5, 4B) | 2 | 8C | 16 GB |
| ARM small (XU3, 2× RPi 3B, 3× RPi Zero W) | 6 | ~16C | ~6 GB |

The two Orange Pi 5 Pro boards are the real upgrade: at 8C/16 GB with NPUs they're proper
multi-purpose ARM nodes — strong enough to be the k3s control plane (better than the RPi 5),
and they're already where the heavier infra services (GitLab) live.

## Role-assignment summary

- **H4 Ultra** — core: NAS + MicroShift + GitOps + two-tier cold backups.
- **Orange Pi 5 Pro ×2** — Phase-2 k3s servers / ARM infra (GitLab, OpenTelemetry).
- **RPi 5 / 4B** — k3s agents; also host Vault (secrets) and OpenLDAP (directory).
- **XU3** — build agent / light pods (flagged unstable in the map; verify).
- **RPi 3B #2** — DNS (Pi-hole, wired); 3D printer offline.
- **Zero (2) W set** — micro services (Grafana, exporters, light apps).
- **M5Stack + OPi NPUs** — edge AI inference endpoints workloads can call.
