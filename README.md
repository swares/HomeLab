# Home Lab — DevOps Environment

A GitOps-managed home lab built around an **Odroid-H4 Ultra** that serves double duty as
a NAS and a single-node **MicroShift** (OpenShift) cluster, with an optional ARM
expansion fleet. Infrastructure is defined as code: **Ansible** stands the host up,
**Argo CD** runs everything inside the cluster from this git repo, and a two-tier storage
model (hot NVMe + two cold SATA disks) keeps data safe.

![Topology](docs/diagrams/architecture.svg)

## Why it's shaped this way

- **MicroShift, not full SNO** — the H4 is also the NAS, and full Single-Node OpenShift
  would eat all 8 cores and require RHCOS (which can't host NAS services). MicroShift runs
  as one systemd service alongside Samba/NFS and leaves most of the box free.
- **Argo CD, not imperative ops** — Claude (and you) change the cluster by editing git and
  opening PRs. Argo reconciles with `selfHeal` on, so drift reverts and rollback is
  `git revert`. The cluster is almost never touched with imperative `oc apply`.
- **Two storage tiers** — a fast 4 TB NVMe for etcd/PVs/live NAS (OS on the 256 GB eMMC),
  and **two SATA disks** (8 TB primary + 6 TB restic copy) for backups and archive. The
  disks are mismatched, so it's two independent copies, not a RAID mirror. See
  [storage tiers](docs/diagrams/storage-tiers.svg).

## Repo map

| Path | What it is |
|------|------------|
| `ansible/` | Host provisioning: storage, MicroShift install, backups, Argo bootstrap |
| `gitops/` | What Argo deploys — `bootstrap/` (app-of-apps), `apps/`, `workloads/` |
| `docs/` | standup guide, service catalog, capability overview, **Lab design (start here)**, architecture, hardware, AI inference, runbook, security, diagrams |
| `.claude/settings.json` | Permission guardrails for Claude operating the lab |
| `CLAUDE.md` | Operating rules Claude reads automatically |
| `terraform/` | **Proxmox IaaS (OpenTofu)** — `bpg/proxmox` module + k3s VM pool |
| `Makefile` | `make storage / microshift / backup / argocd / all` |

## Quickstart

> Full step-by-step (partition map, RAID creation, DNS records) is in
> [docs/RUNBOOK.md](docs/RUNBOOK.md). This is the short version.

1. **Prereqs** — host OS on the 256 GB eMMC, a free NVMe partition reserved for LVMS, the
   two SATA disks ready; a Red Hat pull secret at `ansible/files/pull-secret.json`; a DNS host
   serving the records in the runbook (the map leaves DNS unassigned — pick one); SSH key
   access as the inventory user.
2. **Set your repo URL** — replace `YOURUSER` in `gitops/bootstrap/root-app.yaml`,
   `gitops/apps/*.yaml`, and `ansible/playbooks/argocd.yml`.
3. **Dry run, then build:**
   ```bash
   make check          # ansible --check, no changes
   make storage        # RAID assemble + LVM tiers
   make microshift     # install + configure MicroShift
   make backup         # restic + etcd backup timers
   make argocd         # Argo CD + app-of-apps
   ```
4. **Verify** — `oc get nodes`, then open `https://argocd.apps.lab.home.arpa`.

## Day-to-day

Add a workload by adding a directory under `gitops/workloads/` and an `Application` in
`gitops/apps/` — merge to `main` and Argo deploys it. Change anything by editing git, never
by poking the cluster. The [sample app](gitops/workloads/sample-app/) is a working template.
