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

### 1.1 ~~No restore has ever been performed~~ — **DRILL 1 PASSED 2026-08-16**

The first restore ever performed in this lab. `immich-2026-08-15.sql.gz` (16,662,251 B)
pulled from snapshot `23056e8d` in the R2 `homelab-nas` repo, onto a throwaway VM on
n150-2 with no lab config, using **only envelope items 2 and 3**. Byte-identical to the
H4 original (`sha256 e03bea7d…3d4c`). **9m23s** end to end, of which the restore was 3s.
Full record and criteria in `docs/BREAK-GLASS.md` → Results.

**The backup chain is no longer a belief.** Three repos, retention, verification,
alerting and an offsite tier — one leg of which has now demonstrably restored something.

Written after Drill 1, when only items 2 and 3 had been used:

- ~~**Envelope items 1, 4, 5 and 6 are untested.**~~ **All now tested.** Item 1 by Drill 2a
  (08-17), item 5 by Drill 2b (08-17), item 4 by Drill 2c (08-19), item 6 by every playbook
  run against encrypted `group_vars`. The blocker named here — §4.6, `vault-restore.yml` —
  was resolved by deleting the playbook rather than fixing it; Vault restore is now a
  verified manual procedure in `docs/BACKUP-RESTORE.md` §3.4.
- **The timing does not extrapolate.** 3 seconds moved 15.9 MiB. Real content is ~250 MiB
  today and ~1.5 TB once Immich is populated (§1.10). Still true.
- **§1.9's `cold-sec` re-init is now unblocked** — it was gated on this.

*Original entry below, retained for the reasoning.*

---

#### Original finding
*(Drill procedure in `docs/BREAK-GLASS.md`, **planned in full and corrected 2026-08-15**.
Bounded, read-only, from the offsite R2 repo onto `n150-2`, using only the envelope.
R2 charges no egress, so it costs time and nothing else.)*

**The procedure had a defect that would have produced a false pass.** It restored
`--include /srv/nas/<a known file>`, and `/srv/nas` is empty — §1.10 established that on
08-13. The drill would have restored zero bytes, exited 0, and been written into the
results table as a success. Precisely the shape of the `backup-offsite` bug: a check
that cannot fail is not a check. The procedure now targets
`/mnt/cold-8t/immich/backups/*.sql.gz`, the only real content in the repo, and the first
pass criterion asserts a non-zero file size.

Planning decisions recorded so the drill is repeatable:

- **Host: a throwaway VM on n150-2**, via the existing `create-vm.yml`
  (`-e vm_name=drill-1 vm_ram_mb=2048 vm_vcpus=2 vm_disk_gb=20`), destroyed afterwards.
  Clean room, repeatable, and — the real reason — credential hygiene: the envelope's R2
  keys are read-write and reach the only offsite copy, and on a permanent node they
  survive in shell history and environment alongside a plaintext Postgres dump in `/tmp`.
  Destroying the VM removes all of it. Not n150-1: monitoring stack. Not the RPi5: it is
  the Vault half of the loop the envelope exists to break.
- **Optional but valuable: run it on the `sandbox-nat` network** from
  `sandbox-vm-update.yml` — "internet via NAT, invisible to LAN". The VM reaches R2 but
  cannot reach the H4 or Vault, so "use only the envelope" becomes a network property
  rather than a discipline. `create-vm.yml` defaults to `br0`, so this needs an override,
  and the network's persistence outside that playbook is unverified — check
  `virsh net-list --all` first.
- **Scope: envelope items 2 and 3 only.** Items 1, 4, 5 and 6 are Drill 2. A Drill 1 pass
  must not be recorded as "envelope verified".
- **Window: avoid 02:25–02:40 UTC**, when `backup-offsite.timer` fires. §1.9 is the lesson.
- **Forbidden from the drill host:** `forget`, `prune`, `init`, `migrate`, `copy`,
  `unlock`. The envelope's R2 credentials are read-write and reach the only offsite copy.
- **§1.2 first.** Three currency rows are unticked and the restic password rotated 08-07.
  A drill using credentials read off the H4 tests nothing.

`docs/BACKUP-RESTORE.md:354-372`, `docs/REVIEW-2026-07-24.md:124-144` (C2)

> `| — | *no restore has ever been tested* | — | — | See §5 |`

The backup chain is now genuinely good: three repos, retention, verification, alerting,
offsite seeding. **None of it has ever been proven to restore anything.** The drill
table has an empty first row. This is the single largest risk in the lab and the one
item that makes every other backup improvement conditional.

Do: one restic restore and one etcd restore into scratch, timed, recorded in the table.

### 1.2 ~~The offline break-glass envelope does not exist~~ — **PRINTED AND IN USE 2026-08-17**

It exists. Printed 08-17 carrying the five post-rekey unseal shares, the five superseded
shares as item 5b (destroy after 2026-11-16), and current values for items 1–4 and 6. All
five currency rows in `docs/BREAK-GLASS.md` are ticked.

**All six items are proven** rather than assumed, which is the part that took the drills:
items 2 and 3 opened the R2 repo from a machine with nothing else on it (Drill 1), item 1
opened the local repo (Drill 2a), item 5 unsealed a Vault barrier restored from a snapshot
onto a machine that had never seen this Vault (Drill 2b), and item 4 rebuilt the cluster's
entire datastore from a 38 MB etcd snapshot (Drill 2c, 2026-08-19). Item 6 is exercised by
every playbook run against encrypted `group_vars`.

On 2026-08-15 no restore had ever been performed in this lab. Four days later every
credential in the envelope has been used to recover something.

Drill 2b also produced a three-way agreement worth recording: `secret/lab/restic` inside
the restored snapshot hashes identically to `/etc/restic/password` on the H4 and to the
value on the printed page.

*(This paragraph read "three of the six" until 2026-08-17. It was written before Drill 2b
ran and merged after — git had no conflict to report, because nothing textually collided.
A merge that succeeds is not a merge that is still true.)*

The loop this closes, in the document's own words: the runbook says to get the restic
password from Vault; Vault runs on the RPi5; Vault's snapshots live on the H4. Lose the H4
and you need restic to recover and Vault to get restic's password. That loop is now broken
by something outside both systems.

Remaining, and it is manual: confirm the post-print cleanup ran — drafts shredded, printer
power-cycled, keeper copy **off the property**. `scripts/print-offline-envelope.sh` handles
the machine side and prints the rest as instructions because it cannot shred paper.

*Original entry below.*

---

#### Original finding
`docs/BREAK-GLASS.md` (template added 08-11), `docs/BACKUP-RESTORE.md:91-111`

**Plan agreed 08-11: assemble it, store it offline, then test a restore using only
its contents.** That ordering matters — a drill run on a host that still has the
repos, the config and the credentials proves almost nothing, and it is the drill
that tells you whether the envelope is actually complete.

#### Sequenced 2026-08-15 — split into two tracks

The envelope does not have to be complete before Drill 1 starts. Drill 1 uses **items 2
and 3 only** (R2 restic password; R2 account ID and API keys), neither of which touches
Vault. Blocking the first restore this lab has ever performed on a Vault rekey would be
the wrong order.

1. ~~**Fill items 2 and 3 → run Drill 1**~~ — **DONE 2026-08-16, passed.** Items 2 and 3
   are proven: they opened the offsite repo from a machine with nothing else on it. See
   §1.1.
2. ~~**Rekey Vault**~~ — **DONE 2026-08-16.** Five new shares, all five written to
   `/etc/vault.d/unseal-keys`, verified by `systemctl restart vault` → sealed →
   `vault-unseal` → unsealed. Pre-rekey snapshot `vault-snap-20260816-155152` kept as the
   undo point; post-rekey `vault-snap-20260816-181204` taken immediately so the new shares
   have something to open. Needed a new `rekey` policy and a short-lived token — see
   §1.11 — `generate-root` is authenticated since Vault 2.0.0 and needs a config change
   first, which is why a policy was the faster route here.
3. **Decide the break-glass auth method (§1.11) *before* printing** ← *next*. Without it
   the envelope unseals Vault and cannot administer it. Printing twice means two full
   credential dumps through the CUPS spool, so settle this first.
4. **Fill and print the full envelope**: five new shares, the break-glass credential, and
   the five *old* shares labelled *"valid only for Vault snapshots taken before
   2026-08-16 — destroy after 2026-11-16"*. Pre-rekey snapshots persist for 30 days
   locally and ~3 months in R2 (`--keep-monthly 3`), and only the old shares open them.
5. **Delete the plaintext copy of the old shares** once they are in the envelope.
6. **Drill 2.**

#### The unseal-share question is resolved — by rekeying, not by searching

