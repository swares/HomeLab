# CLAUDE.md — operating rules for this lab

You are helping operate a home lab whose core is an **Odroid-H4 Ultra** NAS, part of a
**3-node HA k3s cluster** (H4 + n150-1 + n150-2 as servers; opi5pro-1/2 as ARM64 agents).
Read this before acting. Full context is in `docs/` (start with `ARCHITECTURE.md`).

## How changes are made

- **Everything is GitOps.** Change the cluster by editing files under `gitops/` and opening
  a **pull request** — never `kubectl apply` to `main` directly, and never push straight to
  `main`. Argo CD reconciles from git with `selfHeal` on, so imperative changes drift and
  get reverted anyway.
- To undo something, `git revert`. The git history is the audit log.
- Host changes go through the Ansible playbooks in `ansible/`. Run `--check` first; a real
  run is an `ask` action.
- Always suggest a branch name.
- Always use gh pr to create pull requests.

## There are two checkouts — commit from one of them

- The **Windows checkout is authoritative**. All edits, commits and PRs happen there.
- The **H4 checkout (`~/lab/homelab/homelab`) is run-only** — Ansible, `kubectl`, restic,
  the drills. Keep it pinned: `git fetch origin && git reset --hard origin/main`.
- **Edits in one checkout are invisible to git in the other.** On 2026-08-17 an hour was
  lost to this: doc changes were written in the Windows checkout while `git add` and
  `git status` ran on the H4, which reported `nothing added to commit` — accurately, and
  about a different set of files. A clean `git status` in one checkout says nothing about
  work in progress in the other.
