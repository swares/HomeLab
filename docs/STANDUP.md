# Lab Standup — Initial Bring-Up Guide

A dependency-ordered procedure to take the lab from bare hardware to a working GitOps platform.
Work top to bottom: each phase assumes the previous one is up. Commands run from the repo root
unless noted. See [LAB-DESIGN.md](LAB-DESIGN.md) for the *why*, [HARDWARE.md](HARDWARE.md) for the
inventory, and [RUNBOOK.md](RUNBOOK.md) for day-2 recovery.

**Legend:** 🟢 automated (a `make` target / `tofu`) · 🔧 manual (one-time hardware/OS) · 🟡 to wire
(a piece you finish or I can build out).

---

## Phase 0 — Bench prep & prerequisites

Goal: a control workstation that can reach everything, clean credentials, and **healthy hardware
to build on** (don't build the NAS on a faulted disk link).

1. 🔧 **Control workstation tooling.** Install `git`, `ansible` (+ collections
   `community.general`, `ansible.posix`), `opentofu`, `kubectl`, `helm`, `jq`. Clone the repo and
   dry-run everything:
   ```bash
   git clone <your-repo> homelab && cd homelab
   make check          # ansible-playbook site.yml --check (no changes)
   ```
2. 🔧 **Hardware reconciliation.**
   - Retire **RPi 3B #1** (`.73`) — on-board power fault; do not give it a role.
   - **Resolve the H4 8 TB mirror's UDMA-CRC fault BEFORE trusting it** — cable → SATA power →
     port → BIOS, per [RUNBOOK → UDMA CRC triage](RUNBOOK.md#disaster-recovery). Confirm both
     mirrors are clean before Phase 2:
     ```bash
     cat /proc/mdstat                       # md1 (8T primary) [UU]; secondary mirror [UU]
     smartctl -a /dev/sdX | grep -E "UDMA_CRC|Reallocated|Pending|Uncorrectable"
     ```
3. 🔧 **Network & addressing.** Give every infra node a **static / DHCP-reserved IP** (Pi-hole
   client-scoping and the k8s API both need stable addresses). Confirm the gateway
   (`lab_gateway`, flagged *confirm* in the inventory) and the ingress VIP (`192.168.1.160`).
4. 🔧 **Credentials.** Replace the map's shared password with **SSH keys** (`ansible_user`), and
   generate real secrets — Vault init/unseal keys, the Pi-hole web hash, the
   restic repo password. Keep them out of Git (Ansible Vault now; HashiCorp Vault once it's up).

---

## Phase 1 — Provision the operating systems (CASC enabler)

Goal: every box boots **SSH-ready** so Ansible can take over. No MAAS — see
[LAB-DESIGN → Provisioning the small stuff](LAB-DESIGN.md#provisioning-the-small-stuff-no-maas).

1. 🔧 **Flash the SBCs** (OPi 5 Pro ×2, OPi Zero 2W ×4, RPi 5/4B/3B #2) with **rpi-imager or a
   cloud-init image**, pre-seeding hostname, your SSH key, and wired/WiFi. They boot ready for
   Ansible — no console needed.
2. 🟢 **Confirm reachability:**
   ```bash
   cd ansible && ansible all -m ping        # expect SUCCESS from every host, then: cd ..
   ```
3. 🔧 **M5Stack** (edge) — flash via **PlatformIO / OTA** (ESPHome optional). Can wait until the
   AI gateway exists (Phase 4).

---

## Phase 2 — L0 Foundation services

Goal: name resolution, storage, identity, and secrets — the things everything else needs.

1. 🟢 **DNS first** (nothing else resolves without it):
   ```bash
   make dns
   ```
   Then point DHCP at **both** resolvers (primary `.148` octopi, Zero 2W secondary). Install Pi-hole
   on top for the UI/blocking if you want it (the playbook pre-seeds `pihole.toml`). Verify:
   ```bash
   dig @192.168.1.148 h4-core.lab.home.arpa +short          # -> 192.168.1.160
   dig @192.168.1.148 anything.apps.lab.home.arpa +short    # -> 192.168.1.160 (Traefik ingress VIP)
   ```
   *Depends on:* Phase 1. *Unblocks:* the cluster API + all `*.apps` ingress names.
2. 🟢 **Storage on the H4** (only once the 8 TB CRC link is proven, Phase 0):
   ```bash
   make storage
   ```
   Mounts the two mirrors (`md1` 8 TB → `/mnt/cold-8t`, secondary ~5.45 TB → `/mnt/cold-sec`), carves the NVMe LVM hot tier, and installs
   **smartd + mdadm monitoring**. Verify mounts, array health, and that the monitors are active.
   See [storage-tiers.svg](diagrams/storage-tiers.svg).
3. 🟢 **Identity & secrets.** `make vault` (RPi 5). lldap runs as k3s Deployment. Vault install/config
   is automated; **`vault operator init` + unseal are a one-time manual step** (store keys offline).
4. 🟢 **MQTT broker.** `make mqtt` stands up Mosquitto on a lab Zero 2W; point the M5Stack
   framework's broker address at it (dad's laptop stays a dev target).

---

## Phase 3 — L2 Core platform (k3s on the H4) + GitOps

Goal: the main Kubernetes platform and the GitOps loop that drives all in-cluster workloads.
`make all` runs steps 1–3 in order; run them individually the first time.

> **Implemented as k3s** (not MicroShift). The H4 runs a single-node k3s server with OPi 5 Pro
> boards as agents. Use `kubectl`, not `oc`; Ingress not Route; `local-path` StorageClass.

1. 🟢 **k3s** on the H4 (uses `local-path` StorageClass on the NVMe):
   ```bash
   make k3s-h4
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # on the H4
   kubectl get nodes,pods -A                      # Ready / Running
   ```
2. 🟢 **Backups** (get the backup spine up before real data lands):
   ```bash
   make backup        # restic timers (md1 primary, restic copy -> secondary) + etcd snapshots
   ```
   Verify the timers exist and a first run succeeds (`systemctl list-timers | grep backup`).
3. 🟢 **Argo CD + app-of-apps** — the GitOps controller; in-cluster workloads sync from Git:
   ```bash
   make argocd
   kubectl -n argocd get applications        # all Synced / Healthy
   ```
   *Unblocks:* LiteLLM gateway, sample-app, observability, and the rest of `gitops/workloads/`.

> Shortcut once you trust it: `make all` = storage → k3s-h4 → backup → argocd.

---

## Phase 4 — AI fabric

Goal: local inference behind one OpenAI-compatible gateway. See
[AI-INFERENCE.md](AI-INFERENCE.md) and [ai-fabric.svg](diagrams/ai-fabric.svg).

1. 🟢 **Inference runtimes** on the AI nodes:
   ```bash
   make ai-nodes      # RKLLama (NPU) on the OPi 5 Pros + OpenVINO (iGPU) on H4/N150s
   ```
2. 🟡 **Verify the gateway** (LiteLLM, deployed by Argo in Phase 3) reaches the backends and the
   `m5stack-adapter`:
   ```bash
   curl -sk https://ai.apps.lab.home.arpa/v1/models | jq '.data[].id'
   # expect: chat, chat-cpu, code, vision, fast, embeddings, cloud, m5, m5-llm, m5-claude
   curl -sk https://ai.apps.lab.home.arpa/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"cloud","messages":[{"role":"user","content":"ping"}]}' \
     | jq '.choices[0].message.content'   # expect: "pong" via Groq or Gemini
   ```
   Cloud fallback (Groq llama-3.3-70b + Gemini 2.0 Flash) is wired as automatic fallback
   for `chat` and `chat-cpu` failures. Keys in Vault at `secret/lab/cloud-ai`.
3. 🔧 **M5Stack escalation router** — point it at the gateway/orchestrator; confirm the 3 tiers
   (local NPU → Claude API → Claude Code on the orchestrator) resolve as configured.

---

## Phase 5 — L1 IaaS playground (Proxmox + OpenTofu)

> **Archived** — Proxmox was not implemented. n150-1/n150-2 run bare-metal Ubuntu 24.04 with KVM/libvirt.

Goal: the VM/devops sandbox. This is a **parallel track** — it doesn't block Phases 2–4. See
[LAB-DESIGN → IaaS](LAB-DESIGN.md) and `terraform/README.md`.

1. 🔧 **Proxmox VE** on the three N150s; form the cluster (quorum 2 of 3). If the living-room
   **n150-3 (HTPC)** is often powered off, add a **QDevice vote on a Zero 2W** (not the faulty
   3B #1) so the other two keep quorum.
2. 🔧 **Shared storage** — export **NFS from the H4** and add it as Proxmox VM storage.
3. 🔧 **HTPC VM** on n150-3 — TV/browse with CPU/disk/iGPU passthrough; node-locked and **separate
   from the lab** (it still votes quorum).
4. 🟢 **VMs via OpenTofu** (cloud-init k3s server + agents, one per N150):
   ```bash
   cd terraform && tofu init && tofu plan && tofu apply
   ```
5. 🟢 **k3s on the VMs.** Generate the inventory then install:
   ```bash
   terraform/inventory-from-tofu.sh > ansible/inventory/tofu-vms.yml
   make k3s-vms
   ```
   The `gitlab` VM (from step 4's `tofu apply`) is where **GitLab now lives** — moved off OPi 5 Pro #2.

---

## Phase 6 — Verify, then close the known gaps

1. **End-to-end smoke test.**
   - DNS: lab names + `*.apps` wildcard resolve from a client.
   - Storage: `cat /proc/mdstat` clean; smartd/mdadm monitoring armed.
   - Platform: `kubectl get nodes,pods -A` healthy; Argo all Synced.
   - AI: gateway lists models and answers a prompt.
   - Backups: a restic snapshot exists on md1 (`/mnt/cold-8t`), copied to the secondary.
2. **Close the gaps** (from [SERVICES.md](SERVICES.md), priority order):
   - ✅ **Offsite backup (Track 1 — cluster state)** — `backup-cloud.timer` runs daily at 03:00,
     pushing etcd snapshots, lldap/Vault snapshots, and Postgres dumps to Cloudflare R2 free tier.
     Credentials in Vault at `secret/lab/cloudflare-r2`. Playbook: `ansible/playbooks/backup-cloud.yml`.
   - 🔵 **Offsite backup (Track 2 — bulk photos/video ~1.5 TB)** — deferred. See RUNBOOK.md for
     options (Backblaze B2 or R2 paid). The `backup-offsite.service` template is ready; needs
     `offsite_restic_repo` set and `/etc/restic/offsite.env` populated.
   - ✅ **healthchecks.io dead-man's switch** — all 4 backup services ping healthchecks.io on
     success via `ExecStartPost=/usr/local/bin/hc-ping <check>` drop-ins. `h4-heartbeat.timer`
     fires every 5 min as a host-alive check. Ping URLs in Vault at `secret/lab/healthchecks`.
     Playbook: `ansible/playbooks/healthchecks.yml`.
   - ✅ **MQTT (Mosquitto)** — relocated to a lab Zero 2W (`make mqtt`).
   - 🔵 **UPS + NUT** — deferred by choice (future improvement).
   - 🟡 **Reverse proxy + internal CA + SSO** — once several web UIs are live.
   - 🟡 **VPN** (WireGuard/Tailscale), **UPS + NUT** (the H4 is a single storage point), dashboards.

---

## One-page sequence

| # | Phase | Command / action | Gate before proceeding |
|---|-------|------------------|------------------------|
| 0 | Bench prep | tooling · **fix H4 CRC** · IPs · creds | `mdstat` clean, `make check` passes |
| 1 | Provision OSes | flash SBCs (cloud-init) | `ansible all -m ping` all green |
| 2 | DNS | `make dns` | lab + `*.apps` names resolve |
| 2 | Storage | `make storage` | mirrors mounted, monitoring armed |
| 2 | Identity/secrets | Vault + LDAP up | Vault unsealed |
| 3 | Platform | `make k3s-h4` | nodes Ready |
| 3 | Backups | `make backup` | first snapshot OK |
| 3 | GitOps | `make argocd` | apps Synced |
| 4 | AI fabric | `make ai-nodes` | gateway answers |
| 5 | IaaS (parallel) | Proxmox + `tofu apply` | VMs reachable |
| 6 | Verify/harden | smoke test + close gaps | — |

**Critical path:** Phase 0 (healthy disks + IPs) → **DNS** → storage → k3s → Argo. DNS is
the true first dependency; the unresolved H4 CRC fault is the one thing that can undermine the
storage tier, so clear it first.
