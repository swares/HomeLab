# Lab backlog — consolidated 2026-08-07

**This is the only list of open work.** Everything else points here.

Swept from every `.md` file and all code/config in the repo. The sections it replaced
have been collapsed to pointers: `README.md`, `docs/OVERVIEW.md`, `docs/services.md`,
and the dated `TODO-2026-07-14.md` / `TODO-2026-07-23.md` / `TODO-2026-08-03.md` files,
which are now historical session notes — keep them for the reasoning, not the tasks.

The reason for consolidating: those six lists disagreed. Offsite backup was marked
**DONE** in three of them while the unit had never copied a byte, the Vault root token
was listed as a required credential in three more after being deliberately eliminated,
and two files end mid-sentence. Contradictions in a task list are worse than an empty
one, because they get believed during an incident. Remaining contradictions are
catalogued in §6 rather than silently fixed, so they can be checked before deletion.

**When you finish something**, tick it here. **When you find something**, add it here.
If you are tempted to start a list somewhere else, add a pointer to this file instead.

Ordered by **what happens if it is ignored**, not by effort.

Items marked **verified** were checked against the code, not just read from another
document — several older findings turned out to be stale, and several documents
contradict each other. Where a claim rests only on an older doc it says so, and
**needs confirming** means exactly that.

One caution learned while compiling this: a file-glob run against the Windows working
copy reported `tools/` as absent when `tools/sdcard/` plainly exists on the H4. Prefer
`ls` on the host you actually care about over tooling run against a second clone.

---

## 1. Data loss — the things that end the lab

### 1.1 No restore has ever been performed
`docs/BACKUP-RESTORE.md:354-372`, `docs/REVIEW-2026-07-24.md:124-144` (C2)

> `| — | *no restore has ever been tested* | — | — | See §5 |`

The backup chain is now genuinely good: three repos, retention, verification, alerting,
offsite seeding. **None of it has ever been proven to restore anything.** The drill
table has an empty first row. This is the single largest risk in the lab and the one
item that makes every other backup improvement conditional.

Do: one restic restore and one etcd restore into scratch, timed, recorded in the table.

### 1.2 The offline break-glass envelope does not exist
`docs/BACKUP-RESTORE.md:91-111`

A printed or encrypted-USB copy, kept **off-site**, of the credentials needed to
recover when everything is gone:

1. The restic password (`/etc/restic/password`) — **rotated 2026-08-07, so any
   existing copy is now wrong**
2. The R2 restic password (`/etc/restic/cloud-password`) and R2 API credentials —
   note this now also guards the `homelab-nas` offsite repo, which reuses it
3. The k3s server token
4. The Vault unseal shares (3 of 5) — the doc still says "and root token"; as of
   08-07 there deliberately isn't one, and the shares alone are the break-glass
5. The Ansible vault password

The loop it breaks, in the doc's own words: the runbook says to get the restic
password from Vault; Vault runs on the RPi5; Vault's raft snapshots live on
`/mnt/cold-8t`, on the H4. Lose the H4 and you need restic to recover and Vault to
get restic's password. No automation can close that — something has to live outside
both systems.


`docs/BACKUP-RESTORE.md:95-111`, `docs/REVIEW-2026-07-24.md:120-122` (C8)

> `**Break the loop with the offline envelope.** This is not yet solved in automation.`

Vault holds the restic passwords; restic holds Vault's snapshots. Total loss of the H4
*and* the RPi5 leaves encrypted data and no key. Needs, on paper, off-site:
restic password, R2 password + API creds, k3s server token, Vault unseal shares,
Ansible vault password.

Note the doc's list still says "Vault root token" — as of 08-07 there deliberately
isn't one. See §6.3.

### 1.3 Finish the offsite tier
`TODO-2026-08-03.md:274`, `ansible/playbooks/backup-offsite.yml:56`

**SEED COMPLETE 2026-08-11 02:19 UTC.** ~3.1 days wall clock, 44m35s CPU, ~204 GiB.
Retention applied on the first run, keeping 32 snapshots across five groups
(2 nas-old-paths + 11 nas + 8 lldap users.db + 7 lldap /tmp + 4 lldap /dump).
`hc-ping: backup-offsite success OK`.

Remaining:

- [ ] **Enable `backup-offsite.timer`** — `-e offsite_timer_enabled=true`. Do this
      promptly: the success ping **un-paused** the healthchecks.io check, so it is
      now counting down against Period 25h / Grace 3h with no scheduled run to
      satisfy it. It will false-alarm ~28h after 02:19 UTC.
