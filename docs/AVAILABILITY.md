# Availability — how true is "uninterrupted service", and the plan to make it true

Written 2026-10-02 from a static review of the repo at `6db94bd` (main). Nothing here
was measured on the live cluster: every downtime figure is an **estimate** derived from
the manifests and playbooks, and the plan's last phase is a load test that replaces
these estimates with numbers. Per CLAUDE.md's "verify before asserting", treat this
document as a hypothesis until that test has run.

**Scope of the claim being tested:** production-level traffic 24×7, **no maintenance
window**, across four layers — containers, k3s, VMs and bare metal.

**Grading rule:** the *design* is graded, not the hardware. Where a gap exists because
of a pattern choice, it is a design gap even if the hardware nudged toward it. Where the
existing hardware genuinely cannot do better, it is marked **[HW-LIMIT]** with what it
would take.

---

## 1. Verdict

**Partly true.** The *foundations* are built for availability: 3-voter embedded etcd,
kube-vip control-plane VIP (`.200`), a separate floating ingress VIP (`.201`), CoreDNS
×2, in-cluster DNS with sequential failover across four resolvers, and stateless image
updates that surge before they terminate.

The *application tier* is not. **Every workload is `replicas: 1`**, nine Deployments use
`strategy: Recreate`, and almost all state lives on `local-path` PVCs, which pin a pod to
the node its volume was created on. The update processes are therefore *orderly and
contained* — one node at a time, drain before touch — but each step still takes the
affected services fully offline for seconds to minutes. Two KVM-host/k3s-server nodes
are not patched by any automation at all, so their contribution to "zero downtime" is by
omission.

The repo already knows this in places: `LAB-DESIGN.md` says *"This is a lab, not HA"*,
`update-hosts.yml` defers the H4 reboot to *"a maintenance window"*, and
`traefik-vip-service.yaml` notes Traefik is single-replica. The claim and the design
have drifted apart; this document reconciles them.

| Layer | Today | After this plan |
|---|---|---|
| Containers | ~99.95–99.99 % per service (planned events only) | ≥ 99.999 % for every service that *can* run 2+ replicas |
| k3s | Control plane ~HA; data plane interrupted by every drain | Drains become non-events |
| VMs | Every host or guest reboot is a GitLab outage | Host maintenance: < 1 s pause. Guest reboot: still an outage **[HW-LIMIT]** |
| Bare metal | n150-1/2 never patched; weekly avoidable reboots | All patched; reboots rare (Livepatch); unavoidable residue is the NAS **[HW-LIMIT]** |

### At a glance: availability today and after the plan

Planned events only (patching, upgrades, image updates), estimated from the manifests
and playbooks under the assumptions in §5. Unplanned failures are excluded. Phase 0 of
the plan replaces these estimates with load-tested measurements.

| Service | Today | After Phases 1–5 | Remaining cause |
|---|---|---|---|
| Ingress | ~99.995 % | **≥ 99.999 %** | — |
| SSO | ~99.99 % | **≥ 99.999 %** | — |
| AI gateway | ~99.97 % | **≥ 99.999 %** gateway; backends at half capacity during agent maintenance | One NPU node down = half capacity **[HW-LIMIT]** |
| Immich (web/API) | ~99.95–99.97 % | **≥ 99.99 %** | Originals unavailable during H4 reboots **[HW-LIMIT]** |
| Home Assistant | ~99.97 % | **~99.99 %** | Single-instance by design; ~30–90 s per HA release |
| MQTT | ~99.97 % | **≥ 99.99 %** | Session takeover on broker failover |
| GitLab | — | Host maintenance non-disruptive | Guest reboots 3–8 min **[HW-LIMIT]** |
| NAS (NFS) | ~99.99 % | **~99.995 %** (rarer reboots) | Single storage node **[HW-LIMIT]** |
| LAN DNS | degraded weekly | **no stalls** | — |

---

## 2. What "uninterrupted" means here

A process counts as **non-disruptive** when, under steady load through the
production path (client → `*.apps` → `.201` → Traefik → Service → pod):

1. No request fails for longer than one client-side retry (~1 s), **and**
2. Total failed requests during the process stay below **0.01 %** of requests in that
   window, **and**
3. No request hangs indefinitely (a hang is an outage, even if nothing returns 5xx).

Anything worse than that is counted as downtime in the tables below.

---

## 3. What is already right

