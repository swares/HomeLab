# Case study: running a home lab like production, and hunting the failures that report success

*Scott Wares · October 2026 · [github.com/swares/HomeLab](https://github.com/swares/HomeLab)*

## The short version

I built a 14-host platform at home and ran it the way I'd want a production platform
run: every change by pull request, everything reconciled from git, backups that are
restored rather than assumed, and an honest backlog. The most valuable thing it taught
me wasn't a tool. It was a pattern. **The failures that hurt most were the ones
reporting success.** A backup that passed nightly and copied nothing. A log pipeline
that was healthy and shipped nothing. A hardening task that said `ok` while the control
plane accepted passwords. Most of what follows is how I found those, and the habits I
built so the next one surfaces sooner.

## What it is

| | |
|---|---|
| **Fleet** | 14 hosts, x86 and ARM64: an Odroid-H4 (k3s server plus NAS), three N150 mini PCs, two Orange Pi 5 Pros with NPUs, Raspberry Pis, Orange Pi Zero 2Ws |
| **Cluster** | 3-node HA k3s control plane behind kube-vip, plus 2 ARM64 agents |
| **Delivery** | Argo CD app-of-apps plus an ApplicationSet, `selfHeal` and `prune` on, about 20 applications. CI runs YAML lint, kubeconform, collision checks and OPA/conftest on every PR |
| **Hosts as code** | 61 Ansible playbooks, OpenTofu with remote state, Packer images, Renovate |
| **Platform services** | Vault with External Secrets, cert-manager private CA, Authelia and lldap SSO, Kyverno in Enforce mode |
| **Observability** | Prometheus, Grafana, Alertmanager, Loki, Alloy, blackbox probes |
| **Data** | Two RAID 1 cold mirrors, restic, offsite to Cloudflare R2, etcd and Vault snapshots |
| **Pace** | About 600 merged pull requests between June and October 2026 |

## Decisions worth explaining

**k3s, not full Kubernetes.** The core box is also the NAS. k3s runs as one systemd
service next to the NFS server and leaves most of the machine free.

**Git is the only way in.** No `kubectl apply` to `main`. Argo reverts drift, so
imperative fixes don't even stick, and rollback is `git revert`. The git history is
the audit log.

**One backlog, ranked by consequence.** Early on, six different TODO lists disagreed.
Offsite backup was marked done in three of them while it had never copied a byte. I
consolidated everything into a single `BACKLOG.md`, ordered by *what happens if this is
ignored* rather than by effort, and a script audits it for items marked done that still
have open boxes.

**A break-glass envelope, tested.** A printed set of recovery credentials stored
offline, and drills that recover using *only* what's in the envelope.

## Failures that reported success

### The offsite backup that passed every night

The `backup-offsite` unit existed and ran nightly. It exited 0 and reported PASSED. But
the variable naming the offsite repository had never been set, so it never copied a
byte. Three documents called offsite backup done.

**Fix:** wired the repository, seeded about 204 GiB over three days, and added the
offsite repo to the nightly verification job. **Lesson:** a check that cannot fail is
not a check.

### The restore drill that would have passed with zero bytes

Before the first restore drill, I reviewed the procedure and found it would have
restored from a path that was empty. It would have restored nothing, exited 0, and gone
into the results table as a success: the same shape as the backup bug. I retargeted it
at real content.

**Result:** the first restore in the lab's history. A database dump came back from the
offsite repo onto a throwaway VM with no lab config, using only two envelope items. It
was **byte-identical** to the original (sha256 matched), in **9 minutes 23 seconds**
end to end. Later drills covered the other envelope items, including restoring Vault
from a snapshot.

### Seven weeks of a healthy log pipeline that shipped nothing

A backup verification job wrote its results to the journal. None of it reached Loki.
The cause stacked four deep:

1. The Helm values used two keys that don't exist in the chart. **Helm silently
   discards unknown values**, so the volume was never mounted, on any node.
2. With the mount fixed, the container's `/etc/machine-id` was empty, so the journal
   reader looked for a journal belonging to no machine. It found zero entries, which
   is not an error.
3. With that fixed, every line from every node arrived with one label set. The relabel
   ran after the stage that strips the labels it needed. One metric gave it away:
   `loki_relabel_cache_size 1` across 6,800 entries.

Argo said Synced and Healthy the entire time. **Lesson:** check the artifact the
consumer actually reads, and prefer a number that can only be produced by the work
actually happening.

### "Password authentication is disabled": it wasn't

An Ansible task had reported `ok` on "ensure SSH password authentication is disabled"
for months. `sshd -T`, which prints the settings sshd actually uses, showed password
auth **enabled on the entire k3s control plane**. Ubuntu's `sshd_config` includes
`sshd_config.d/*.conf` near the top, sshd takes the *first* occurrence of a setting,
and cloud-init's drop-in said `yes`. On one host the task would have restarted sshd,
reported success, and changed nothing.

**Fix:** a `00-lab-hardening.conf` drop-in (the `00-` sorts first, so it wins), with
`sshd -t` before the restart and an assertion on `sshd -T` after.

**What happened next is the part I'd tell in an interview.** Three days after going
key-only, a Windows laptop was locked out of all 14 hosts. It had never been given a
key, and password auth had been carrying it without anyone knowing. The break-glass key
got me back in, which proved the envelope worked under real pressure. Workstation keys
are now managed by a playbook. **Lesson:** before removing an authentication method,
list who is actually using it, not what the config says.

### A dead NFS server nobody could see for 37 days

The first run of a new drift check found `nfs-server` on a hypervisor had been failed
for 37 days, which broke VM live migration between hosts. Monitoring couldn't see it
because the systemd collector had been scoped to backup units only. For every other
unit, the metric didn't exist, so no alert rule could find it.

**Lesson:** a missing series is worse than a failing rule, because no query can be
written that finds it.

### Fifteen days without a Vault snapshot, and an alert that did fire

Nightly Vault snapshots stopped. Three defects stacked in a six-line setup recipe:

- the token was a child of an admin token that's deliberately allowed to expire, so it
  was revoked with its parent;
- its requested ten-year period was silently capped at 32 days;
- and nothing renewed it.

The interesting part: **the alert fired correctly every night.** It went to one phone,
and that phone had been stolen. Monitoring didn't fail; delivery did.

**Fix:** an orphan token with the period Vault actually honours, renewed before every
snapshot. I verified the token's *properties*, not just that a snapshot landed,
because a non-orphan token would also have worked today and died again in 26 days.
**Lesson:** alert delivery is part of monitoring, and one subscriber is a single point
of failure.

## Two outages

**One DNS record took down every service URL.** The `*.apps` wildcard pointed at a
single node's IP. When that changed, every service went dark at once. The wildcard now
points at a kube-vip VIP. Blackbox probes query all four resolvers every minute and
assert the *answer*, not just that one came back, because a resolver that is up and
wrong is worse than one that is down. Before trusting the probes, I ran a control: the
same check against a public resolver that can't know lab names had to fail, and did.

**The core box wouldn't finish booting.** After a reboot, boot stopped before SSH. My
first theory, RAID metadata, was wrong; both arrays were healthy. The real cause was a
systemd dependency cycle: the NAS mount needed a logical volume created by a service
that only ran *after* local filesystems were mounted. It had been latent for **62
days**, waiting for a reboot. The fix was an explicit `x-systemd.requires` on the
mount, plus `nofail` on data mounts. Recovery also exposed a Postgres pod sized for
idle rather than for WAL replay, which OOM-killed seven times, so I resized it. It was
confirmed by a clean unattended reboot, and the full write-up is
[`docs/INCIDENT-2026-08-23-h4-boot.md`](INCIDENT-2026-08-23-h4-boot.md).

## Habits that came out of it

These are written into the repo's operating rules, and they're how I'd work on a
team:

- **Check the artifact the consumer reads, not the config you wrote.** Use `sshd -T`,
  not `grep sshd_config`, and the kubelet's actual `resolv.conf`, not `resolvectl`.
- **Empty output isn't a finding until you prove the check can speak.** Run the same
  query against a case known to be true. That habit uncovered that Prometheus was
  evicting data at about 14 days under a 30-day setting, because a size limit wins
  first.
- **A dry run that prints no verification has verified nothing.** Ansible skips command
  tasks in check mode, so summaries are gated on it.
- **Restore, don't assume.** A backup you haven't restored is a hypothesis.
- **Write down wrong theories.** The incident record says plainly that my first
  diagnosis was wrong, so nobody reopens it.

## What's still open

Each of these is tracked in [`BACKLOG.md`](../BACKLOG.md):

- **No host firewall anywhere yet.** The plan is to discover the real flows first,
  then write rules.
- **Vault serves plain HTTP on the LAN.**
- **Prometheus keeps about two weeks of history, not the configured 30 days.**
- **Unit monitoring is still narrower than it should be.**
- **One board still runs Ubuntu 16.04**, and the decision is retire or rebuild.

## Related

The cloud counterpart, [HomeLab-aws](https://github.com/swares/HomeLab-aws), applies
the same approach to an EKS cluster that's built from nothing and destroyed nightly.
Its [case study](https://github.com/swares/HomeLab-aws/blob/main/docs/CASE-STUDY.md)
covers IRSA, controller-created load balancers, and cost guardrails.
