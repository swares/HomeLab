# CLAUDE.md — operating rules for this lab

You are helping operate a home lab whose core is an **Odroid-H4 Ultra** that is *both* a
NAS and a single-node **MicroShift** cluster. Read this before acting. Full context is in
`docs/` (start with `ARCHITECTURE.md`).

## How changes are made

- **Everything is GitOps.** Change the cluster by editing files under `gitops/` and opening
  a **pull request** — never `oc apply` to `main` directly, and never push straight to
  `main`. Argo CD reconciles from git with `selfHeal` on, so imperative changes drift and
  get reverted anyway.
- To undo something, `git revert`. The git history is the audit log.
- Host changes go through the Ansible playbooks in `ansible/`. Run `--check` first; a real
  run is an `ask` action.

## This box has two roles — keep them separate

- The **cluster layer is yours to manage**. The **NAS services (`smbd`/`nfs`) and the data
  they serve are off-limits** — never stop, restart, or reconfigure them, and never disable
  the backup timers (`backup-nas`, `backup-etcd`).

## Storage — separation is logical, so be precise

- Storage is **two-tier**: HOT = the 4 TB NVMe (etcd, live NAS, fast PVs; OS on the 256 GB
  eMMC); COLD = **two independent SATA disks** — 8 TB primary (`/mnt/cold-8t`) + 6 TB copy
  (`/mnt/cold-6t`). The disks are mismatched (8+6), so there is **no RAID mirror**.
- On the NVMe the separation between cluster and NAS is **LVM logical volumes, not separate
  disks** — so precision matters. k8s PVs come **only** from the LVMS VG. Never provision
  against `lv_nas` or `lv_root`.
- The cold disks are the **only copy-of-record** for NAS data and cluster state. Never
  `mkfs`/`wipefs` them, and never run `restic forget`/`prune` — retention is handled by the
  backup timers only. The 6 TB holds the redundant `restic copy`; don't let the two diverge.
- One NVMe + two cold disks in one box = **one failure domain**. Before any hot-tier
  storage change, confirm the last backup succeeded. Flag — don't perform — anything that
  could risk both tiers at once. (There is currently **no off-box copy**.)

## OpenShift / MicroShift specifics

- MicroShift enforces **SCCs**. If a workload won't start because it wants root, **fix the
  manifest's `securityContext`** (run non-root, drop capabilities) — **never** grant
  `privileged`/`anyuid` to unblock it.
- Confirm the LVMS `StorageClass` name with `oc get sc` rather than assuming it.
- DNS is load-bearing: `api.lab.home.arpa` and `*.apps.lab.home.arpa` resolve to the node.
  If Routes don't resolve, suspect DNS before the cluster. DNS host is currently unassigned
  (the old Pi-hole Zero now runs Grafana) — it needs a home.

## Secrets

- Never read aloud, echo, or commit: `/etc/crio/openshift-pull-secret`,
  `ansible/files/pull-secret.json`, `/etc/restic/password`, `ansible/.vault_pass`, any
  kubeconfig. These are `.gitignore`d — keep it that way.

## Verify before asserting

- Package names, repo enablement, StorageClass names, and exact CLI flags vary by MicroShift
  release and distro. Check current docs rather than relying on memory; say so when unsure.

## The fleet

The H4 is the core. The two **Orange Pi 5 Pro** boards (8C/16GB/NPU) are the strongest ARM
nodes and the natural k3s control plane for an **optional Phase-2 cluster** (separate, since
MicroShift is single-node); RPi 5/4B are agents (Vault, OpenLDAP), the XU3 is a build agent.
DNS is unassigned and needs a host. M5Stack + the OPi NPUs are edge inference endpoints, not
nodes. The map's plaintext credentials must be rotated. See `docs/HARDWARE.md`.