| Mechanism | Where | Why it works |
|---|---|---|
| 3 embedded-etcd voters | `k3s_server`: h4-core, n150-1, n150-2 | Survives one server down; a leader re-election stalls API writes ~1–3 s |
| Control-plane VIP `.200` | `kube-vip/daemonset.yaml` | 5 s lease / 3 s renew / 1 s retry; failover ~5–10 s |
| Ingress VIP `.201`, separate election | `svc_election: true`, `traefik-vip-service.yaml` | Ingress address survives losing any node; `externalTrafficPolicy: Cluster` means the VIP holder needn't host Traefik |
| servicelb on every node | k3s default, deliberately kept | Node IPs still serve 80/443 as a fallback |
| CoreDNS ×2 | `coredns-custom/helmchartconfig.yaml` | Survives a drain |
| `*.apps` answered locally | `coredns-custom/configmap.yaml` template | In-cluster ingress resolution does not depend on any Pi-hole |
| In-cluster DNS failover | `forward … policy sequential` (.116, .184, .217, .148) | The weak primary (octopi) is *last* for the cluster |
| Drain-compatible PDBs | `maxUnavailable: 1` on lldap/authelia/immich-postgres | Drains no longer hang (BACKLOG §4.7) |
| Surge-first rollouts for stateless Deployments | Kubernetes default (25 % / 25 % → surge 1, unavailable 0 at replicas 1) | New pod passes readiness before old one is removed |
| Serial node handling | `serial: 1` everywhere | Blast radius is one node |
| ESO caches secrets | ExternalSecret → native Secret | Vault outages do not reach running pods |
| GitOps rollback | `git revert` → Argo selfHeal ~60 s | Fast, auditable recovery |

---

## 4. Each process under load — what traffic actually does

### 4.1 Argo CD image update — stateless Deployment
authelia, immich-server, immich-ml, redis, whisper, ai-gateway, both m5stack-adapters, ollama ×2.

- New pod is created first, then the old pod is told to terminate.
- **No `preStop` hook anywhere in `gitops/`**, so the old pod receives SIGTERM at the
  same instant its endpoint is being removed. For ~1–3 s Traefik (and kube-proxy)
  still route to a process that is shutting down. Under load this is a burst of
  `502`/connection resets.
- **Estimate:** 0 s hard outage; ~0.1–1 % of requests in a 1–3 s window fail.
- Redis is restarted empty (no persistence) — Immich job queue state is lost.
- Authelia keeps sessions **in memory** (no Redis session provider in
  `authelia/configmap.yaml`), so every Authelia restart **logs every user out**.

### 4.2 Argo CD image update — `Recreate` Deployment
home-assistant, lldap, minio, zot, semaphore, and all four Postgres instances
(authelia, immich, lldap, semaphore).

- Old pod terminates fully, then the new one starts. Traefik returns `503 no available
  server` for the whole gap; dependants lose their database at the same time.
- **Estimate per event:** Postgres 10–30 s · lldap / zot / minio 5–20 s · semaphore
  15–30 s · **Home Assistant 30–90 s**.
- Dependency chains amplify it: lldap-postgres down ⇒ lldap down ⇒ Authelia cannot
  authenticate ⇒ OIDC logins fail for Argo CD, Semaphore, MinIO, and forward-auth
  fails for `ai-gateway`.

### 4.3 Weekly OS patching — k3s agents (opi5pro-1, then opi5pro-2)
`scheduled-updates.yml` → `update-hosts.yml --tags k3s_agents`, Sundays 09:00 UTC.

- Drain evicts everything. `ollama` / `ollama-2` are pinned by `kubernetes.io/hostname`
  with node-local PVCs, so they sit **Pending** until the node returns. `rkllama` (host
  systemd service) dies with the reboot.
- LiteLLM has two backends per model group, but `ai-gateway/configmap.yaml` sets **no
  `router_settings`** — no retries, no `allowed_fails`, no cooldown, no background
  health checks — so requests continue to be routed to the dead backend until failures
  accumulate.
- **The reboot condition is wrong:** it reboots when `reboot-required` exists **or any
  package changed**, so agents reboot essentially every week.
- Unpinned pods (possibly Traefik, CoreDNS, immich-server) are moved; if Traefik is on
  the node, *all* ingress is down until the replacement is Ready.
- **Estimate:** AI at half capacity **10–20 min per node** with intermittent errors;
  **10–40 s total ingress outage** whenever Traefik is on the drained node.

