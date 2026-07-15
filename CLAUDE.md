# CLAUDE.md — operating rules for this lab

You are helping operate a home lab whose core is an **Odroid-H4 Ultra** that is *both* a
NAS and a single-node **k3s** cluster (Ubuntu 22.04). Read this before acting. Full context
is in `docs/` (start with `ARCHITECTURE.md`).

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

## This box has two roles — keep them separate

- The **cluster layer is yours to manage**. The **NAS services (`smbd`/`nfs`) and the data
  they serve are off-limits** — never stop, restart, or reconfigure them, and never disable
  the backup timers (`backup-nas`, `backup-etcd`).

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
  VIP); `*.apps.lab.home.arpa` must resolve to `192.168.1.160` (Traefik ingress).
  If Ingress doesn't resolve, check DNS first.

## Secrets

- Never read aloud, echo, or commit: `/etc/restic/password`, `ansible/.vault_pass`,
  `ansible/files/pull-secret.json`, any kubeconfig or k3s token. These are
  `.gitignore`d — keep it that way.

## Verify before asserting

- Package names, StorageClass names, and exact CLI flags vary by k3s release and distro.
  Check current docs rather than relying on memory; say so when unsure.

## The fleet

The H4 is the core (k3s server + NAS, Ubuntu 22.04, `192.168.1.160`). The two
**Orange Pi 5 Pro** boards (8C/16GB/NPU) are k3s agents / AI inference hosts; RPi 5
runs Vault; RPi 4B runs Pi-hole (secondary DNS, 192.168.1.116); lldap runs as a k3s Deployment in the `lldap` namespace (ldap-1 VM decommissioned
2026-07-04); the XU3 is a build agent. DNS needs a permanent host.
M5Stack + OPi NPUs are edge inference endpoints, not cluster nodes.
The map's plaintext credentials must be rotated. See `docs/HARDWARE.md`.