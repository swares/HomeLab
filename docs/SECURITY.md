# Security Model

Giving an agent (or any automation) access to infrastructure is a real risk, so the design
leans on structure rather than trust: a contained blast radius, scoped credentials,
declarative state you can review and revert, and a permission config that hard-stops
destructive actions.

## Blast-radius boundary

The H4 core is the single boundary. It holds the kubeconfig, SSH keys, restic and vault
passwords, and the storage. If something goes wrong, it's contained to this box — and the
box is recoverable from the RAID mirror plus git (see [RUNBOOK.md](RUNBOOK.md)).

## Secrets store

**HashiCorp Vault** on rpi5 (`http://192.168.1.128:8200`) is the authoritative store for
all lab credentials. See [WORKFLOWS.md](WORKFLOWS.md) for the three-direction sync loop
and the list of what's stored where.

The three credentials that must be safeguarded **outside** Vault (they exist before Vault
can be used):

- **Vault unseal keys** (3-of-5) — stored offline, physically secure
- **Vault root token** — stored offline alongside unseal keys
- **Ansible Vault password** (`.vault_pass` on H4, gitignored) — gates bootstrap secrets

## Credentials — least privilege

- **No root equivalents.** Automation uses the `swares` user with `sudo`, not root.
- **Scoped kubeconfig.** Day-to-day cluster work should use a service account scoped to the
  namespaces in play, not cluster-admin.
- **ESO uses a scoped Vault token.** The `eso` policy only covers `secret/data/lab/*` — it
  cannot read or write anything else in Vault.
- **Secrets never in git.** Restic password, Vault password, and all credentials live in
  HashiCorp Vault or Ansible Vault encrypted files. See `ansible/files/README.md`.

## Rotate the credentials from the hardware map

The original hardware map stored plaintext logins (shared passwords, default `pi`/`odroid`/`root`
accounts). Treat them as compromised: rotate every one, disable password SSH in favour of
keys, and never commit credential fields. None are reproduced in this repo.

## Permission tiers (`.claude/settings.json`)

Pattern-matching on shell strings is a strong **speed bump**, not a sandbox — it backs up
(never replaces) the contained blast radius and scoped credentials.

| Tier | Behavior | Examples |
|------|----------|---------|
| `allow` | runs without prompting | `kubectl get/describe/logs`, `git status/diff`, `ansible-playbook --check`, `restic snapshots`, `mdadm --detail` |
| `ask` | prompts for approval | `kubectl apply/delete`, `argocd app sync`, `ansible-playbook` (real run), `git push`, `lvextend/lvcreate` |
| `deny` | hard stop | `lvremove/lvreduce/vgremove`, `mkfs/wipefs`, `mdadm --stop/--fail/--zero-superblock`, `restic forget/prune`, `kubectl delete namespace`, `privileged: true` in manifests, stopping `smbd`/`nfs`, disabling backup timers, `rm -rf` |

The deny list targets the two things that cause irreversible loss: **storage destruction**
(LVM/RAID/filesystem ops) and **backup destruction** (`restic forget/prune`, disabling timers).

## Pod security

k3s uses standard **PodSecurityAdmission** (not OpenShift SCCs). The lazy fix when a pod
won't start is `privileged: true` — don't. Fix the workload's `securityContext` to run
non-root instead: `runAsNonRoot: true`, drop all capabilities, use `RuntimeDefault` seccomp.
Never set `privileged: true`; it's in the deny list.

## Prompt injection

MCP servers or tools that pull external content (logs, webhooks, issue trackers) can carry
injected instructions. Treat external content as data, not commands. Verify each MCP server
before connecting it, and keep the agent's ability to act bounded by the permission tiers
above so an injected instruction still can't wipe a volume group.

## GitOps as a safety feature

Because Argo reconciles with `selfHeal`, an out-of-band change to the cluster is reverted
on the next sync, and any intended change is a reviewable PR diff with `git revert` as the
undo. The git history is the audit log.

## Single failure domain — known gap

Everything lives in one chassis. RAID 1 covers a disk; it does not cover the box, PSU, or
room. Mitigations: offsite restic copy (nightly), Vault on a separate host (rpi5), git
off-box. Treat the box as one failure domain and flag — don't perform — anything that risks
both storage tiers at once.