### 4.4 Weekly OS patching — standalone hosts (rpi5, octopi, opi-zero2w-2, xu3-1)

| Host | What clients experience | Estimate |
|---|---|---|
| rpi5 (Vault) | Auto-unseal; ESO serves cached secrets | 0 s user-visible; ESO sync errors 1–2 min |
| octopi (Pi-hole primary) | LAN clients that list it first wait the resolver timeout (~5 s on glibc) per lookup before failing over | 1–2 min of slow lookups, no hard failure. Cluster unaffected (octopi is last) |
| opi-zero2w-2 (MQTT) | Home Assistant connects only to `.188`; the bridge to `-4` replicates topics but is **not** client failover | **1–2 min MQTT outage; QoS-0 messages lost** |
| xu3-1 | No service role (not a build agent; BACKLOG §2.16) | Irrelevant to service |

### 4.5 Pi-hole application update (`update-non-apt.yml -t pihole`)
- **Only octopi is updated.** The play header and `UPDATES.md` say "secondary first",
  but there is no secondary play: the comment says dns-2 runs dnsmasq — true, but the
  actual Pi-hole secondary, **rpi4b**, is never updated by anything.
- FTL restart: ~5–20 s of the same slow-lookup behaviour as 4.4.

### 4.6 k3s upgrade (manual, per Renovate PR)
- Servers then agents, `serial: 1`, each **drained** first.
- **The drain is what causes the downtime.** Restarting the k3s service does not stop
  running containers (the containerd shims outlive it; only `k3s-killall.sh` stops
  them). Draining converts a near-zero-impact binary swap into minutes of outage for
  every pinned or `local-path` pod on that node.
  - Draining **H4** stalls ai-gateway, both m5stack-adapters, zot, and immich-postgres
    (per the comment in `update-hosts.yml`) for the installer + restart + Ready time:
    **2–5 min**.
  - Draining **n150-1** stalls lldap-postgres, minio, semaphore (+postgres), whisper:
    **2–5 min**, and SSO logins fail for that duration.
- No health gate between nodes: the play moves to the next node the moment `uncordon`
  returns, so pods evicted from node *N* can be rescheduled onto node *N+1* seconds
  before it, too, is drained — **Traefik can move two or three times in one cycle**.
- etcd has **zero fault tolerance** while any one server is down for upgrade.
- Agents join via `K3S_URL=https://<h4 ansible_host>:6443`, **not the `.200` VIP**, so an
  agent upgrade fails if the H4 is down at that moment.

### 4.7 H4 maintenance reboot (`--tags reboot_h4`, manual)
- **NAS (`nfs-server`, the only export path — there is no Samba) is down 2–5 min.**
- `immich-library` is an NFS PV with `hard` mount options: Immich I/O **hangs** rather
  than failing. `/api/server/ping` does not touch the library, so the pod stays
  "healthy" while uploads and originals hang; stuck I/O may need a pod restart after.
- Everything on H4's `local-path` and everything pinned to `odroid-nas` is out for
  drain + reboot + Ready: **5–10 min**.
- If the H4 holds either VIP: ~5–10 s failover, existing TCP connections reset.

### 4.8 KVM VM update (`sandbox-vm-update.yml`, gitlab-1)
- Phase 1 **suspends production** while `cp` copies the ~23 GiB used of an 80 GiB
  qcow2: an estimated **30–60 s freeze** (most TCP sessions survive; webhooks and CI
  jobs in flight may time out).
- Promote: shut down → swap disk → start. GitLab Omnibus cold start: **3–8 min outage**.
- `update-vms.yml` claims "Zero-downtime OS patching for Proxmox VMs", but there is no
  Proxmox, and it targets a `k3s` inventory group that does not exist. It is dead code.

### 4.9 KVM host / k3s server OS patching (n150-1, n150-2)
- **Not automated anywhere.** `update-hosts.yml` covers h4-core, the opi5pro agents and
  `standalone`; `update-vms.yml` targets nothing that exists. Two of three etcd voters
  and both hypervisors drift unpatched.
- When done by hand, rebooting n150-1 also reboots gitlab-1 (no evacuation step) and
  takes down the `/srv/libvirt-shared` NFS export **from n150-1** — the very host being
  evacuated, which makes the shared pool useless for its stated purpose (live
  migration away from n150-1).

---

## 5. Estimated planned downtime (today)