- [x] **Add `homelab-nas` to `backup-verify.sh`** — done 08-11 (§1.3b closed).

**Bug found by the first real run, fixed:** the completion line read
`offsite copy + retention complete — 1 snapshots at destination` while retention had
just kept 32. `restic snapshots --json` emits the whole array on one line, and
`grep -c` counts matching *lines*, not matches. The assertion still caught the zero
case (an empty array has no `"short_id"`), but the reported number was meaningless.
Now `grep -o … | wc -l`. Same family as the `grep -q`/pipefail bug in the immich dump
job — a grep flag answering a subtly different question than the one asked.

*(An earlier version of this entry said to commit an untracked
`gitops/workloads/lldap/restic-pv.yaml`. That was wrong — see §1.8. The PV never
existed in the cluster and the file has since disappeared from the working tree.)*

**Chunker params verified 08-09** — the one setting that cannot be changed after init:

    /mnt/cold-8t/restic  (4154928a)  chunker_polynomial 30f6553d487a79
    R2 homelab-nas       (d7ac04b8)  chunker_polynomial 30f6553d487a79

Identical, so `--copy-chunker-params` took and dedup between the two repos is
preserved. Had they differed, the remote would be re-chunking everything and the only
fix would be emptying the bucket and re-seeding.

### 1.3b ~~`backup-verify` does not check the offsite repo~~ — **DONE 08-11**
`ansible/templates/backup-verify.sh.j2` §5

It checked the primary, cold-sec and the R2 *cloud* repo (`homelab-backup`), but not
`homelab-nas` — so the tier that exists specifically to survive losing the H4 was the
only one with no weekly integrity check. Added once the seed completed; running it
against a half-populated repo would only have produced noise.

Three deliberate choices:

- **`check` without `--read-data`.** Re-reading 204 GiB from R2 every week would cost
  hours and, on a metered link, real money. Structural verification catches a corrupt
  or truncated upload, which is the failure this guards against.
- **Every call names `-r` and `--password-file` explicitly.** Section 4 exports
  `RESTIC_REPOSITORY` and `RESTIC_PASSWORD_FILE` for the *cloud* repo and they are
  still set; the flags win over the environment. Relying on the env here is how you
  end up verifying one repo twice and another never.
- **A recency check as well as integrity.** A clean `check` on a repo that stopped
  receiving copies three weeks ago still passes. `nas`-tagged snapshot age is compared
  against the same threshold the local repos use.

### 1.8 lldap's restic mount is a **hard** NFS mount
`gitops/workloads/lldap/backup-cronjob.yaml:151-154`

```yaml
- name: restic-repo
  nfs:
    server: 192.168.1.160
    path: /mnt/cold-8t/restic
```

An **inline** NFS volume — and inline NFS volumes cannot carry `mountOptions`, which
is a PV-only field. So this mounts with kernel defaults, meaning **hard**: if the H4's
NFS export is unreachable, the pod blocks indefinitely rather than erroring.

That is the 2026-08-02 incident, where `lldap-backup` hung for **3d15h**. It was
*bounded*, not fixed: `activeDeadlineSeconds: 1800` now kills the job after 30
minutes, and `LabBackupJobFailed` pages when it does. So the harm — a backup silently
stalled for days — is handled. The stall itself is not.

**How this was found, and a correction.** An untracked
`gitops/workloads/lldap/restic-pv.yaml` was spotted on the H4 on 08-08 and recorded
here as a live PV that urgently needed committing. It was not: `kubectl get pv
lldap-restic` returns NotFound. It was an **unapplied draft** — someone's half-finished
attempt to move this volume to a PV precisely so it could carry
`soft,timeo=100,retrans=3`. The file has since vanished from the working tree.

I asserted it was load-bearing from reading its contents without checking whether the
object existed. The same mistake, in miniature, as trusting a green timer.

**If the stall is worth fixing:** a PV plus a matching PVC, and switch the CronJob's
volume from inline `nfs:` to `persistentVolumeClaim:`. Soft mounting turns a 30-minute
hang into a ~30-second failure. Weigh that against changing a backup path that has run
reliably since the deadline was added — the deadline already converts an indefinite
hang into a bounded, alerted failure, which was the actual damage.

### 1.9 The offsite seed starved `backup-nas` for four nights — **fix pending**

`backup-nas` failed outright on **08, 09, 10 and 11 Aug**. Not the copy step — the
whole unit. Four consecutive nights with no new backup of `/srv/nas`,
`/mnt/cold-8t/VMs` or `/mnt/cold-8t/immich` to *any* repo. Recovered by hand
2026-08-11 03:46.

    unable to create lock in backend: repository is already locked by PID 1693818