- The same split produced two envelope scripts differing only by hyphen versus underscore
  (`print-offline-envelope.sh` shipped; `print_offline_envelope.sh` sat unreferenced on
  the H4's local `main` for two days). Before concluding work is missing, check
  `git branch -r` — it may be on an unmerged branch someone pushed and never opened a PR
  for.

## This box has two roles — keep them separate

- The **cluster layer is yours to manage**. The **NAS service (`nfs-server`) and the data
  it serves are off-limits** — never stop, restart, or reconfigure it, and never disable
  the backup timers (`backup-nas`, `backup-etcd`).
- **There is no Samba on this box, and this line used to say there was.** Measured
  2026-09-02: `systemctl show smbd` returns `LoadState=not-found`, nothing listens on
  139 or 445, and `list-units --all` matches no `smb`/`nmb`/`samba` unit. So
  **`nfs-server` is the ONLY export path for the NAS data** — not one of two. That
  matters when reasoning about availability: it exited 1/FAILURE on 2026-07-24 and
  stayed down 37 days unnoticed (§3.16). Do not restore `smbd` to this sentence
  without checking the box first. See BACKLOG §6.13.

## Storage — separation is logical, so be precise

- Storage is **two-tier**: HOT = the 4 TB NVMe (LVM, live NAS, k8s PVs via `local-path`;
  OS on the 256 GB eMMC); COLD = two SATA RAID 1 mirrors — 8 TB primary (`/mnt/cold-8t`) +
  ~5.45 TB copy (`/mnt/cold-sec`).
- On the NVMe the LVM VG (`vg_microshift`) is backed by a **sparse loop device**
  (`/mnt/nvme0n1p2/microshift-lvm.img`, attached as `/dev/loop100` by systemd). k8s PVs
  use the `local-path` StorageClass (k3s built-in). Never provision against `lv_nas`.
- The cold disks are the **only copy-of-record** for NAS data and cluster state. Never
  `mkfs`/`wipefs` them, and never run `restic forget`/`prune` — retention is handled by the
  backup timers only.
- One NVMe + two cold disks in one box = **one failure domain**. Before any hot-tier
  storage change, confirm the last backup succeeded. Flag — don't perform — anything that
  could risk both tiers at once.

## k3s / Kubernetes specifics

- The H4 runs **k3s** (not MicroShift). Use `kubectl`, not `oc`.
- Ingress is **Traefik** (k3s default). Workloads expose via `networking.k8s.io/v1 Ingress`,
  not OpenShift `Route`. If an Ingress doesn't resolve, suspect DNS before the cluster.
- StorageClass is **`local-path`** (k3s built-in). Never reference `topolvm-provisioner`.
- Security is standard **PodSecurityAdmission** (not SCCs). If a workload needs elevated
  permissions, fix the `securityContext` — never set `privileged: true`.
- Confirm the StorageClass name with `kubectl get sc` rather than assuming it.
- DNS is load-bearing: `api.lab.home.arpa` must resolve to `192.168.1.200` (kube-vip
  control-plane VIP); `*.apps.lab.home.arpa` must resolve to **`192.168.1.201`**
  (kube-vip service VIP for Traefik). If Ingress doesn't resolve, check DNS first.
  Source of truth is `ingress_vip` in `ansible/inventory/hosts.yml`, applied by
  `ansible/playbooks/dns.yml`. **Not `192.168.1.160`** — that was the H4's own node IP
  until 2026-07-27, a single A record whose loss took down every service URL in the
  lab. If you find `.160` on the wildcard, that is the fault, not the fix.
  (`.160` on `h4-core.lab.home.arpa` is correct and expected — it is the H4's node
  IP. Only the *wildcard* pointing there is the fault.)
- **DNS is now probed — check the probes before checking anything else.** Since
  2026-09-02 (§3.3) blackbox queries all four resolvers every 60s and asserts the
  ANSWER, not just that one arrived: `api.lab.home.arpa` must be `.200`, the
  `*.apps` wildcard must be `.201` and must NOT contain `.160`. Read it with
  `probe_success{job=~"dns-.*"}` — 16 series, all 1 when healthy.
  `LabDNSWrongAnswer` is critical precisely because a resolver that is up and wrong
  is worse than one that is down: clients fail over from a dead resolver, and use a
  wrong answer indefinitely. That was the 2026-07-27 shape.

## Secrets

- Never read aloud, echo, or commit: `/etc/restic/password`, `ansible/.vault_pass`,
  `ansible/files/pull-secret.json`, any kubeconfig or k3s token. These are
  `.gitignore`d — keep it that way.

## Verify before asserting

- Package names, StorageClass names, and exact CLI flags vary by k3s release and distro.
  Check current docs rather than relying on memory; say so when unsure.
- **Check the artifact the consumer reads, not the config you wrote.** Config can be
  correct while the thing consuming it sees something else. `resolvectl dns` showed
  three resolvers per link while `/run/systemd/resolve/resolv.conf` — the file the
  kubelet actually reads — held six (BACKLOG §4.12). Argo reported Synced and Healthy
  on an Alloy config whose journal mount had never existed, because Helm discards
  unknown value keys silently (§3.9). In both cases every status signal was green and a
  single number was the whole diagnosis:
  `grep -c nameserver /run/systemd/resolve/resolv.conf`, and `loki_relabel_cache_size`
  returning 1 for 6800 entries. Prefer a number that can only be produced by the work
  actually happening.
- **Empty output is not a finding until you prove the check can speak.** A healthy
  Alertmanager receiver logs nothing on first-attempt success; a mistyped label selector
  prints the same `No resources found` as a deleted workload; `findmnt /a /b /c /d` returns
  nothing whatever is mounted. On 2026-08-26 all three were read as faults and all three
  were fine. Before treating absence as evidence, run the same query against a case known
  to be true. That control costs one command and has twice produced a finding of its own —
  it is how §3.14 (Prometheus evicting at ~14d under a `30d` config) was discovered.
- **Ask what the person actually saw before investigating why they saw nothing.** An hour
  went into finding the defect in an alerting pipeline that had none, because "found it in
  the Argo UI" was silently expanded into "no alert arrived." It had arrived. The cheapest
  diagnostic in this lab is a question.
- **A dry run that prints no verification has verified nothing.** Ansible skips
  `command` tasks under `--check`, so a play's closing `debug` message will happily
  assert success during a run that changed nothing. Put `check_mode: false` on
  read-only verification commands and gate the summary on `ansible_check_mode`. This
  was written twice in one day, the second time immediately after fixing the first.

## The fleet

The H4 is the core (k3s server + NAS, Ubuntu 22.04, `192.168.1.160`) — **but it also
holds `192.168.1.156` on a second interface, and that is the address it often speaks
from.** `enp1s0` (.156) and `enp2s0` (.160) are both on the same /24 at metric 100, so
which one sources outbound LAN traffic is not pinned: `ip route get 192.168.1.128`
returns `dev enp1s0 src 192.168.1.156`. Found 2026-09-05 in Vault audit logs, where the
H4 appeared as an address documented nowhere. **Never allowlist, firewall or match the
H4 by a single IP** — use both, and see BACKLOG §2.9 and §4.12, which share this cause. The two
**Orange Pi 5 Pro** boards (8C/16GB/NPU) are k3s agents / AI inference hosts; RPi 5
runs Vault; RPi 4B runs Pi-hole (192.168.1.116) as the DNS **secondary**; opi-zero2w-1 (192.168.1.184) is the **tertiary** dnsmasq fallback, NOT the secondary — corrected 2026-09-02, see BACKLOG §4.12; opi-zero2w-3 (192.168.1.217) is a **fourth, fully working dnsmasq resolver that nothing currently queries** — it is configured by `dns.yml` but is absent from `lab_dns_servers`, and 2026-09-02's probes confirmed it answers every lab name correctly and authoritatively (`local=/lab.home.arpa/`, so it is a real spare, not a forwarder). Do not describe the lab as having three resolvers; Home Assistant runs as a k3s Deployment in the `home-assistant` namespace; lldap runs as a k3s Deployment in the `lldap` namespace (ldap-1 VM decommissioned
2026-07-04); the XU3 is a build agent. DNS needs a permanent host.
M5Stack + OPi NPUs are edge inference endpoints, not cluster nodes.
The map's plaintext credentials must be rotated. See `docs/HARDWARE.md`.