**Assumptions:** weekly Sunday run as scheduled; one k3s upgrade and one H4 reboot per
month; current Renovate churn (patches auto-merge); unplanned failures **excluded**.

| Service | Hard-down / year | Degraded / year | Availability (planned events only) |
|---|---|---|---|
| Ingress address / `*.apps` DNS | ~20–30 min | — | ~99.995 % |
| SSO (Authelia + lldap) | ~1 h, plus a forced logout on every Authelia restart | — | ~99.99 % |
| NAS (NFS) | ~0.5–1 h | — | ~99.99 % |
| AI gateway | ~2–3 h | ~15 h at half capacity | ~99.97 % |
| Immich | ~2–4 h, plus hung I/O during H4 reboots | — | ~99.95–99.97 % |
| Home Assistant + MQTT | ~2–3 h | — | ~99.97 % |
| GitLab | ~3–8 min per promote; host reboots unaccounted (never done) | 30–60 s freeze per run | — |
| LAN DNS (clients) | ~0 | ~1.5–2 h of 5 s lookup stalls | ~100 % / visibly degraded |

**Unplanned failure is the larger risk.** A node holding `local-path` volumes that dies
takes its stateful pods with it until the node is repaired — hours, not seconds —
because the volume cannot follow the pod.

---

## 6. Code and documentation that disagree with the design

| # | Statement | Reality | Fix |
|---|---|---|---|
| D1 | `UPDATES.md:47` — "Kubernetes rolling update (maxSurge=1, maxUnavailable=0)" | Not set anywhere; 9 Deployments are `Recreate` | Corrected in this branch; enforced by C2 |
| D2 | `UPDATES.md:210` + workflow step name — Pi-hole "secondary first" | Only octopi is updated; rpi4b never | Corrected in this branch; fixed by B6 |
| D3 | `UPDATES.md:175` — "`serial: 1` keeps one agent schedulable" | True, but irrelevant to availability: everything pinned to the drained agent is down | Corrected in this branch |
| D4 | `UPDATES.md:367` — libvirt-shared "exported from H4 … live migration ready" | Exported from **n150-1** (`shared-storage.yml:65`); was down 37 days (BACKLOG §3.16); useless for evacuating n150-1 | Corrected in this branch; replaced by V1 |
| D5 | `update-vms.yml:2` — "Zero-downtime OS patching for Proxmox VMs" | No Proxmox; target group `k3s` does not exist | V3 |
| D6 | `update-hosts.yml` agents play — reboot "if kernel or libc was updated" | Reboots if *any* package changed | B2 |

---

## 7. The plan

Ordered so each phase is useful on its own and later phases build on earlier ones.
Every item is a GitOps PR or an Ansible change run with `--check` first, per CLAUDE.md.
**Decisions marked ◆ need your sign-off before any code is written** (§8).

### Phase 0 — Measure first (½ day, no risk)

| # | Change | Why |
|---|---|---|
| M1 | Blackbox HTTP probe per service through `.201` at **1 s** interval (separate job from the 60 s DNS probes) | Today's probes cannot resolve a 10-second outage |
| M2 | A load generator (`k6` or `oha` as a CronJob-triggered Job) running steady RPS against each service during any maintenance run | Replaces §5's estimates with measured error counts |
| M3 | Recording rules + a Grafana panel: per-service success ratio over 30 d; alert on burn rate | Makes "uninterrupted" a number you can watch |
| M4 | Baseline: run the Sunday playbook with M1–M3 active and record the result in this doc | The before picture |

### Phase 1 — Containers: stop dropping requests (1–2 days, low risk)

