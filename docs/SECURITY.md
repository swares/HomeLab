# Security Model

Giving an agent (or any automation) access to infrastructure is a real risk, so the design
leans on structure rather than trust: a contained blast radius, scoped credentials,
declarative state you can review and revert, and a permission config that hard-stops
destructive actions.

## Blast-radius boundary

The H4 core is the single boundary. It holds the kubeconfig, the SSH keys, restic and vault
passwords, and the storage. If something goes wrong, it's contained to this box — and the
box is recoverable from the RAID mirror plus git (see [RUNBOOK.md](RUNBOOK.md)).

## Rotate the credentials from the hardware map

The Hardware2 mindmap stored **plaintext logins** (shared passwords across the fleet, and
default `pi`/`odroid`/`root` accounts). Treat them as compromised: rotate every one, disable
password SSH in favor of keys, and never commit the map's credential fields. None are
reproduced in this repo.

## Credentials — least privilege

- **No `root@pam`-equivalent.** Automation uses a dedicated `ansible` user with `sudo`,
  not the root account.
- **Scoped kubeconfig.** Day-to-day cluster work should use a service account scoped to the
  namespaces in play, not cluster-admin. The bootstrap kubeconfig is for setup only.
- **Secrets never in git.** Pull secret, restic password, and vault password live on the
  host or in vaulted/`.gitignore`d files. See `ansible/files/README.md`.

## Permission tiers (`.claude/settings.json`)

Pattern-matching on shell strings is a strong **speed bump**, not a sandbox — it can be
bypassed by command rewriting, so it backs up (never replaces) the contained blast radius
and scoped credentials. The tiers:

| Tier | Behavior | Examples |
|------|----------|----------|
| `allow` | runs without prompting | `oc get/describe/logs`, `git status/diff`, `ansible-playbook --check`, `restic snapshots`, `mdadm --detail` |
| `ask` | prompts for approval | `oc apply/delete`, `argocd app sync`, `ansible-playbook` (real run), `git push`, `lvextend/lvcreate` |
| `deny` | hard stop | `lvremove/lvreduce/vgremove/pvremove`, `mkfs/wipefs`, `mdadm --stop/--fail/--remove/--zero-superblock`, `restic forget/prune`, `oc delete project/namespace`, `add-scc-to-user privileged/anyuid`, stopping `smbd`/`nfs`, disabling backup timers, `rm -rf` |

The deny list is built around the two things that cause irreversible loss here: **storage
destruction** (LVM/RAID/filesystem ops) and **backup destruction** (`restic forget/prune`,
disabling timers). Growing volumes (`lvextend`) is `ask`, not `deny`, since it's a
legitimate occasional need.

## OpenShift SCCs — don't loosen them

MicroShift enforces Security Context Constraints (no root by default). The lazy fix when a
pod won't start is to grant it `privileged` or `anyuid` — **don't**. That's denied in the
permission config. Fix the workload's `securityContext`/image to run non-root instead; the
[sample app](../gitops/workloads/sample-app/deployment.yaml) shows the right shape
(`runAsNonRoot`, dropped capabilities, `RuntimeDefault` seccomp).

## Prompt injection

MCP servers or tools that pull external content (logs, webhooks, issue trackers) can carry
injected instructions. Treat external content as data, not commands. Verify and trust each
MCP server before connecting it, and keep the agent's ability to act bounded by the tiers
above so an injected instruction still can't, e.g., wipe a volume group.

## GitOps as a safety feature

Because Argo reconciles with `selfHeal`, an out-of-band change to the cluster (accidental or
injected) is reverted on the next sync, and any intended change is a reviewable PR diff with
`git revert` as the undo. The git history is the audit log.

## Single failure domain — known gap

Everything lives in one chassis. RAID 1 covers a disk; it does not cover the box, PSU, or
room. The mitigation on the roadmap is an offsite restic copy (3-2-1). Until then, treat the
box as one failure domain and flag — don't perform — anything that risks both storage tiers
at once.
