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

Seed is running (~27h in as of 08-09 02:00 UTC, ~1.9 MiB/s). When it lands: enable the
timer, resume the paused healthchecks.io check, and commit the untracked
`gitops/workloads/lldap/restic-pv.yaml`.

**Chunker params verified 08-09** — the one setting that cannot be changed after init:

    /mnt/cold-8t/restic  (4154928a)  chunker_polynomial 30f6553d487a79
    R2 homelab-nas       (d7ac04b8)  chunker_polynomial 30f6553d487a79

Identical, so `--copy-chunker-params` took and dedup between the two repos is
preserved. Had they differed, the remote would be re-chunking everything and the only
fix would be emptying the bucket and re-seeding.

### 1.3b `backup-verify` does not check the offsite repo
`ansible/templates/backup-verify.sh.j2`

It runs `restic check` against the primary, cold-sec and the R2 *cloud* repo
(`homelab-backup`), but not the new `homelab-nas` offsite repo. So the tier that exists
specifically to survive losing the H4 is the one tier with no weekly integrity check.
Add it once the seed completes — the check is meaningless against a half-populated repo.

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

### 2.4 `ldap.yml` silently falls back to a literal password
`ansible/playbooks/ldap.yml:9`

```
ldap_admin_password: "{{ vault_ldap_admin_password | default('CHANGEME-set-via-vault') }}"
```

If the vault var is out of scope it preseeds slapd and binds with that string — while
the file's own header says "never hardcode it".

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

### 4.2 `zot_admin_password` is undefined
`ansible/playbooks/k3s-registry.yml:48`, `TODO-2026-08-03.md:227-229` — referenced,
defined nowhere. Blocks giving `opi5pro-1` registry credentials.

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
- Re-sweep Ansible for `no_log` tasks whose register feeds a later `set_fact` — the
  shape that broke `healthchecks.yml` under `--check` (`TODO-2026-08-03.md:290-292`).
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