| # | Change | Effect | HW |
|---|---|---|---|
| C1 | `preStop: sleep 5` (or `exec` sleep for distroless images) + `terminationGracePeriodSeconds` ≥ 15 on every Deployment; enforce with a Kyverno policy alongside the existing three | Endpoint removal propagates before SIGTERM: eliminates the 4.1 error burst | — |
| C2 | Explicit `RollingUpdate {maxSurge: 1, maxUnavailable: 0}` on every stateless Deployment; Kyverno audit for `Recreate` without an annotation explaining why | Makes D1 true and keeps it true | — |
| C3 | **Traefik ×3** via `HelmChartConfig` (k3s-supported), `topologySpreadConstraints` across hostnames, PDB `minAvailable: 2`; then switch `traefik-vip` to `externalTrafficPolicy: Local` (preserves client IPs; the comment in that file already names this as the trigger) | Ingress no longer blinks on any drain | — |
| C4 | **Authelia ×2** with a **Redis session provider** (Redis via Sentinel ×3, or the Bitnami/valkey HA chart) | Authelia restarts stop logging everyone out; SSO survives a node | — |
| C5 | **lldap ×2**, RollingUpdate (it is stateless since the Postgres move — its own PDB comment says so) | LDAP survives a node | — |
| C6 | **immich-server ×2** (library is already RWX NFS) and **immich-ml ×2** (model cache → `emptyDir` or per-pod `ephemeral` volume; models re-download or pre-pull) | Immich front-end survives a node | — |
| C7 | **ai-gateway (LiteLLM) ×2**, unpinned from `odroid-nas`; spread across H4 + n150-2; add `router_settings`: `num_retries: 2`, `allowed_fails: 1`, `cooldown_time: 30`, `enable_pre_call_checks`, background health checks | AI requests are retried onto the healthy backend instead of failing | Placement limited by RAM: OPi nodes reserve memory for Ollama (existing constraint, kept) |
| C8 | **whisper ×2** on n150-1 / n150-2 / H4 (amd64 only) | Speech-to-text survives a node | amd64 image only — 3 eligible nodes, enough |
| C9 | **CoreDNS**: add PDB `minAvailable: 1` and hostname anti-affinity | Two copies never on the same node | — |
| C10 | PDBs → `minAvailable: 1` for every Deployment now at ≥ 2 replicas (keeps `maxUnavailable: 1` for the remaining singletons, per BACKLOG §4.7) | Drains wait for the replacement instead of racing it | — |
| C11 | Redis for Immich: enable AOF persistence or use the same HA Redis as C4 | Job queue survives restarts | — |

**Inherently single-instance (software limit, not hardware):**
- **Home Assistant** has no clustering. Best achievable: storage that can follow the pod
  (Phase 2) and fast restarts → ~30–90 s per HA update, ~0 per node drain if moved first.
- **m5stack-adapter** fronts one physical M5Stack. Two replicas would contend for one
  device. **[HW-LIMIT]**: one device. Keep singleton; make it non-critical to LiteLLM via C7 fallbacks.
- **Semaphore** runs one task scheduler. Acceptable: it is an operator tool, not a
  served path. Keep singleton.

### Phase 2 — Stateful: let state move with the pod (3–5 days, medium risk) ◆

This is the change that removes most of the minutes in §5. Two components:

| # | Change | Effect | HW |
|---|---|---|---|
| S1 ◆ | **CloudNativePG** for all four Postgres instances: 3 instances (primary + 2 sync/async replicas) spread across h4-core, n150-1, n150-2; CNPG performs a **switchover on drain** | DB writes pause ~1–3 s during a drain, instead of 2–5 min | Fits: amd64 and arm64 images. Immich needs a CNPG image with its vector extension (VectorChord / pgvecto.rs — verify the version Immich currently requires) |
| S2 ◆ | **Longhorn** (2 replicas per volume) for the remaining RWO volumes: home-assistant config, zot, lldap restic staging, model caches if kept | Pods can reschedule anywhere; a dead node no longer strands its data | **1 GbE on n150s/OPi** caps synchronous replication at ~110 MB/s — fine for config/DB-sized volumes, **not** for bulk object storage. Needs `open-iscsi` on all nodes. Disk capacity on n150s to be confirmed |
| S3 ◆ | **Object storage:** MinIO distributed mode needs ≥ 4 drives — **[HW-LIMIT]** in this cluster's shape. Alternative within hardware: **Garage** (designed for small heterogeneous clusters; 3 nodes, replication factor 3, runs on ARM) across h4-core, n150-1, n150-2 | S3 survives a node | 1 GbE limits throughput, not availability |
| S4 | **zot** → S3 storage backend on the Garage S3 store from S3, ×2 replicas | Registry becomes stateless and survives a node | — |
| S5 | Retire `local-path` for anything a user hits; keep it for Ollama models (re-downloadable, pinned to NPU/accelerator nodes by design) | | Ollama/rkllama stay per-node — the RK3588 NPUs are the hardware |

Migration is per workload: dump → CNPG cluster → restore → cut over the Service, with the
old PVC retained until a restore drill passes (same discipline as BACKLOG §1.1).

### Phase 3 — k3s: make drains non-events (1–2 days, low–medium risk)