The earlier note asked where shares 4 and 5 were before filling item 5 in. They were in a
plaintext file on a laptop. **`vault operator rekey` invalidates every existing share at
once**, which is strictly better than deleting that file: `rm`/`shred` do not reliably
erase flash storage, so you cannot prove the old copy is gone — but you can make it
worthless. After a rekey the only shares in existence are the ones just written down.

Decisions taken, so they are not re-litigated:

- **All five shares go in `/etc/vault.d/unseal-keys`**, and all five get printed in the
  envelope. Three is already the threshold and the RPi5 already equals full Vault access,
  so the extra two change nothing — they are inert, since `vault-unseal.sh` reads the
  first `vault_unseal_threshold` valid lines and stops. Five in the envelope buys
  tolerance for a mistranscribed character.
- **Auto-unseal is kept.** Under Shamir, auto-unseal and "no single location can unseal"
  are mutually exclusive: the first needs a threshold of shares on the host, the second
  needs fewer than a threshold everywhere. Vault gates every ExternalSecret, so the trade
  favours availability. Escaping it entirely means transit or cloud-KMS auto-unseal, which
  is a new dependency — deliberately not taken.
- **Therefore §2.5 is fixed by correcting the claim, not the storage.** Done: see §2.5.

**Trap when hand-editing the unseal file:** no comments, no labels. `vault-unseal.sh`
skips blank lines only; any other non-key line is handed to `vault operator unseal`, fails,
and aborts the unit under `set -euo pipefail`, leaving Vault sealed on boot with nothing to
warn you until the next reboot. Rewrite the file in the same sitting as the rekey and test
it with a deliberate `vault operator seal` rather than waiting for a reboot to find out.

`docs/BREAK-GLASS.md` holds the template, the currency log, and the drill procedure.
It contains no secrets and must not. The filled copy goes offline.

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

### 1.3 ~~Finish the offsite tier~~ — **DONE, verified running 08-15**
`TODO-2026-08-03.md:274`, `ansible/playbooks/backup-offsite.yml:59`

**SEED COMPLETE 2026-08-11 02:19 UTC.** ~3.1 days wall clock, 44m35s CPU, ~204 GiB.
Retention applied on the first run, keeping 32 snapshots across five groups
(2 nas-old-paths + 11 nas + 8 lldap users.db + 7 lldap /tmp + 4 lldap /dump).
`hc-ping: backup-offsite success OK`.

- [x] **Enable `backup-offsite.timer`** — enabled and active. Confirmed by
      `systemctl` on 08-15, not by reading this file.
- [x] **Add `homelab-nas` to `backup-verify.sh`** — done 08-11 (§1.3b closed).

**Steady state, measured 2026-08-15.** The nightly incremental is cheap and the tier is
behaving:

    NEXT   Sun 2026-08-16 02:30 UTC        LAST  Sat 2026-08-15 02:30:11 UTC
    ran 02:30:11 → 02:31:24                       73 s wall, 9.122 s CPU
    "offsite copy + retention complete — 37 snapshots at destination"
    "hc-ping: backup-offsite success OK"

73 seconds against 3.1 days for the seed, and 37 snapshots against the 32 kept at seed
time — so retention is running and the count is now meaningful (see the `grep -c` bug
below, fixed).

**Note on this entry's own accuracy.** The checkbox above sat unticked for four days
while the timer was enabled and running nightly. On 2026-08-15 that stale checkbox was
read as evidence the timer was off, and the warning below it — that healthchecks.io
would false-alarm ~28h after the seed — was repeated as though it had happened. It had
not: the check has been satisfied every night since 08-11. Nothing was changed, because
`systemctl is-enabled` was run before the playbook. **Check the unit, not this file.**
The same failure mode as §6 and §4.11, on the page that catalogues them.

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

### 1.10 What the backups actually contained — and the window to reset cheaply