PID 1693818 was the offsite seed. `restic -r <primary> copy --repo2 <offsite>` holds
a lock on the **source** repo for the whole operation — three days — so the nightly
`restic backup` could not acquire its own lock and the unit failed. Nightly
incrementals take ~10s, so this only bites on multi-day work. It bit for four days.

The seed was designed with `TimeoutStartSec=infinity` because it was expected to be
slow. What was not considered is that a long operation against the primary starves
the nightly job it exists to protect.

**Sourcing bulk copies from `cold-sec` was proposed and then rejected — checked
2026-08-11:**

    /mnt/cold-8t/restic   chunker_polynomial 30f6553d487a79
    R2 homelab-nas        chunker_polynomial 30f6553d487a79
    /mnt/cold-sec/restic  chunker_polynomial 2d710aa7618093   <- different

`backup-nas-copy.sh:72-77` initialised the secondary *plainly*, without
`--copy-chunker-params`, and says so. So copying `cold-sec → offsite` would re-chunk
all 204 GiB: no dedup against what is already there, a full re-upload, and an offsite
repo carrying two chunkings of the same data. Do not do it.

**Fix applied instead: bound the runtime.** `TimeoutStartSec` was `infinity` for the
seed; it is now `4h`. A nightly incremental takes ~10s, so that is enormous headroom,
and it ends at 06:30 — clear of the next `backup-nas` at 01:30. An unbounded copy can
starve the nightly job silently for days; a bounded one fails, and a failed unit skips
`hc-ping` and trips `LabBackupUnitFailed`.

**Procedure for any future re-seed:** raise the timeout deliberately *and* stop
`backup-nas.timer` for the duration, then re-enable it. The nightly being paused
knowingly is very different from it failing unnoticed.