| # | Change | Effect | HW |
|---|---|---|---|
| K1 | **Health gate between nodes** in every drain loop: after `uncordon`, wait until no pod is Pending, all Deployments are `Available`, CNPG clusters report healthy, and Longhorn volumes are `healthy` — *then* move to the next node | Stops the double-move and the half-recovered-cluster drain | — |
| K2 | **k3s patch upgrades: cordon, don't evict**, until Phase 2 lands (containers survive a k3s restart). After Phase 2, keep the drain — it is then free | Removes the 2–5 min pinned-pod outages from 4.6 immediately | — |
| K3 | Agents' `K3S_URL` → `https://192.168.1.200:6443` (the VIP) | Agent upgrades no longer depend on the H4 being up | — |
| K4 | Optionally adopt **system-upgrade-controller** (k3s-native) with `concurrency: 1` and drain settings tuned per plan | Upgrades are declarative and GitOps-managed like everything else | — |
| K5 ◆ | **5 etcd voters**: promote opi5pro-1 and opi5pro-2 to servers | During a server's maintenance the cluster still tolerates one failure (today it tolerates zero) | Possible on existing hardware (RK3588 + NVMe), **but** these nodes run memory-heavy inference and ship logs via zram `/var/log`; etcd wants stable fsync latency. Trade-off, not a free win |
| K6 | kube-vip: confirm the leader releases its lease on SIGTERM (graceful handoff) so *planned* VIP moves are < 1 s rather than lease-expiry 5 s; verify against kube-vip v0.9.2 behaviour before relying on it | Planned VIP moves stop resetting connections for 5 s | — |

### Phase 4 — VMs (1–2 days, medium risk)

| # | Change | Effect | HW |
|---|---|---|---|
| V1 | **Live migration without shared storage**: `virsh migrate --live --persistent --undefinesource --copy-storage-all` between n150-1 and n150-2 (identical N150 CPUs, both on `br0`). Drop dependence on the n150-1-hosted NFS pool | Host maintenance on either n150 → GitLab pause **< 1 s** | **[HW-LIMIT, tight]** gitlab-1 is 8 GiB RAM; each n150 has 16 GiB **and** is a k3s server with workloads. n150-2 must have ~8.5 GiB free at migration time — the playbook must check and cordon/evict pods first if not. 1 GbE: ~23 GiB disk copy ≈ 3–5 min of background copy before the cut-over |
| V2 | Sandbox pipeline: replace *suspend + `cp`* with a libvirt external disk-only snapshot (`virsh snapshot-create-as --disk-only --atomic`, or `virsh backup-begin`) | Removes the 30–60 s production freeze | — |
| V3 | Delete or rewrite `update-vms.yml` (Proxmox-era, targets nothing) into a **KVM host maintenance play**: live-migrate VMs off → drain k3s (Phase 3 gate) → patch → reboot if required → uncordon → migrate back | n150-1/n150-2 actually get patched, without an outage | — |
| V4 | **Guest kernel updates via Livepatch** inside gitlab-1 (see B3) | Fewer guest reboots | — |

**[HW-LIMIT] residual:** a GitLab *guest* reboot (or Omnibus upgrade) is still a 3–8 min
outage. GitLab's own HA reference needs ≥ 3 Rails nodes + Gitaly Cluster + HA Postgres
and Redis — far beyond 2 × 16 GiB hosts. Accept it; schedule guest reboots only when
Livepatch cannot cover the fix.

### Phase 5 — Bare metal (2–3 days, low–medium risk)