Inspecting the newest `nas` snapshot on 2026-08-13, before the first restore drill:

    Total File Count:   35
    Total Size:         224.991 GiB

    /mnt/cold-8t/VMs/YIKW.VHDX          224.7 GiB, unchanged since 2026-06-18
    /mnt/cold-8t/immich/backups/*.sql.gz  ~250 MiB of nightly dumps
    /mnt/cold-8t/immich/{library,upload,thumbs,profile,encoded-video}/.immich
                                          13 bytes each — Immich init markers only
    /srv/nas                              empty

So the "204 GiB of irreplaceable lab data" that framed the offsite work was one
static Windows disk image plus two weeks of database dumps **of an empty photo
library**. `/srv/nas` and the Immich library are both empty by design — Immich was
deliberately not populated until backups were proven stable, which is the right
order and worth saying.

**Corrected 2026-08-17 by Drill 2a: "empty photo library" oversold it.** The library holds
no photos; the database is far from empty. Loading `immich-2026-08-17.sql.gz` into a scratch
Postgres gives `geodata_places` **224,210 rows**, `naturalearth_countries` 4,274, and 68
applied migrations — the 16 MB dump is mostly Immich's reverse-geocoding dataset. It is
reconstructible from upstream, so this does not change the sizing argument above, but
"dumps of an empty library" reads as "dumps of nothing" and they are not. They contain real
data and it restores.

**`/mnt/cold-8t/VMs` removed from `backup-nas` on 08-13.** The VHDX is recreatable
from installation media and does not justify 224 GiB of offsite storage (~$3/month,
and three days of seeding).

- [ ] **Reset the offsite repo while it is cheap.** Existing snapshots still contain
      the VHDX and retention keeps monthlies for 6 months, so it will linger — and be
      billed — until roughly 2027-02. With the VHDX excluded, the real data is
      ~250 MiB: emptying the `homelab-nas` bucket and letting the next run re-seed
      takes minutes instead of days, and the script re-inits with
      `--copy-chunker-params` automatically.

      **The window is now.** Once the Immich library is migrated, a re-seed is
      expensive again. Local repos can keep the VHDX — 224 GiB on an 8 TB mirror
      costs nothing and CLAUDE.md forbids hand-pruning them anyway.

- [ ] **Re-assess sizing once Immich and `/srv/nas` are populated.** `RUNBOOK.md:151`
      plans ~1.5 TB of photo/video. At R2's $0.015/GB-month that is ~$24/month, which
      is a different decision from $3 — and the point at which Backblaze B2 (~$0.006)
      or a rotating external disk deserves a second look.

### 1.11 The envelope does not tell you how to regain Vault admin — **found 08-16, small**
`docs/BREAK-GLASS.md` item 5, `docs/RUNBOOK.md:175-188`

**An earlier version of this entry claimed the envelope could not recover administrative
control of Vault at all. That was wrong, and the repo already said so.** It is recorded
here rather than deleted because the mistake is instructive: the claim was written after
grepping for auth methods and for `token-admin`, but without grepping the docs for
`generate-root` — asserting an absence without checking. The exact failure §6 exists for.

What is true:

`vault operator generate-root -init` returns `403 permission denied`, tested properly with
`VAULT_TOKEN` unset and `~/.vault-token` moved aside. **Vault 2.0.0 made `sys/generate-root`
and `sys/rekey` authenticated by default** — the fix for HCSEC-2026-08 / CVE-2026-5807,
where unauthenticated callers could spam attempt/cancel with bogus fragments and block
legitimate operations.

**But the recovery path exists, is documented, and has been used.**
`docs/RUNBOOK.md:175-188` ("Root token lost (Vault 2.x)") temporarily appends
`enable_unauthenticated_access = ["generate-root"]` to `vault.hcl`, HUPs Vault, runs the
ceremony with three unseal shares, then removes the line. `vault-policies.yml`'s header
records this being performed on **2026-08-05** after the exposed root token was revoked.

So the chain from the envelope is: unseal with item 5 → root shell on the rpi5 → temporary
config → generate-root → full admin. It works. It just needs host root as well as the
envelope, which in a rebuild you would have anyway.

**And it was documented twice.** `TODO-2026-08-03.md:727-814` carries a section titled
*"Why `generate-root` was blocked — and the actual fix"*: the identical 403 with no token,
the `enable_unauthenticated_access` remedy, and at `:760` the full list of families —
**`"rekey"`, `"generate-root"`, `"generate-operation-token"`**. The `rekey` family is
precisely what blocked the 08-16 ceremony for an hour before it was solved a different way.

That is the sharpest argument yet for §7 of `docs/DOC-CONSOLIDATION-PLAN.md`. The knowledge
was not missing; it was in a dated session note that is now frozen and unread. Freezing a
file removes it from the maintenance surface *and* from the places anyone looks. Durable
operational content has to be promoted into the live docs before its source is frozen —
`RUNBOOK.md` got the `generate-root` half, and nothing got the `rekey` half.

The remaining gaps are small but real:

- **The envelope does not mention it.** Item 5 hands you five shares with no pointer to
  `RUNBOOK.md`, so at 2am on paper you would not know the config step exists. Add a
  "Regaining admin access" note to `BREAK-GLASS.md` — the procedure, not a credential.
- **`vault.hcl` is Ansible-managed** (`vault.hcl.j2`). A hand-edit is correct for a
  ceremony but will be reverted by the next `vault.yml` run, and a *forgotten* line would
  be silently removed — which is fine here, but worth knowing rather than discovering.
- **The HUP reload is unverified for this option.** It worked on 08-05, so treat that as
  evidence rather than proof; if it ever does not, restart the service.
- `token-admin` still expires **2026-09-06** (§5). Not fatal given the above, but it is
  the credential everything routine depends on.

Optional, not required: a `break-glass` userpass credential carrying `admin`, password in
the envelope. It removes the config-edit-under-pressure step. Weigh against one more
standing credential that grants full Vault access. **Not** recommended is making
`enable_unauthenticated_access` permanent — Vault here is plaintext HTTP on `0.0.0.0:8200`
(§2.6) with no host firewall (§2.9), so that would leave the DoS vector open permanently
rather than for the length of a ceremony.

Related: §2.11 (cannot seal), §2.12 (version lag), §4.6 (Vault restore, now a verified
manual procedure in `docs/BACKUP-RESTORE.md` §3.4).

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

### 2.5 ~~Vault unseal keys sit beside the sealed data~~ — **claim corrected 08-15; storage kept, deliberately**
`ansible/templates/vault-unseal.sh.j2:6`, `TODO-2026-08-03.md:871-876`

`docs/SECURITY.md` described the shares as "Offline, physically secure". They are on the
RPi5 at `0400`, next to the raft store they unseal, so root there is equivalent to full
Vault access. The entry said: fix the storage or fix the claim.

**The claim is fixed.** `docs/SECURITY.md` now states where the shares actually are, that
the RPi5 is a single point of full access, and why.

**The storage is kept, and that is a decision rather than an omission.** Under Shamir,
auto-unseal and "no single location can unseal" cannot both hold — auto-unseal requires a
threshold of shares on the host. Vault gates every ExternalSecret in the cluster, so a
reboot without auto-unseal leaves every workload's secrets empty until someone
intervenes. Availability wins here. The genuine escape is transit or cloud-KMS auto-unseal,
which adds an external dependency; **not taken**, and recorded in §8 rather than left
looking unconsidered.

All five shares now live in that file rather than three. That changes nothing: three is
the threshold, and `vault-unseal.sh` reads only the first three. See §1.2.

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

### 2.11 Vault cannot be sealed deliberately — **found 08-16, decide**
`ansible/files/vault-policies/admin.hcl`

`vault operator seal` returns `403 permission denied`. `admin.hcl` grants no `sys/seal`
path, and the root token was revoked 08-07, so **no credential in this lab can seal
Vault**. Found while writing the rekey verification step in `docs/OPS.md`, which
originally prescribed exactly that and could never have worked.

"Something is wrong, lock the secrets" is a legitimate break-glass action and is
currently unavailable.

- **Add `path "sys/seal" { capabilities = ["update","sudo"] }` to `admin.hcl`** — simple,
  but it turns a leaked admin token into a denial-of-service against every ExternalSecret
  in the cluster.
- ~~Leave it and use `vault operator generate-root`, which authorises from unseal shares
  rather than a token.~~ **This escape does not exist.** Tested 08-16 with no token and no
  `~/.vault-token`: `generate-root -init` returns 403 as well. See §1.11 — it is the same
  root cause and a much larger problem than sealing.
- **A dedicated policy plus a short-lived token**, as done for `rekey` on 08-16
  (`ansible/files/vault-policies/rekey.hcl`). Least privilege, auditable, and the pattern
  is now proven.

The third option is the one that worked for rekey and is the obvious template here.
Recorded rather than done, because "can seal Vault" deserves a deliberate decision.

Not blocking: rekey verification uses `systemctl restart vault` instead, since Vault
always starts sealed and that needs no token at all.

### 2.13 k3s server token was exposed during Drill 2c — **decide: rotate or accept**
`docs/BREAK-GLASS.md` item 4, `ansible/playbooks/backup-cloud.yml:217`

On 2026-08-19 the k3s server token was passed as `--token='K10…'` on a command line and
the full invocation was pasted into a chat transcript. It is therefore in: that transcript,
the H4's shell history, and the (now destroyed) drill VM's history.

`CLAUDE.md` lists it as never-echo. `docs/BACKUP-RESTORE.md:65` is blunter — snapshot plus
token is total compromise, because the token is the key k3s derives to encrypt CA private
keys inside the datastore.

**Severity: real but bounded.** The token alone grants nothing without either a snapshot or
network access to the cluster. Snapshots live on the H4 and in R2, the latter encrypted
under a different credential.

**If rotating** (`k3s token rotate`, verify syntax first — it requires restarting all five
nodes), it cascades exactly as the Vault rekey did: **snapshots taken before the rotation
need the old token.** Those persist 30 days on `/mnt/cold-8t/k3s-etcd-snapshots` and ~3
months in R2. The envelope would need an **item 4b** — old k3s token, labelled, destroy
after the same window. Same shape and same reasoning as item 5b.

**If accepting**, record that decision here rather than leaving it unstated.

Process note worth keeping: this happened while pasting command output for diagnosis, in a
session that had twice explicitly said not to paste the value. Reading a rule and applying
it under debugging pressure are different things — the durable fix is not typing secrets on
command lines at all, which is why `--token-file` was reached for in the first place. That
it is unsupported on the restore path (§ Drill 2c) is an upstream gap worth knowing.

### 2.12 Vault is seven weeks behind its installed binary — **found 08-16**
`ansible/playbooks/update-non-apt.yml:213-221,248`, `docs/UPDATES.md` §5

Restarting Vault during the 08-16 rekey moved it from **2.0.3 (built 2026-06-17)** to
**2.0.4 (built 2026-08-03)**. The newer package had been installed by the apt tier and the
service had never been restarted into it.

`update-non-apt.yml` starts Vault only when it is *inactive*
(`when: vault_svc.status.ActiveState != "active"`). A running Vault is never restarted, so
the running version drifts behind the installed one indefinitely — on a secrets manager.

**And the play reports the wrong number.** Line 248 prints
`Version: {{ vault_version.stdout }}`, captured from `vault version` — the **CLI binary**,
not the server. It would have reported 2.0.4 while the server ran 2.0.3. Not a missing
check: a check that asserts the opposite of the truth.

Fix: compare the server version (`vault status -format=json`, `.version`) against the
binary (`vault version`) and flag a pending restart when they differ. Report rather than
auto-restart — `vault-unseal.service` makes a restart safe, but it should be a decision.
`docs/UPDATES.md` §5 documents the seal risk *after* a restart and should also cover the
risk of never restarting.

Same family as the CoreDNS ConfigMap in §4.11: the artefact updates, the process does not,
and nothing says so.

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

### 3.8 `PolicyViolation` events fire continuously against dead ReplicaSets

**Found 2026-08-19** in the first Kubernetes Event capture. Kyverno emits a stream of

    policy require-resource-limits/autogen-require-limits fail: validation error:
    Container must specify resources.limits.cpu and resources.limits.memory

against **ten different `m5stack-adapter-*` ReplicaSets** in `ai-gateway`, all within
the same second, repeatedly.

**Nothing is broken.** The live manifest
(`gitops/workloads/ai-gateway/m5stack-adapter/deployment.yaml`) declares
`cpu: 500m` / `memory: 256Mi`. The objects being flagged are the Deployment's
scaled-to-zero revision history from before those limits were added, retained by the
default `revisionHistoryLimit: 10`. The policy runs `background: true`, so every scan
re-evaluates the corpses and re-emits a violation for each.

**The cost is signal, not availability.** In Enforce mode a `PolicyViolation` event
should mean *something was just blocked from starting*. Here it almost always means
*an old ReplicaSet still exists*, so the one event class that indicates an admission
failure is now background hum. That is how a real block gets missed.

**It also falsifies a comment in the policy itself.**
`gitops/workloads/kyverno/policies/require-resource-limits.yaml` states
*"Mode: Enforce — zero violations confirmed in audit baseline."* Whenever that was
true, it is not true now. Same drift class as §6.

**To do:**

- [ ] Decide the fix: exclude ReplicaSets with `spec.replicas: 0` from the policy
      match, or drop `revisionHistoryLimit` on the affected Deployments so the dead
      revisions age out. The first is general; the second is narrower and reversible.
- [ ] Check whether other namespaces carry the same backlog of pre-policy ReplicaSets.
      Only `ai-gateway` appeared in the first capture, but capture is hours old.
- [ ] Correct the "zero violations" comment once the count is actually zero.

### 3.9 ~~Alloy never shipped the journal — four stacked silent failures~~ — **FIXED AND VERIFIED 2026-08-21**

**Found 2026-08-19, root-caused 2026-08-21.** `backup-verify` ran on 2026-08-16 and
wrote eighteen lines to journald on the H4, ending `backup-verify: all checks passed`.
None of them reached Loki. The unit does not exist there at all.

**The cause is two invented value keys.** `gitops/apps/alloy.yaml` carried:

    alloy:
      extraVolumes:      [...]
      extraVolumeMounts: [...]

Neither is a key in the Alloy chart. The real ones are `alloy.mounts.extra` and
`controller.volumes.extra` — different names, and in two different blocks. **Helm
discards unrecognised values without warning**, so no volume was ever created and no
mount ever existed, on any node. Proven directly:

    kubectl -n monitoring exec <alloy-pod> -c alloy -- ls /var/log/journal
    ls: cannot access '/var/log/journal': No such file or directory

`loki.source.journal` had been running against a non-existent path since `cbed946`
("remove Promtail, add journal unit/hostname labels to Alloy") — seven weeks —
reporting healthy the entire time.

**And fixing the mount was not enough.** With `/var/log/journal` correctly mounted and
readable — Alloy runs as uid 0, the files are `root:systemd-journal` 0640, the host
directory plainly present as `/var/log/journal/e4c52d300a65467db8b36a2ca592b8ad` — still
nothing shipped. The container's `/etc/machine-id` was **empty**. sd-journal locates
journals by machine ID, so the reader searched for a journal belonging to no machine,
found zero entries, and returned successfully. Finding nothing is not an error. A second
mount of `/etc/machine-id` (`type: File`) was required, added 2026-08-21.

**And that was still not the last one.** With the mount working and machine-id in place,
the H4 was demonstrably reading — `loki_source_journal_target_lines_total 6800` on its
own `:12345/metrics` — yet Loki showed no `hostname` and no `unit`, only
`{job="node-journal"}`. The tell was `loki_relabel_cache_size 1`: **one distinct label
set across 6800 entries**.

The relabel was chained *downstream* of the journal source. Upstream docs, verbatim:
*"All messages read from the journal include internal labels following the pattern of
`__journal_FIELDNAME` and Alloy drops them before sending to the list of receivers
specified in `forward_to`. To keep these labels, use the `relabel_rules` argument."*
So both rules matched nothing and every journal line from every node landed in one
undifferentiated stream. The field names were correct throughout — only the wiring was
wrong. Fixed 2026-08-21 by passing `relabel_rules = loki.relabel.journal.rules` into
the source and setting the relabel component's `forward_to = []`.

**Four separate silent failures stacked in one config:** a wrong key, a second wrong
key, a missing mount whose absence yields an empty result rather than an error, and a
relabel wired to a stage where its inputs no longer exist. Not one of the four produced
an error, a warning, or an unhealthy component. Each was individually invisible and
each masked the next — every fix looked like it had failed, because the layer beneath
it was broken too.

**This also means the earlier `hostname` label values were never evidence of anything.**
`n150-1`, `n150-2` and the Pis appeared in Loki because *promtail* labels correctly.
Alloy has never contributed a hostname label from any node. The 2-vs-3 "split" that
framed this entire investigation was an artifact of which hosts happened to run a
second, unmanaged log shipper.

**Why two nodes appeared to work.** n150-1 and n150-2 have host logs in Loki because
they are running a **stray promtail systemd service** — `active` and `enabled`,
confirmed 2026-08-21, and targeted by no current playbook.
`ansible/playbooks/promtail.yml` runs against `node_exporter:rpi5`, a group of
`octopi-dns, rpi4b, opi-zero2w-1..4, rpi5` that does not include the N150s — while the
playbook's own header comment claims *"This playbook covers: n150-1/2, octopi-dns,
opi-zero2w-*, rpi4b, rpi5."* Comment and code disagree; the service is a leftover from
when they matched. So host-log coverage in this lab currently depends on an accident,
and `odroid-nas`, `opi5pro-1` and `opi5pro-2` — having neither promtail nor a working
mount — ship nothing.

**Two defects found in the same investigation and fixed 2026-08-20** (they were real,
just not the cause):

- **5x duplicate ingestion.** `discovery.kubernetes` had no node selector, so all five
  DaemonSet pods tailed every pod in the cluster through the API. Fixed with a
  `spec.nodeName` field selector driven by a downward-API `NODE_NAME`.
- **Dropped batches.** A blanket `labelmap` of pod labels produced a 16-label stream,
  over Loki's `max_label_names_per_series` limit of 15; Loki answered 400 and Alloy
  discarded the whole batch. Fixed by removing the labelmap. Confirmed zero across all
  five pods afterwards.

**What makes this entry worth reading twice.** Every layer reported success. Argo:
Synced and Healthy. The pod: 2/2 Running. The Alloy component: healthy. The config in
git: correct-looking, reviewed, merged. The rendered ConfigMap: contained the journal
block. And the mount did not exist. There was no error to find because nothing
considered it an error — Helm treats unknown keys as nothing at all.

**RESOLVED 2026-08-21.** Verified by content, not by status. `backup-verify` was
triggered by hand (read-only) and its output is now queryable in Loki under
`{unit="backup-verify.service"}`:

    ok:   restic check clean — /mnt/cold-8t/restic
    ok:   restic check clean — /mnt/cold-sec/restic
    ok:   restic check clean — R2
    ok:   restic check clean — offsite R2
    ok:   newest R2 snapshot contains the k3s server token
    backup-verify: all checks passed

Journal streams now carry both labels on every node, e.g.
`{hostname="odroid-nas", job="node-journal", unit="k3s.service"}`.

**The four fixes, in the order they had to be made:**

| # | Defect | Fix |
|---|---|---|
| 1 | `alloy.extraVolumes` / `alloy.extraVolumeMounts` — keys the chart does not have; Helm discarded them | `alloy.mounts.extra` + `controller.volumes.extra` |
| 2 | hostPath had no `type`, so a missing path would mount an empty dir silently | `type: Directory` |
| 3 | Container `/etc/machine-id` empty; sd-journal searched for a machine with no journal and returned zero entries | mount `/etc/machine-id`, `type: File` |
| 4 | Relabel chained downstream of the source, which strips `__journal_*` before forwarding | `relabel_rules = loki.relabel.journal.rules`, relabel `forward_to = []` |

**Remaining follow-ups (tracked, not blocking):**

- [x] **Remove the stray promtail from n150-1/n150-2** — done 2026-08-21 via `ansible/playbooks/promtail-remove-cluster.yml`. Verified afterwards by content: `{job="node-journal", hostname="n150-1"}` still returns fresh entries with promtail gone, so Alloy genuinely covers all five nodes. That was the real test — until then those two nodes' journal data came entirely from the stray shipper, masking whether the Alloy fix worked there at all.
- [ ] Consider whether other Helm `valuesObject` blocks in `gitops/apps/` contain invented keys. Sixteen Applications use inline values; nothing in CI would catch it, since yaml-lint, kubeconform and conftest all pass on syntactically valid nonsense. `helm template --validate` against the real chart would.
- [ ] §4.15 covers Alloy's ephemeral `storagePath`, found during this work.

**The lesson worth keeping.** Four independent failures in one config, none of which
produced an error, a warning, or an unhealthy component — and each masked the next, so
every fix appeared to have failed. The diagnostic that finally cut through was a single
counter on the pod's own `:12345/metrics`:

    loki_source_journal_target_lines_total 6800   <- reading fine
    loki_relabel_entries_processed        6800   <- forwarding fine
    loki_relabel_cache_size                  1   <- ONE label set for 6800 entries

That last number is the whole diagnosis. Component-level counters distinguish "did
nothing" from "did the wrong thing"; health status cannot, because a component doing
the wrong thing correctly is healthy.

### 3.10 Fleet hostnames are inconsistent and do not match the Ansible inventory

**Found 2026-08-19** while investigating §3.9. The `hostname` label values Loki holds
use at least four conventions and match the inventory names in almost no case:

| In Loki | In `ansible/inventory/hosts.yml` |
|---|---|
| `RPI-3B-2` | `octopi` |
| `RPI-4B` | `rpi4b` |
| `RPI-5--01` | `rpi5` |
| `opi-zero2w-4` **and** `opizero2w-4` | `opi-zero2w-4` — one host, two names |
| `opizero2w-1` | `opi-zero2w-1` |
| `orangepizero2w` | unidentified — vendor default, never set |

`n150-1` and `n150-2` are the only hosts whose real hostname matches their inventory
name.

**The practical cost is correlation.** Joining a journal line to a host requires a
mental lookup table that exists nowhere. `opi-zero2w-4` and `opizero2w-4` both persist
in Loki's index because the host was renamed at some point and both labels still have
chunks in retention — so one machine reads as two. `orangepizero2w` cannot be
attributed to a host at all without going and looking.

This lands directly on `docs/LEDGER-DESIGN.md` §4, which proposes joining sources on
extracted identifiers. Hostname is the obvious key for tying a journal line to a node
event and **is not usable as one in this lab** without a mapping. Either fix the
hostnames (§4.14) or carry an explicit alias table in the ledger schema.

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

### 4.6 ~~`vault-restore.yml` cannot work as written~~ — **DELETED 2026-08-19, not rewritten**

**Resolution: the playbook is gone and Vault restore is now a verified manual procedure**
in `docs/BACKUP-RESTORE.md` §3.4, matching how etcd restore has always been handled in
§3.2. One document, two restores, same shape, both drilled.

**Why deletion rather than a rewrite**, which is what this entry expected as recently as
08-17:

- Drill 2c (08-19) restored the **entire cluster datastore** with no playbook at all,
  following §3.2. The harder of the two restores has never needed automation and is the
  better-tested of the pair.
- The automatable part of both is three commands — install at the right version, fetch the
  newest snapshot, run one restore. Everything that actually goes wrong is judgement:
  *which* snapshot, *is this host isolated from production*, *is the version right* —
  followed by a key ceremony that has to be human.
- `vault-restore.yml` was broken from at least 2026-07-24 (H21) and nobody noticed **because
  nobody ran it**. A rewrite rots the same way. The only thing that would keep it honest is
  drilling it, and drilling it means running it by hand.
- Drill 2b took **11m40s** by hand. Automation would have saved minutes on an operation
  performed roughly never, while adding something that silently goes wrong between uses.

§3.4 carries the four findings from 2b — `-force`, the mandatory restart before the seal
config is readable, newest `vault-snap-*.snap` from the H4 rather than a dated tarball, and
Vault installed at or above the snapshot's version — plus the isolation warning that
Drill 2c turned from theory into an observed fact.

References updated: `docs/TROUBLESHOOTING.md` rpi5 recovery now points at §3.4, and
`docs/BACKUP-RESTORE.md` §5 records H21 closed.

*Original entry below.*

---

#### Original finding — `vault-restore.yml` cannot work as written
`docs/REVIEW-2026-07-24.md:296` (H21), `ansible/playbooks/vault-restore.yml:26,65-68`

H21 records a hard-coded dated tarball (`vault-backup-20260627.tar.gz`) in
`/mnt/cold-8t/backups/`, a directory nothing maintains, plus a controller-side `src` for
a file that lives on the H4.

**It is worse than mis-pathed.** The play stops Vault, wipes `/opt/vault/data` and unpacks
a tarball — a file-level restore. The live backups are raft **snapshots**
(`vault-snap-*.snap`, `/mnt/cold-8t/vault-snapshots/`, 30-day retention) which restore
through the API with `vault operator raft snapshot restore`. The method does not match the
artefact the backups produce, so this is a rewrite rather than a path fix.

**Sequence deliberately inverted 2026-08-16: do the manual drill first.** Rewriting from
the review note would replace one unverified procedure with another and leave no way to
know the replacement works either.

**Drill 2b ran 2026-08-17 and the evidence now exists** (`docs/BREAK-GLASS.md` → Results).
The rewrite has four things the old play does not:

1. `vault operator raft snapshot restore -force <snap>` against a running, unsealed Vault
   — **not** stop-wipe-untar.
2. **A Vault restart after the restore.** Until then `vault status` still reports the
   pre-restore seal config, and unsealing against the wrong threshold fails confusingly.
   Nothing in the current play does this, and no doc mentioned it before 2b.
3. Newest `vault-snap-*.snap` from `/mnt/cold-8t/vault-snapshots/` on the H4, not a
   hard-coded dated tarball, and not a controller-side `src`.
4. Vault installed at or above the version that wrote the snapshot.

The share ceremony stays human: the play should stop at "restored, restart done, now
unseal" rather than handling shares. Note the drill took 11m40s by hand, so automation
buys little here beyond removing the chance to mistype a path.

Precedent from the same day: `create-vm.yml` yielded three real defects — missing base
image, a bridged default that cannot get a lease on this LAN, and an IP check that could
not fail — none of which were findable by reading it. The manual run surfaced all three in
twenty minutes.

Still compounds §1.1 in the sense that no automated Vault restore exists. It no longer
blocks anything: the drill does not need it.

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

### 4.11 ~~CoreDNS in-cluster wildcard answers `192.168.1.160`~~ — **FIXED 08-15, tested from a pod**

**Resolution.** The wildcard now answers `192.168.1.201`, matching the LAN record, and the
per-hostname `lab-apps-internal.server` override was removed as redundant. Verified from a
pod before changing anything, forcing the address with `curl --resolve` so DNS was out of
the picture and only the network path was under test:

    immich.apps.lab.home.arpa   → 192.168.1.201 → 200
    authelia.apps.lab.home.arpa → 192.168.1.201 → 200

authelia was tested specifically because it is the one host with a documented failure on
this path, and the override was masking it.

**Residual per-node risk: closed 08-15.** `.201` is ARP-announced by a single kube-vip
holder, so a pod on a different node could in principle have taken a different path. Tested
from all five nodes with the pod pinned via `spec.nodeName`:

    n150-1      200
    n150-2      200
    odroid-nas  200
    opi5pro-1   200
    opi5pro-2   200

Both arm64 agents included. The pod→service-VIP path works from every node in the cluster,
so nothing here depends on where a workload happens to be scheduled.

Note for anyone repeating this: a per-node `dig` proves nothing. CoreDNS answers from its
own pods, so resolution is identical regardless of client placement — only `curl --resolve`,
which bypasses DNS and forces the address, exercises the per-node network path.

Rollback for the whole change is `git revert`, a CoreDNS restart, and one cache TTL (30 s).

The original finding, and the reasoning behind the choice, is kept below: the CNAME dead
end in particular is recorded so nobody spends an afternoon rediscovering it.

---

#### Original finding — 2026-08-15
`gitops/workloads/coredns-custom/configmap.yaml` — the `apps.lab.home.arpa:53` template
answers every in-cluster query for `*.apps.lab.home.arpa` with `192.168.1.160`. The LAN
wildcard moved to `.201` (`ingress_vip`, `hosts.yml:48`) on 2026-07-27; the in-cluster
zone did not move with it.

`kubectl get cm -n kube-system coredns-custom -o yaml` on 08-15 matches git byte for byte
— no drift, so the committed file is the whole story.

**Is it deliberate? Partly, and the part that is doesn't scale.** The hairpin workaround
is real: `lab-apps-internal.server` overrides exactly one hostname, `authelia`, to
Traefik's ClusterIP `10.43.10.71`. Line 24 of the file states the design outright — *"Add
entries here for each ingress hostname pods need to reach internally."* It is a manual
allowlist with one entry, added because authelia broke loudly during the SSO session
(`docs/sso-authelia-minio-troubleshooting.md:65-102`). Every other ingress name still
resolves to `.160`.

**The comment is also wrong.** Line 2 calls `192.168.1.160` the "Traefik ingress VIP". It
is the H4's node IP. The ingress VIP is `.201`. Fix this whichever way the decision goes.

**The HA gap is real.** In-cluster resolution for every ingress name except `authelia` is
pinned to one node — and that node is the H4, which also carries the NAS. Lose it and
kube-vip floats `.201` to a surviving control-plane node, LAN clients keep working, and
in-cluster pods stop resolving `*.apps` names. That is the single-A-record failure the
`.201` change eliminated, still live one layer down.

#### The three candidate targets

| Target | Hardcoded IP | Confidence | Note |
|---|---|---|---|
| `192.168.1.201` (service VIP) | No | **Tested 08-15 → 200. CHOSEN.** | Smallest change. One value for LAN and cluster. |
| `10.43.10.71` (Traefik ClusterIP) | Yes | High | Already proven by the authelia override. Rejected: hardcodes a ClusterIP that changes if the Traefik Service is recreated. |
| `rewrite` in a `*.override` key | No | Medium | Cleanest, but unverified. Not needed now — keep in reserve if `.201` ever regresses. |

**Do not assume `.201` fails.** An earlier draft of this entry implied it would, reasoning
from the documented hairpin failure. That reasoning does not carry: the hairpin note was
written against `.160`, which was then the H4's *node* IP — pod → node IP → out the
physical NIC → back in, the path that breaks. `.201` is a kube-vip **service** VIP, so
kube-proxy holds iptables rules for it and pod→`.201` should DNAT straight to the Traefik
pod without leaving the node. Different path, unknown outcome, cheap to test.

#### The test that decides it

`require-resource-limits` excludes the `default` namespace, so only an explicit image tag
is needed to clear admission (`disallow-latest-tag` rejects untagged images).

```bash
kubectl run dnstest --rm -it --image=nicolaka/netshoot:<pinned-tag> --restart=Never -- curl -sk -o /dev/null -w "%{http_code}\n" --resolve immich.apps.lab.home.arpa:443:192.168.1.201 https://immich.apps.lab.home.arpa
```

Repeat with `10.43.10.71`. TLS is unaffected either way — SNI still carries the hostname
and the cert is `*.apps.lab.home.arpa`, which is why the authelia override works today.

- **`.201` returns 200** → change the wildcard to `.201`, delete `lab-apps-internal.server`.
  One line, no new plugin behaviour, and in-cluster DNS finally agrees with the LAN record.
- **`.201` hangs, ClusterIP returns 200** → the hairpin problem generalises to the service
  VIP. Use `10.43.10.71` and accept the hardcoded value, noting that a recreated Traefik
  Service changes the ClusterIP and would break in-cluster resolution for everything at
  once. Consider pinning `spec.clusterIP` via `HelmChartConfig` if so.

#### Why the CNAME form was rejected — checked 08-15, do not retry

The tempting fix is a CNAME to `traefik.kube-system.svc.cluster.local`, avoiding any
literal IP. **It does not work in this Corefile**, for three reasons:

1. `upstream` no longer exists in the *template* plugin syntax; coredns/coredns#2436
   defaulted it to self and made arguments an error.
2. "Resolve against itself" means the plugin chain **in that server block**. The plugin
   README's own *Fabricate a CNAME* example only returns the A record because its Corefile
   has `forward . 8.8.8.8` in the same block.
3. `apps.lab.home.arpa:53` contains `template` and `cache` and nothing else. No `forward`,
   no `kubernetes` plugin — nothing that can resolve `cluster.local`.

Result: a bare CNAME with no A record, leaving the pod's stub resolver to chase it. glibc
generally will; musl (Alpine images) is less dependable. coredns/coredns#2600 is someone
hitting exactly this.

#### The third option, if a literal IP is unacceptable

k3s's `coredns-custom` supports **`*.override`** keys, which are imported into the main
`.:53` server block — the one that *does* have the `kubernetes` plugin. Only `*.server`
keys create separate blocks, which is why the current config is stuck in a block with no
resolver. Deleting both `.server` keys and adding:

```yaml
lab-apps.override: |
  rewrite stop {
      name regex (.*)\.apps\.lab\.home\.arpa traefik.kube-system.svc.cluster.local
      answer auto
  }
```

lets those queries fall through to `.:53`, where the rewrite maps them to the Traefik
Service, the `kubernetes` plugin resolves it, and `answer auto` maps the name back. No IP
anywhere. **Unverified:** `answer auto` under a many-to-one regex — every ingress name
collapses to one target and no documented example covers that shape. Needs a live trial,
not a merge.

#### Fix alongside, not before

Three documents accurately describe the current config and must be corrected *with* the
ConfigMap, not ahead of it: `docs/ARCHITECTURE.md:149`, `docs/services.md:14`,
`docs/OVERVIEW.md:26`. `tofu/dns/main.tf:8` carries the same value but cannot be applied
(§4.5).

#### Adjacent finding — in-cluster forwarders — **FIXED 08-15**

`lab.server` forwarded `lab.home.arpa` to `192.168.1.184` and `192.168.1.217` only — the
two OPi Zero 2W dnsmasq boxes — while line 6 of the file claimed "Pi-hole + dnsmasq
secondaries". Neither Pi-hole was listed. In-cluster resolution of every `*.lab.home.arpa`
name depended on two of the weaker boards while `.148` and `.116` sat unused.

Now forwards to all four, ordered strongest first, with `policy sequential`:

| Order | IP | Host | CPU / RAM | Link | Engine |
|---|---|---|---|---|---|
| 1 | `.116` | RPi 4B | A72 4C / 8 GB | wired | Pi-hole |
| 2 | `.184` | OPi Zero 2W #1 | H618 A53 4C / 4 GB | wired | dnsmasq |
| 3 | `.217` | OPi Zero 2W #3 | H618 A53 4C / 4 GB | **WiFi** | dnsmasq |
| 4 | `.148` | RPi 3B #2 | A53 4C / **1 GB** | wired | Pi-hole |

**`policy sequential` is what makes the order mean anything.** The forward plugin defaults
to `random`, which ignores order — so the old two-entry list expressed no preference, it
merely excluded the Pi-holes. Anyone reordering a `forward` list without setting the policy
is changing nothing.

**All four verified to serve the zone before promoting `.116` to first** — config intent
was not taken as sufficient. `hosts.yml:83-104` puts all four in the `dns` group as
`dns-1`…`dns-4`, so `dns.yml` gives each the same `dns_records` and
`address=/apps.lab.home.arpa/{{ ingress_vip }}`. Confirmed at runtime 08-15, querying each
resolver directly:

| Queried | `gitlab.lab.home.arpa` | `h4-core.lab.home.arpa` | `*.apps` canary |
|---|---|---|---|
| `.116` | `192.168.1.50` | `192.168.1.160` | `192.168.1.201` |
| `.184` | `192.168.1.50` | `192.168.1.160` | `192.168.1.201` |
| `.217` | `192.168.1.50` | `192.168.1.160` | `192.168.1.201` |
| `.148` | `192.168.1.50` | `192.168.1.160` | `192.168.1.201` |

`.116` mattered most: `hosts.yml:91-96` records that it sat outside the `dns` group until
2026-07-27 and "kept handing out 192.168.1.160 indefinitely" while the three managed
resolvers moved to `.201` — *"an unmanaged resolver does not drift gradually; it holds
whatever it was last told, forever."* This change promotes that box to first upstream, so
the wildcard column above is the specific thing being checked. It now answers `.201`,
which also confirms the 07-27 re-add took effect.

Repeat this table's query if `.116` is ever rebuilt or drops out of the group.

**Verified live after the restart, 08-15.** Querying CoreDNS on its ClusterIP from the H4,
after `kubectl rollout restart -n kube-system deployment/coredns`:

    gitlab.lab.home.arpa       NOERROR  → 192.168.1.50    (via the lab.server forward zone)
    immich.apps.lab.home.arpa  NOERROR  → 192.168.1.201   (via the wildcard template)

CoreDNS logs confirm all three server blocks loaded — `.:53`, `apps.lab.home.arpa.:53`,
`lab.home.arpa.:53` — with no plugin errors, so `policy sequential` parses correctly on
CoreDNS 1.14.4. The `No files matching import glob pattern: /etc/coredns/custom/*.override`
warning is benign: no `.override` keys exist. It does confirm k3s wires up that import
path, which is the mechanism the rejected third option would have used.

**Theory raised and dismissed: Pi-hole listening mode.** Before this change the forwarders
were `.184` and `.217`, both bare dnsmasq; it now leads with `.116` and includes `.148`,
both Pi-hole. Pi-hole v6 defaults `listeningMode` to local-subnet-only and
`ansible/templates/pihole.toml.j2` does not set it, so there was a plausible failure mode:
queries arriving from the pod CIDR (`10.42.0.0/16`) being dropped by a resolver that
dnsmasq would have answered. **Tested — it does not occur.** Flannel masquerades pod
traffic leaving the cluster CIDR, so Pi-hole sees the node's `192.168.1.x` address and
permits the query. The Pi-holes were not excluded for this reason, and promoting them is
safe. Recorded so the theory is not re-raised as an objection.

**Tooling note.** Two verification runs returned no output and read as failures on a change
that was working. Cause was `kubectl run --rm -it` losing the attach race against a pod
that exits immediately — not DNS. `docs/OPS.md` now leads with the ClusterIP `dig`, which
needs no pod at all.

#### Still open — the LAN primary is the weakest box

Ranking the forwarders exposed an inversion this entry does not fix: `.148` is a 1 GB
RPi 3B and is the LAN's **primary** Pi-hole, while the 8 GB RPi 4B at `.116` is secondary
(`docs/HARDWARE.md:21-22`, `:114`). In-cluster traffic now prefers `.116`; every other
client on the network still asks `.148` first. That is client-side DNS ordering — Pi-hole
and DHCP config, not this ConfigMap — and wants a decision of its own.

Found 2026-08-15 while fixing the documentation half of §6.1. **Flagged, not changed** —
this is a cluster change and DNS is the lab's most load-bearing dependency. Rollback is
`git revert` plus one cache TTL (30s).

### 4.12 Every x86 node exceeds the kubelet nameserver limit — and the H4's DNS redundancy is fake

**Found 2026-08-19**, in the first query run after Kubernetes Event capture went live
(PR `feat/ledger-capture-k8s-events`). The kubelet caps a pod's `resolv.conf` at
**three** nameservers (a glibc limit it does not work around). Every x86 node supplies
more than three, so one is silently discarded. DNS still resolves, which is why this
never surfaced — `type` is `Warning`, nothing is failing, and the first specimen found
carried `"count":26090`.

**Three different resolver sets are live across five nodes:**

| Applied nameserver line | Nodes | Distinct physical hosts |
|---|---|---|
| `.148 .184 .217` | n150-1, n150-2 | 3 — but **no Pi-hole secondary** |
| `.148 .116 .152` | **odroid-nas (H4)** | **2** — octopi counted twice |
| *(no event)* | opi5pro-1, opi5pro-2 | list is ≤3; not truncated |

**`192.168.1.152` is octopi's second interface, and this repo already says not to use
it.** `docs/HARDWARE.md:22` lists RPi 3B #2 as `192.168.1.148` / `192.168.1.152
(avoid)`. So on the H4 — the NAS, a k3s server, and per `CLAUDE.md` the core of the
lab — two of three resolvers are the *same 1 GB Raspberry Pi 3B*, one of them via the
address the hardware doc flags. The H4 believes it has three-way DNS redundancy and
has two-way. Lose octopi and it drops two resolvers in the same instant, leaving only
`.116`.

**The N150s have the opposite defect.** Three distinct hosts, but the dropped resolver
is `192.168.1.116` — the rpi4b Pi-hole secondary. Both control-plane N150s therefore
run one Pi-hole and two plain dnsmasq fallbacks, so anything failing over past `.148`
loses ad/telemetry filtering entirely.

**The ARM nodes are the only ones configured correctly**, which suggests the x86 hosts
share a provisioning path the OPis do not.

**Not an outage. A redundancy and precedence bug**, in the lab's most load-bearing
dependency, on the node whose loss is least survivable.

**Where each list comes from — established 2026-08-21.**

The N150s' `.148 .184 .217` is not an accident. `ansible/node-dns.yml` writes
`/etc/systemd/resolved.conf.d/10-lab-dns.conf` with exactly those three as a
**routing-only** domain (`Domains=~lab.home.arpa`), targeting
`k3s_agents:k3s_new_servers`. The truncation warning arises because the kubelet sees
the *union* of that routing list and the node's global/DHCP nameservers, which exceeds
three.

**The H4 is managed by nothing, and it has two NICs.** `node-dns.yml` excludes it
deliberately — *"h4-core excluded — ansible_connection: local and already has
/etc/hosts workaround"* — and that workaround solves resolving lab names, not the
resolver list. `resolvectl status` on 2026-08-21:

    Global                    (no DNS servers)      resolv.conf mode: stub
    Link 2 (enp1s0)  +DefaultRoute   DNS: 192.168.1.148 192.168.1.116
    Link 3 (enp2s0)  +DefaultRoute   DNS: 192.168.1.152 192.168.1.184 192.168.1.148 192.168.1.116

**Two default-route links, each with its own DNS list, four distinct servers between
them.** The kubelet takes the first three of the union and reports the omission. The
`.152` entry — octopi's second interface, marked "(avoid)" in `docs/HARDWARE.md:22` —
is led by `enp2s0` alone; `enp1s0` is correct on its own.

Source is `/etc/netplan/50-cloud-init.yaml`, **generated by cloud-init**. That is why
no playbook touches it and why hand-editing it is not a fix: cloud-init can regenerate
it. Any change must either add a higher-numbered netplan file (later filename wins) or
disable cloud-init's network config first.

**A second question falls out of this and is not DNS:** why does the H4 have two links
with `+DefaultRoute` at all? That is an asymmetric-routing and source-address hazard on
the box that serves NAS traffic. Worth its own entry rather than being fixed silently
alongside the resolver list.

**To do.** DNS is this lab's most load-bearing dependency, and §4.11 and §6.1 are both
scars from changing it on an assumption. The draft playbook
(`ansible/playbooks/h4-dns-resolvers.yml`) **writes the netplan override but does not
apply it** — the apply step is `netplan try`, by hand, deliberately.

- [x] **Find what sets the H4's resolver list** — done 2026-08-21. Two default-route
      NICs, `enp2s0` carrying four servers led by `.152`, from a cloud-init netplan.
- [x] **H4 — `.152` removed 2026-08-21** via `netplan try`. `enp2s0` retained `.160`,
      `.200` and `.201` throughout and all five nodes stayed `Ready`.
- [x] **H4 FULLY RESOLVED 2026-08-21 16:14.** `grep -c nameserver
      /run/systemd/resolve/resolv.conf` returns **3**, and no `DNSConfigForming` event
      has fired for `odroid-nas` since — only n150-1 and n150-2, which are the
      separate fix below.

      **A third failure had to be fixed to get here.** Putting the same three servers
      on *both* links produced **six** entries in `/run/systemd/resolve/resolv.conf`:
      **systemd-resolved aggregates per-link DNS without deduplicating across links**,
      and says so in the file itself —
      `# Too many DNS servers configured, the following entries may be ignored.`
      The kubelet read six, kept three and warned, with the *correct* three in its
      applied line. Right servers, wrong count. Fixed by moving the resolver list to
      `enp2s0` alone (`h4_dns_link` in the playbook); `enp1s0` keeps
      `use-dns: false` and no nameservers.

      **`resolvectl dns` showed three per link and looked correct at every single
      stage.** It reports configured per-link state; the kubelet reads the aggregate.
      The acceptance test for anything touching resolvers is
      `grep -c nameserver /run/systemd/resolve/resolv.conf`, not `resolvectl`.

      Two things were learned the hard way and are worth keeping:

      - **Netplan merges lists across files; it does not replace them.** A 99- override
        can add a nameserver but can never remove one. Proven with
        `netplan get ethernets.enp2s0`, which returned the union of cloud-init's
        `[.152, .184]` and the override's `[.148, .116, .184]`. `.152` had to be
        deleted from `50-cloud-init.yaml` itself.
      - **The two links failed for different reasons.** `enp1s0` took its DNS from
        DHCP, so `use-dns: false` fixed it. `enp2s0`'s was hard-coded in the netplan
        file, so `use-dns: false` did nothing there. One assumption, two mechanisms,
        and the first fix worked on exactly half the problem — which looked like a
        partial success and was actually two separate bugs.

      Also established: **`enp2s0` is the primary interface**, carrying `.160` and both
      kube-vip VIPs. It is not a spare, and changes to it risk the cluster API and every
      ingress at once.
- [ ] **Reboot the H4 at a quiet moment.** Cloud-init network regeneration is now
      disabled, so boot-time networking rests entirely on the two netplan files.
      `netplan try` cannot test that path. Backup is at
      `/etc/netplan/50-cloud-init.yaml.bak-2026-08-21`.
- [ ] Confirm no *new* `DNSConfigForming` events for `odroid-nas`. Existing pods keep
      their old `resolv.conf`, so this only shows as pods are recreated. Checkable now
      only because events are retained (§3.9).
- [ ] Decide whether the H4 should join `node-dns.yml` rather than staying unmanaged.
      Being the only unmanaged node is how this happened.
- [x] **`lab_dns_servers` in `node-dns.yml` corrected** 2026-08-21, from
      `.148 .184 .217` (one Pi-hole, two dnsmasq) to `.148 .116 .184` (two Pi-holes,
      one dnsmasq). **Not yet applied** — it touches all four managed nodes and wants
      its own `--check`.
- [ ] **The N150 warning will persist after that change**, and this is the part worth
      understanding. `node-dns.yml` writes a *routing-only* drop-in
      (`Domains=~lab.home.arpa`), so its three servers apply to lab queries while the
      nodes' global resolvers still come from DHCP. The union is what the kubelet
      truncates. Correcting the list fixes *which* three get used; it does not reduce
      the count. Suppressing the DHCP-supplied global DNS on those nodes is a netplan
      change (`dhcp4-overrides: use-dns: false`), the same mechanism that worked on the
      H4's `enp1s0` — and a separate piece of work from this list.
- [ ] Resolve the docs disagreement found alongside this: `CLAUDE.md` calls
      opi-zero2w-1 (`.184`) "secondary DNS", while `README.md` lists `.184` as the
      *tertiary* dnsmasq fallback and rpi4b (`.116`) as the Pi-hole secondary. One is
      wrong and it is load-bearing for the decision above.
- [ ] Decide whether `.152` should exist at all. An address documented as "avoid" that
      is nonetheless in a production resolver list is worse than an undocumented one.

**A fourth set (`.148 .184 .152`) appeared under `node-exporter-tqxdl`** — a pod that
no longer exists, so that one is history rather than live config. See §4.13 for why a
deleted pod's event was still queryable.

**This has been firing since at least 2026-07-27 — the day of the wildcard outage.**
The event backfill taken on 2026-08-19 retained exactly two events from 2026-07-27,
and both are this one: `DNSConfigForming` on `kube-vip-ds-6gf7c` (n150-1) and
`kube-vip-ds-7tzlg` (n150-2), at 20:41:40 and 20:41:41. On the day DNS took down every
service URL in the lab, the cluster was concurrently reporting a *second, unrelated*
DNS defect — resolver truncation — and it went unread, because nothing was capturing
events. It is still unfixed twenty-three days later. This is not the cause of that
outage (§4.11 and the `.160` wildcard were), and it should not be conflated with it.
It is the clearest available answer to "what else was wrong that day."

Related: §3.3 (nothing verifies DNS actually resolves) and §4.11 (the CoreDNS wildcard).
This is a third, separate DNS defect — host resolver config, not cluster config.

### 4.13 Events leak past `--event-ttl` and never expire

**Found 2026-08-19** while measuring event retention for `docs/LEDGER-DESIGN.md`. Full
distribution of `kubectl get events -A -o json`, 123 objects:

    1   2026-06-30        2   2026-08-07
    25  2026-07-02        2   2026-08-11
    2   2026-07-27        1   2026-08-16
                          90  2026-08-19

Retention behaves normally: 90 of 123 are from the current day, consistent with the
`1h0m0s` upstream `--event-ttl` default. **The other 33 never expired.** They are
non-recurring — `count: 1`, `firstTimestamp == lastTimestamp` — so nothing is
refreshing them; they simply have no expiry.

The dates are not random. They cluster on days the control plane was disturbed:
2026-07-02 (n150-1/n150-2 joined as k3s servers), 2026-07-27 (the wildcard change),
08-07, 08-11, 08-16. The likely mechanism is **etcd TTL leases lost across apiserver
restarts or leader elections**, orphaning the keys they were attached to.

**Low severity, and not urgent.** 33 objects is nothing next to etcd's working set,
and the leak rate is a handful per control-plane disruption. It is filed because it is
a real, understood defect that will accumulate slowly and forever, and because it cost
four wrong answers before anyone measured it.

**To do:**

- [ ] Confirm no `--event-ttl` override exists (`kube-apiserver-arg` in
      `/etc/rancher/k3s/config.yaml`). If one does, this entry's premise changes.
- [ ] Re-measure after the next k3s upgrade or server reboot to confirm the leak
      correlates with control-plane restarts rather than something else.
- [ ] Decide whether to care. Doing nothing is defensible; the entry exists so the
      next person to find an impossibly old event does not spend an afternoon on it.

### 4.14 Nothing in Ansible owns hostnames — they were set by hand and drifted

The consequence side of §3.10. Every host's hostname was set once, manually, at flash
time, and nothing has enforced it since. `ansible/inventory/hosts.yml` is the naming
source of truth for humans and for `--limit`, but no play makes the machines agree
with it. Result: four naming conventions, one host answering to two names, and one
still on a vendor default.

The fix is a small play using `ansible.builtin.hostname` driven from
`inventory_hostname`, plus the matching `/etc/hosts` 127.0.1.1 line, run against the
whole fleet. It is a handful of tasks.

**It is also the most dangerous small change on this list, and must not be run
fleet-wide.**

**k3s derives its Kubernetes node name from the host's hostname.** Renaming a cluster
node does not rename its `Node` object: the old one lingers `NotReady` and a new one
registers empty. Worse, this repo pins workloads to node names in eighteen places via
`kubernetes.io/hostname` selectors — `odroid-nas` (6), `n150-1` (12), `opi5pro-1`,
`opi5pro-2`. Every one of those becomes unschedulable the moment the underlying node
answers to a different name, and several of them own `local-path` PVs that cannot
follow. That is the `lldap`/n150-2 outage pattern from
`gitops/workloads/lldap/postgres.yaml:6`, executed deliberately across the fleet.

**Scope it accordingly:**

- [ ] **Non-cluster hosts only, to begin with** — the Pis and Zero 2Ws. They are the
      ones that are actually inconsistent, they carry no `kubernetes.io/hostname`
      selectors, and the blast radius is a reboot.
- [ ] Identify `orangepizero2w` before touching it. An unattributed host on the
      network is its own small finding.
- [ ] Resolve the `opi-zero2w-4` / `opizero2w-4` duplicate — confirm it is one machine
      renamed, not two.
- [ ] **Cluster nodes: flag, do not perform.** `odroid-nas`, `n150-1`, `n150-2`,
      `opi5pro-1`, `opi5pro-2` already match their inventory names, so there is
      nothing to fix and every reason not to touch them. If a rename is ever genuinely
      needed it is a drain → delete Node → rejoin operation with the nodeSelectors
      updated in the same PR, not a hostname play.
- [ ] Add the play to CI's `--check` path so drift is caught rather than assumed.

Related: §3.10 (the correlation cost), §3.9 (found while chasing the same thread).

### 4.15 Alloy keeps no position state, so every restart re-ingests and is partly rejected

**Found 2026-08-21**, immediately after the §3.9 pod rollout. Fresh Alloy pods emitted
a wall of:

    has timestamp too old: 2026-07-31T10:30:05Z,
    oldest acceptable timestamp is: 2026-08-14T02:12:10Z

The chart's default `storagePath` is `/tmp/alloy` — ephemeral, gone with the pod. With
no persisted read positions, a restarted Alloy re-reads container log files from the
beginning for long-running pods (`traefik`, `metrics-server`,
`argocd-applicationset-controller`, and the log files of the long-deleted
`promtail-2vvp7`) and tries to push July entries into Loki's rejection window.

Two costs. The obvious one is churn: every restart re-ingests weeks of logs and burns
ingestion budget against a 16 MB/s cap. The subtler one is that these are **batch-level
rejections** — a batch containing one too-old entry is dropped whole, so current
entries pushed alongside it are lost too. Same failure shape as the label-limit
rejections in §3.9, different trigger.

It self-corrects once Alloy catches up to the present, so this is chronic rather than
urgent.

**To do:**

- [ ] Give Alloy a persistent `storagePath` on a volume that survives restarts. This
      means adding a volume to a DaemonSet, so it wants its own PR and its own
      verification — deliberately not bundled with the §3.9 mount fix.
- [ ] Decide whether Loki's `reject_old_samples_max_age` should be raised. Probably
      not: the rejection is correct behaviour and raising it would let stale replays
      land silently, which is worse than the noise.

---

## 5. Scheduled / time-bound

| Item | By | Ref |
|---|---|---|
| Renew `token-admin` (720h TTL) | **2026-09-06** | `TODO-2026-08-03.md:248` |
| ESO → Kubernetes auth (token expires) | **~2026-09-08** | `TODO-2026-08-03.md:261` |
| Destroy superseded unseal shares (envelope item 5b) | **2026-11-16** | §1.2, `docs/BREAK-GLASS.md` |
| ~~Enable `backup-offsite.timer` after seed~~ | ~~Sunday 08-09~~ | done — §1.3 |

The two September items fail **silently**: `token-admin` stops authenticating, and ESO stops
syncing secrets with nothing visibly broken until something needs a refresh. Neither has an
alert. Do them at a time of your choosing rather than theirs — and note that since §1.11,
letting `token-admin` lapse means a `generate-root` ceremony to get back in, so it costs
more than it used to.

The November item is the opposite shape: nothing breaks if it is missed, but a superseded
set of unseal shares with no expiry quietly becomes a permanent second copy of full Vault
access, which is the reverse of what the rekey was for.

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

**Vault transit / cloud-KMS auto-unseal** — the only real escape from the trade in §2.5,
where auto-unseal requires a threshold of shares on the RPi5 and therefore makes root
there equivalent to full Vault access. Rejected because it introduces an external
dependency (or a second Vault) in the recovery path, which is the opposite of what the
break-glass work is for. Revisit only if the RPi5 stops being trusted.

---

## 9. Small, live, cheap

- **~440 MB of pre-migration files in the etcd snapshot directory** — found during Drill 2c.
  `/mnt/cold-8t/k3s-etcd-snapshots/` holds `state-2026-06-25_1645.db` (19 MB),
  `state-2026-06-28_0300.db` (421 MB) and `etcd-2026-06-24_1739-odroid-nas-…`. None match
  the `etcd-snapshot-*` glob that `backup-etcd.sh.j2:98` prunes on, so they have sat there
  since June and will sit there forever. Confirm they are the pre-embedded-etcd sqlite
  state (`backup-etcd.sh.j2:14` mentions the `state.db` rename) and delete.

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