- [ ] **Optional, later: re-init `cold-sec` with `--copy-chunker-params`** to match
      the primary. It would align all three repos, improve dedup between primary and
      secondary (currently "imperfect" by that script's own admission), and make
      `cold-sec` a legitimate source for future bulk work. Cost is rebuilding the
      secondary from scratch — local disk-to-disk, so hours rather than days, but it
      temporarily reduces you to one local copy plus offsite. **Do not attempt this
      before a restore has actually been tested (§1.1).** Rebuilding redundancy you
      have never verified you can restore from is the wrong order.

**The alerting worked.** Both paths fired and reached the phone: healthchecks.io went
down (hc-ping is `ExecStartPost`, skipped on failure, Period 25h / Grace 1h) and
`LabBackupUnitFailed` fired on `node_systemd_unit_state{state="failed"}`. Investigation
was deliberately deferred until the seed completed rather than interrupting it.

That is the first real-world validation of the 08-07 alerting work — a genuine
multi-night backup outage, detected, delivered, and acted on. Worth recording against
the three failures that preceded it, none of which anyone noticed for days.

### 1.4 `storage.yml` can `mkfs` a cold mirror by unstable device name
`docs/REVIEW-2026-07-24.md:291` (H15)

The cold disks are the copy-of-record. Device-name-based formatting is how a reboot
that reorders `/dev/sdX` destroys them.

### 1.5 Nothing ever trims the cold-sec copy repo
`docs/REVIEW-2026-07-24.md` (M-new-1) — *possibly fixed 07-25 via `backup-nas-copy.sh`
retention; verify against the live repo rather than the doc.*

### 1.6 R2 retention has never deleted a snapshot and cannot
`docs/REVIEW-2026-07-24.md` (M-new-4) — `TMPDIR` in `SOURCES` means the staging path
varies per run, so `--group-by` never matches an existing series. Every cloud snapshot
is kept forever, and the 10 GB free tier is the ceiling.

### 1.7 Hold restic at 0.12.x
`docs/BACKUP-RESTORE.md:360-372` (M-new-2), `ansible/templates/backup-nas-copy.sh.j2:9-19`

Upgrading past 0.14 reverses `copy` argument semantics. The version guard catches it,
but an unattended `apt upgrade` crossing that boundary is a real path to overwriting
the primary from the secondary. Pin it.

---

## 2. Security

### 2.1 Pi-hole admin UI deploys unauthenticated — **verified**
`ansible/playbooks/dns.yml:12`, `ansible/templates/pihole.toml.j2:21` (H16)

```
pihole_web_password_hash: ""     # double-sha256; source from Vault, NOT plaintext here
password = "{{ pihole_web_password_hash | default('') }}"
```

Those are the only two occurrences in the entire repo — the variable is set to empty
and never overridden, so it always renders empty. The template's own comment says
empty = no auth. This is the lab's load-bearing resolver.

### 2.2 GitLab runner mounts the host Docker socket read-write
`gitops/workloads/gitlab-runner/values.yaml:40-45` (C5)

CI job pods get `/var/run/docker.sock` with `read_only: false` — that is node root for
anything that can open a merge request. Also no CPU/memory limits on build pods.

### 2.3 Plaintext credential in git
`ansible/playbooks/provision-gitlab-vm.yml:95-96`

A SHA-512 crypt hash with a hardcoded salt, and the line beneath it **states the
plaintext password**. Every VM built from this playbook ships with a known password,
`lock_passwd: false`, and `NOPASSWD:ALL`.

### 2.4 ~~`ldap.yml` silently falls back to a literal password~~ — **RESOLVED 08-09**
The playbook was deleted rather than fixed; see §9. It preseeded slapd and bound with
`CHANGEME-set-via-vault` whenever the vaulted variable was out of scope, while its own
header said "never hardcode it". It had also been dead since 2026-07-18.

### 2.5 Vault unseal keys sit beside the sealed data
`ansible/templates/vault-unseal.sh.j2:6`, `TODO-2026-08-03.md:871-876`

`docs/SECURITY.md:25` describes them as "Offline, physically secure". They are on the
RPi5 at `0400`, next to the raft store they unseal. Either fix the storage or fix the
claim — as written the document is load-bearing and false.

### 2.6 Vault runs plaintext HTTP
`ansible/templates/vault.hcl.j2:8-9`, `README.md:167`, `docs/OVERVIEW.md:72`

Fine on a trusted LAN, flagged in three places as "before exposing beyond LAN".
Worth deciding whether that day is ever coming.

### 2.7 Committed argon2id hashes for five OIDC client secrets
`gitops/workloads/authelia/configmap.yaml:72,86,98,111,125`

Offline-crackable, and the only credential for those clients.

### 2.8 Optional: tighten `admin` so it cannot self-escalate
`ansible/files/vault-policies/admin.hcl`, `TODO-2026-08-03.md:310`

`admin` holds `create` plus `sudo` on `sys/policies/acl/*` and `auth/*`, so a token
carrying it can write a policy granting anything and mint a token for it — root at
will, no key ceremony. Deliberate (it is what lets it run `vault auth enable
kubernetes`) and accepted on 08-07. Recorded so "no standing root token" is not
mistaken for "no root-equivalent access".

If the trade stops being acceptable: scope `sys/policies/acl/*` to read/list, drop
`sudo` on `auth/*`, and do rare privileged operations through a generate-root ceremony.

### 2.9 No host firewall anywhere
`docs/REVIEW-2026-07-24.md` (Medium)

### 2.10 `.claude/settings.json` is a MicroShift-era artifact
`docs/REVIEW-2026-07-24.md:310` (H30)

`kubectl` appears three times, all in `allow` — every mutation unguarded. Denies
`systemctl stop nfs-server` while Ubuntu's unit is `nfs-kernel-server`, and no
`sudo`-prefixed variants of any deny rule.

---

## 3. Monitoring that cannot fire

*The theme of the 08-07 session. These are the remaining instances.*

### 3.1 ~~`scripts/verify-lab.py` suppresses metrics that now work~~ — **FIXED 08-07**
`KNOWN_ABSENT` emptied. Both entries were wrong: one carried a diagnosis retracted on
08-02, the other named a metric that does not exist. Original finding below for
context.

`scripts/verify-lab.py:51-59`

`KNOWN_ABSENT` still excuses `node_systemd_unit_state` on the grounds that the
collector "cannot read `/run/systemd/private`" — a diagnosis that
`gitops/workloads/monitoring/lab-alerts.yaml:17-32` records as **wrong and fixed on
2026-08-02**. The script's own comment says `an entry is an admission that an alert
cannot fire`. It is now suppressing a working metric. One of the two key names is also
the non-existent `..._last_trigger_time_seconds`.

### 3.2 No etcd metrics, therefore no quorum-loss alerting
`docs/REVIEW-2026-07-24.md:306` (H26) — `kubeEtcd: enabled: false` on a 3-node HA cluster.

### 3.3 Nothing verifies that DNS actually resolves
`docs/REVIEW-2026-07-24.md:306` (H29) — no blackbox exporter, so
`api.lab.home.arpa` and `*.apps.lab.home.arpa` failing to resolve is invisible.
DNS is the lab's most load-bearing dependency.

### 3.4 `LabBackupEtcdSilent` may fire permanently against a weekly timer
`docs/REVIEW-2026-07-24.md:306` (H27) — *possibly fixed; verify the timer cadence
against the 25h threshold.*

### 3.5 A CronJob that has never succeeded is invisible
`gitops/workloads/monitoring/lab-alerts.yaml:262-269` — `LabCronJobStale` keys off
`kube_cronjob_status_last_successful_time`, which does not exist until the first success.

### 3.6 `.github/workflows/sync-check.yml` performs no sync check
`:17-30` — named `Post-merge notice`, does nothing but `echo`, because hosted runners
cannot reach the LAN.

### 3.7 Alloy restart recency filter
`TODO-2026-08-03.md:335` — benign historical restarts keep surfacing.

---

## 4. Broken or blocked, live

### 4.1 CI depends on an image with no build definition — **verified**
`.gitlab-ci.yml:22-24`

```
# Lab registry image — built from Dockerfile in tools/homelab-ci/ (has kubectl, argocd, yq, curl).
# Falls back to bitnami/kubectl until the lab image is published.
image: registry.apps.lab.home.arpa/tools/homelab-ci:latest
```

`tools/` contains only `sdcard/`, and `find . -name 'Dockerfile*'` returns nothing —
so `tools/homelab-ci/` and its Dockerfile do not exist. The documented fallback is a
comment, not configuration: there is no `image:` fallback anywhere. **Every GitLab CI
job depends on an image that cannot be built from this repo.**

The tag is also `:latest`, which `ci/policies/no-latest-tag.rego` forbids for
workloads — the repo's own policy, applied to workloads but not to its own CI.

Either write the Dockerfile and publish the image, or point `image:` at a pinned
public one (`bitnami/kubectl:<version>` plus the extra tools installed per-job).

### 4.1c `ansible.cfg` only applies if you `cd ansible` first — **verified 08-09**
`ansible/ansible.cfg:21`, `:34` (M-new-7)

Ansible auto-loads `ansible.cfg` from the **current working directory**. Run a playbook
from the repo root with an explicit `-i ansible/inventory/hosts.yml` and the config is
never read — so `vault_password_file` and `pipelining = True` both silently do nothing.

Surfaced on 08-09: `bootstrap.yml --limit n150-1,n150-2` failed with

    "Attempting to decrypt but no vault secrets found"

because `kvm_hosts` carries a vaulted `ansible_become_password`. Every other playbook
run this session was made the same way and succeeded **only because none of them
needed to decrypt anything** — they were running without pipelining too, unnoticed.

Correctness should not depend on which directory you are standing in. Options:

- a repo-root `ansible.cfg` with paths adjusted (`inventory = ansible/inventory/hosts.yml`,
  and the same absolute `vault_password_file`), so both locations work; or
- a `Makefile` target that `cd`s first, and documenting `cd ansible` as the only
  supported way to run playbooks.

The absolute path at `:21` shows this trap was already half-known — the comment at
`:16` explains that a *relative* `vault_password_file` resolves from the playbook
directory. The remaining gap is the config file itself not being found at all.

### 4.2 ~~`zot_admin_password` is undefined~~ — **RESOLVED 08-09 by deletion**

The variable was referenced at `k3s-registry.yml:48` and defined nowhere, so the play
could only fail on an undefined variable — meaning it had never been run. Checking the
live nodes explained why nobody noticed:

    h4-core, opi5pro-2, n150-1, n150-2   registry mirror only, NO auth block
    opi5pro-1                            file absent entirely

The template was *ahead of reality in a risky direction*. It additionally mirrored
`docker.io` and `ghcr.io` through Zot — which runs inside the cluster it serves, so a
cold cluster or a new node would need Zot to start Zot — and added an auth block for a
credential nothing uses. Zot serves the one lab-registry image in production
(`registry.apps.lab.home.arpa/m5stack-adapter:0.1.1`) without authentication.

So the template was reduced to match the deployed file rather than the password being
minted. No rotation, no new secret, and the cold-start dependency never gets
introduced. If Zot as a pull-through cache is wanted later it becomes a deliberate
change with its own rollback story.

**Also fixed, and more dangerous than the password:** the play had no `serial:`, so its
`restart k3s` handler would have restarted all three control-plane servers in parallel
— losing the embedded etcd quorum. Now `serial: 1`. Worth remembering that `make
k3s-registry` was one working variable away from being a cluster outage.

**`opi5pro-1` brought into line 08-09** — file created, its `k3s-agent` restarted,
nothing else touched.

Two further faults the `--check` caught, neither visible from reading the file, both
fixed:

- **The template said `mode: 0600`; the deployed files are `0644`.** Content matched
  on all four configured nodes, so the only diff was the mode — but `copy` notifies
  `restart k3s`, so applying it would have rolled **all five nodes** to tighten
  permissions on a file holding no credentials. Set to `0644` to match. If an `auth:`
  block is ever added, tighten it in that same commit and accept the restart then.

- **The Docker play could not succeed, and would have been harmful if it had.**
  `h4-core` runs `docker-ce 29.7.1`, which depends on `containerd.io`; the task
  installed Ubuntu's `docker.io`, which depends on the conflicting `containerd`. Now
  guarded by a `docker --version` probe. `xu3-1` was dropped from the play entirely:
  Ubuntu 16.04's Python is too old for ansible-core, so every module dies with a
  SyntaxError before task logic runs, and `ignore_unreachable` does not help because
  the host is reachable. It is already excluded from auto-updates — configure it by
  hand or retire it (see §6 on `xu3-1` being EOL since 2021).

### 4.3 `orchestrator_allowlist` is undefined
`ansible/templates/orchestrator.service.j2:14` — falls back to the whole LAN, while
line 2 claims the unit is "fail-closed".

### 4.4 `k3s_version` silently floats
`ansible/playbooks/k3s-h4.yml:16`, `k3s-ha-join.yml:29` — defaults to the `stable`
channel if the pinned var isn't in scope. An unattended run could upgrade the cluster.

### 4.5 `tofu/dns` cannot be applied
`tofu/dns/terraform.tf:6-11` — no Pi-hole v6 provider. The ingress VIP is now
maintained by hand in three places (`main.tf:43`, `hosts.yml`, `verify-lab.py:46`).

### 4.6 `vault-restore.yml` cannot work as written
`docs/REVIEW-2026-07-24.md:295` (H21) — the automated Vault restore path is broken.
Directly compounds §1.1.

### 4.7 PDBs block node drains
`docs/REVIEW-2026-07-24.md:271` (H7) — three PDBs with `minAvailable: 1` against
`replicas: 1`. Any drain hangs forever.

### 4.8 OVMS disabled, crash-looping
`ansible/playbooks/ai-nodes.yml:191-198` — needs `intel-opencl-icd` + level-zero, model
IR conversion, and a valid `config.json` (the deployed one contains `//` comments).

### 4.9 Kyverno `cleanupJobs` block is a confirmed no-op
`gitops/apps/kyverno.yaml:55-66` — creates nothing as of chart 3.3.4.

### 4.10 Kyverno `require-resource-limits` skips initContainers
`docs/REVIEW-2026-07-24.md` (Medium) — live gap at
`gitops/workloads/home-assistant/deployment.yaml:51-53`.

---

## 5. Scheduled / time-bound

| Item | By | Ref |
|---|---|---|
| Renew `token-admin` (720h TTL) | **2026-09-06** | `TODO-2026-08-03.md:248` |
| ESO → Kubernetes auth (token expires) | **~2026-09-08** | `TODO-2026-08-03.md:261` |
| Enable `backup-offsite.timer` after seed | Sunday 08-09 | `TODO-2026-08-03.md:274` |

---

## 6. Documentation drift — statements that are now false

*These matter because they will be read during an incident.*

### 6.1 ~~`CLAUDE.md:49-51` gives the wrong ingress IP~~ — **FIXED 08-07**
Corrected to `.201`, with the source of truth named and an explicit note that finding
`.160` on the wildcard is the fault rather than the fix. Original finding below.

> `*.apps.lab.home.arpa` must resolve to `192.168.1.160` (Traefik ingress)

Three sources disagree with it:

    ansible/inventory/hosts.yml:48   ingress_vip: 192.168.1.201
    ansible/inventory/hosts.yml:40   "Was 192.168.1.160 (the H4) until 2026-07-27"
    scripts/verify-lab.py:46         INGRESS_VIP = "192.168.1.201"

`hosts.yml` is the source of truth applied by `dns.yml`. `CLAUDE.md` is the file that
governs how work is done in this repo, so this line will mislead during exactly the
incident where it matters — someone "fixing" DNS back to `.160` would undo the change
that stopped a single A record taking down every service URL in the lab.

### 6.2 Offsite backup claimed DONE in three places
`README.md:186`, `docs/services.md:119`, `docs/STANDUP.md:183-185` —
all written while `backup-offsite` had never copied a byte. Now nearly true; will be
true when the timer is enabled.

### 6.3 Vault root token documented as a required credential
`docs/WORKFLOWS.md:118-128`, `docs/SECURITY.md:26`, `docs/BACKUP-RESTORE.md:100` —
as of 08-07 there is deliberately no standing root token. Three files describe a
credential that must not exist.

### 6.4 `CLAUDE.md:69` — "DNS needs a permanent host"
Contradicted by four documented permanent DNS servers in `docs/ARCHITECTURE.md:136-143`.

### 6.5 `CLAUDE.md:71` — "The map's plaintext credentials must be rotated"
`docs/HARDWARE.md:6-8` says rotation is done.

### 6.6 `docs/ARCHITECTURE.md:176` — "Bookworm flash pending"
Flashed 2026-07-13; the same file says so at `:140`. Self-contradictory.

### 6.7 `docs/BACKUP-RESTORE.md:360-372` — two stale rows
`backup-offsite is a no-op` (fixed) and `No alert reaches a human` (ntfy wired 08-07).

### 6.8 `docs/UPDATES.md:325` — Authelia→PostgreSQL listed as a gap
Completed 2026-07-03.

### 6.9 ~~Two files end mid-sentence~~ — **HARDWARE.md fixed 08-09**
`docs/HARDWARE.md` ended mid-word at `— investigate(2`. That truncated line was the
Authelia `Progressing` item, which had been resolved in a later session — so a
half-written sentence kept a closed issue alive across two audits.

`docs/services.md:121` still ends at `Improvement need`. Content is missing; recover
or delete it.

### 6.10 rknpu target version disagrees
0.9.7 everywhere except `gitops/workloads/immich/README.md:50`, which requires ≥ 0.9.8.
Resolve before doing the upgrade.

### 6.11 `docs/SECURITY.md:38-39` claims a scoped kubeconfig
Not implemented (H12). `:52-54` describes `kubectl` permission tiers that don't exist
in `.claude/settings.json` (D8/H30).

### 6.12 An "unresolved H4 CRC fault" appears only in `docs/STANDUP.md:213-215`
Called the critical path, referenced nowhere else. Either resolved and undocumented,
or a lost thread.

---

## 7. Repo hygiene

- **`FETCH_HEAD` is tracked in git** — a git internal committed by accident.
- **Duplicated, drifted CI config under `ansible/`** — `ansible/.gitlab-ci.yml`,
  `ansible/.github/workflows/*`, `ansible/.claude/settings.json`. Only the root copies
  are read; these are dead weight diverging silently.
- **Mixed ArgoCD `repoURL` schemes** — 12 files use `git@github.com:`, but
  `gitops/apps/gitlab-runner.yaml:18,22` uses `https://`. Argo treats these as two
  repos needing two credentials.
- **`.gitignore` path bug in `ansible/`** (C7) — and note this working copy lives in
  `Downloads`, so `LAB-URLS.md` and similar travel with any zip or sync of the folder.
- **Archive `TODO-2026-07-14.md`** (25/26 done) and collapse `README.md`'s TODO to a
  pointer at this file.

---

## 8. Deferred by choice — no action wanted

Recorded so they stop resurfacing as findings.

Remote access (WireGuard/Tailscale) · UPS + NUT · OpenTelemetry · Vector DB / Qdrant
RAG · Vault OIDC auth · OVMS until a concrete iGPU use case · rknpu 0.9.7 until a 3B+
model is worth running · Home Assistant and LiteLLM SSO (not worth the complexity) ·
Zot OIDC (blocked on upstream provider naming) · Windows Update automation ·
`externalTrafficPolicy: Local` on the Traefik VIP until Traefik runs 2+ replicas.

---

## 9. Small, live, cheap

- `lldap-backup` init container failed once and self-healed; a retry loop around
  `pg_dump` would make it deterministic (`TODO-2026-08-03.md:447-452`).
- [x] **Re-sweep Ansible for `no_log` registers consumed later** — done 08-09.
  All 12 files carrying `no_log` were checked. Results, so this need not be redone:

      backup-cloud.yml      OK — check_mode: false on both Vault reads
      backup-offsite.yml    OK — check_mode: false on the Vault read
      healthchecks.yml      FIXED 08-07 — this was the original case
      vault-policies.yml    OK — reads deliberately not no_log
      k3s-agent.yml         OK — uses slurp, which supports check mode and runs
      k3s-ha-join.yml       OK — same
      rotate-passwords.yml  OK — consumer guards `is defined` with a fallback
      sync-secrets-to-vault OK — the set_fact guards `is not skipped and ... is defined`
      k8s-secrets.yml       OK — no register -> consumer chain
      sandbox-vm-update.yml OK — already carries check_mode: false on its probe
      github-runner.yml     OK — no_log task has no consumed register
      ldap.yml              **FINDING, below**

  Two useful generalisations. `slurp` supports check mode, so it runs and populates
  its register — only `command`/`shell` skip. And the defensive shape is a guarded
  consumer (`when: x is defined`, or `| default(...)`), not just `check_mode: false`
  on the producer; `rotate-passwords.yml` and `sync-secrets-to-vault.yml` are the
  models to copy.

- [x] **`ldap.yml` deleted 08-09** — not fixed, removed. It targeted `hosts: ldap`,
  a group deleted from the inventory on 2026-07-18 when `ldap-1` was decommissioned
  and lldap moved to k3s, so it matched no hosts and could only no-op. But
  `Makefile:54` still offered a `make ldap` target, and `site.yml:14` described it as
  "lldap VM provisioning" — which it never was; it installed OpenLDAP/slapd.

  Deleting resolved three items at once: the `--check` bug below, the
  `CHANGEME-set-via-vault` fallback (§2.4), and the dead playbook itself. Makefile
  target and site.yml comment removed with it.

  The original finding, kept because the shape is worth recognising:
  The task is `command` + `no_log`, with both conditionals reading the register:

      register: ldapadd
      changed_when: "'adding new entry' in ldapadd.stdout"
      failed_when: ldapadd.rc not in [0, 68]
      no_log: true

  Under `--check` the command skips, so `.stdout` and `.rc` do not exist, both
  expressions fail on undefined, and `no_log` censors the reason — the identical
  signature to the `healthchecks.yml` bug. It is a *write* (`ldapadd`), so the fix is
  not `check_mode: false` but defaults: `ldapadd.stdout | default('')` and
  `ldapadd.rc | default(0)`.

  **But first ask whether it should exist.** This playbook installs `slapd`, and
  lldap replaced it as a k3s Deployment when `ldap-1` was decommissioned on
  2026-07-04. If nothing targets it, deleting is better than fixing — a broken
  playbook nobody runs is harmless right up until someone runs it. Note also
  `ldap.yml:9` silently falls back to the literal `CHANGEME-set-via-vault` (§2.4),
  which is a second reason to remove rather than repair.
- Confirm each healthchecks.io check's Period/Grace matches
  `ansible/playbooks/healthchecks.yml` — set by hand in the UI, nothing enforces it.
- Delete `/etc/vault.d/vault.hcl.unused` on the H4.
- Rotate sudo passwords on `n150-1`/`n150-2` (exposed 2026-07-18) — `rotate-passwords.yml`.
- Pin the Ollama image and give Whisper a versioned tag (Kyverno `disallow-latest-tag`).
- ~~Investigate Authelia health stuck `Progressing` in ArgoCD~~ — **DONE.** Resolved in
  an earlier session; the leftover PVC has also been removed. The entry survived only
  because it was carried in `README.md` and `docs/HARDWARE.md`, neither of which was
  updated. Exactly the drift §6 exists to catch.
- ~~`bootstrap.yml` needs `-K` for `n150-1`/`n150-2`~~ — **DONE 08-09.** Both now have
  passwordless sudo via `/etc/sudoers.d/ansible-swares`, applied by `bootstrap.yml`
  rather than by hand.

  Worth recording *how* this closed. The `--check` run did not confirm agreement — it
  found that the drop-in did not exist on either host, so the working passwordless
  sudo came from an uncodified edit elsewhere. Live and git both worked, and differed.
  The hand edit was removed and `bootstrap.yml` applied, so there is now one source of
  the grant instead of two. Running `--check` before the real run is what surfaced it;
  applying blind would have left both in place, which is how a grant becomes
  impossible to revoke.
- [ ] **Decide whether the control node's RSA key should still be pushed.**
  `bootstrap.yml` finds both `~/.ssh/id_ed25519.pub` and `~/.ssh/id_rsa.pub` on
  `odroid-nas` and appends whichever is missing — so every bootstrapped host gains an
  `ssh-rsa` (3072-bit) key alongside the ed25519 ones. Both are believed in use as of
  08-09, so this is deferred rather than fixed. Revisit: if the RSA key turns out to
  be a leftover, delete it from the control node rather than un-pushing it from each
  host, and consider ordering the lookup ed25519-first so it stops propagating.
- Confirm `*.apps` wildcard answers only `.201`, not also `.160`.
- `community.general` vs Ansible 2.17.14 version mismatch.
- Mirror `bitnamilegacy/kubectl` into zot before the archive is withdrawn
  (`gitops/apps/kyverno.yaml:43-44`); blocked on §4.2.