| # | Change | Effect | HW |
|---|---|---|---|
| B1 | Patch **n150-1 / n150-2** via V3's host play — weekly, `serial: 1`, with the Phase 3 gate | Closes the "never patched" gap (§4.9) | — |
| B2 | Agents reboot **only** on `/var/run/reboot-required` (fix the `or apt_result.changed` condition) | Removes ~52 avoidable reboots/node/year | — |
| B3 | **Canonical Livepatch** (free for personal use, up to 5 machines) on h4-core, n150-1, n150-2 and gitlab-1 — 4 of 5 slots | Kernel CVEs patched without reboots; reboots become rare | **[HW-LIMIT]** the opi5pro and Zero 2W boards run vendor kernels that Livepatch does not cover. Confirm the H4's kernel flavour is a Canonical-built one |
| B4 | `needrestart` in automatic mode on Ubuntu hosts, with a deny-list for `k3s`, `nfs-server`, `libvirtd` | Libraries take effect without reboots; protected services never restart by surprise (CLAUDE.md: `nfs-server` is off-limits) | — |
| B5 | **H4 role reduction:** move everything pinned to `odroid-nas` (ai-gateway, m5stack-adapter ×2, zot) off it via C7/S4. H4 keeps: NAS, etcd voter, Longhorn/CNPG/Garage replica | An H4 reboot affects the NAS and Immich originals only | — |
| B6 | **DNS VIP for LAN clients:** keepalived VRRP address shared by octopi and rpi4b (both wired); hand that single address out via DHCP. Update **both** Pi-holes, standby first | LAN clients never see a resolver disappear: no 5 s stalls | octopi is a 1 GB RPi 3B — the BACKLOG already calls it the weakest box; rpi4b (8 GB) should be VRRP master |
| B7 ◆ | **MQTT:** move the broker into k3s (EMQX or NanoMQ cluster ×3, or Mosquitto + kube-vip LoadBalancer VIP) and point Home Assistant and devices at the VIP | MQTT survives node and broker restarts | The current brokers are **WiFi** Zero 2W boards — **[HW-LIMIT]** for anything called HA. Retire them from the broker role |
| B8 ◆ | **Vault 3-node Raft**: rpi5 + n150-1 + n150-2 (host services, outside k3s to avoid the bootstrap loop), each with the existing on-disk auto-unseal posture (BACKLOG §2.5) | Vault survives a node; no ESO sync gaps | Low user impact today (ESO caches), so lowest priority. rpi5 on SD card is already flagged in TROUBLESHOOTING.md |
| B9 | **NAS** — see residual below | | **[HW-LIMIT]** |

**[HW-LIMIT] — the NAS.** The H4 is the only machine with the SATA RAID mirrors and the
NVMe that holds `lv_nas`. An H4 reboot therefore takes NFS down for 2–5 min, and Immich
originals with it. Within existing hardware the best available is: Livepatch (B3) so the
reboot is rare; B5 so nothing *else* rides on it; and a deliberate Immich behaviour
during the gap (keep `hard` for integrity, but add an app-level readiness check that
touches the library so Traefik returns a fast `503` instead of hanging connections).
Truly uninterrupted NFS needs a **second storage node with comparable disks** and
replicated block storage (DRBD + Pacemaker floating NFS, or Ceph) — new hardware.
Note CLAUDE.md marks `nfs-server` and its data as off-limits: every NAS-adjacent item
here is a proposal for you, not something to be performed.

### Out of scope / accepted
- **Windows HTPC (n150-3)** — a client device, not a service host.
- **Network and power.** One router/switch, no documented UPS. These dominate
  *unplanned* availability more than anything above. **[HW-LIMIT]** — a UPS for the
  rack and the switch is the single highest-value hardware purchase for this goal.
- **xu3-1** — no service role (not a build agent; BACKLOG §2.16), not on any served path.

---

## 8. Decisions needed before any code

1. **S1/S2/S3 — storage stack.** CNPG + Longhorn + Garage is the recommendation. The
   alternative is CNPG only (Phase 2 for databases) and accepting `local-path` for
   Home Assistant / zot / MinIO. Which?
2. **K5 — 5 etcd voters** on the opi5pro boards: worth the memory/fsync trade-off?
3. **B7 — MQTT into k3s:** which broker (EMQX cluster vs Mosquitto + VIP)?
4. **B8 — Vault Raft ×3:** placement on the n150s acceptable?
5. **B3 — Livepatch:** acceptable to enrol hosts with Canonical (requires an Ubuntu Pro
   token)?
6. **B9 — NAS:** accept the residual, or scope a second storage node?

Suggested order once decided: Phase 0 → 1 → 3 (K1–K3) → 2 → 4 → 5. Phase 1 plus K1–K3
alone should remove most of the *request-visible* errors without touching storage.

---

## 9. How to prove it

The claim is true for a layer when **M2's load test, run during that layer's
maintenance process, meets §2's criteria**:

1. Start steady load (e.g. 50 RPS per service) through `.201`.
2. Run the process: `update-hosts.yml`, the k3s upgrade, the KVM host play, an Argo
   image bump.
3. Record failed requests, max latency and longest gap from M1.
4. Write the result into §5 with the date, replacing the estimate.

A process that fails the test is not done, whatever the manifests say.
