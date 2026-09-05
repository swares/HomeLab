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

## 0. ~~OPEN INCIDENT — H4 will not complete boot~~ — **RESOLVED 2026-08-26**

> Full write-up: **`docs/INCIDENT-2026-08-23-h4-boot.md`**. No data lost.
>
> **Root cause:** `/srv/nas` mounts `/dev/vg_microshift/lv_nas`, an LV that does not exist
> until `microshift-lvm-loop.service` runs — and that service is `WantedBy=multi-user.target`,
> which comes *after* `local-fs.target`. A dependency cycle. The mount timed out,
> `local-fs.target` failed, and boot stopped before `sshd`. **Latent for 62 days**; the
> reboot merely exercised it.
>
> **My mdadm theory was wrong** — both arrays were `[2/2] [UU]` throughout. The §1.4 UUID
> change did not cause this, and the `mdadm.conf` question raised there can stay closed.
>
> **Fixed** in `ansible/playbooks/storage.yml`: `x-systemd.requires=microshift-lvm-loop.service`
> so `/srv/nas` waits for the loop device rather than racing it, plus `nofail` on all three
> data mounts. Also `immich-postgres` 512Mi → 2Gi — it OOMKilled seven times during WAL
> replay, having been sized for idle rather than recovery.
>
> **Confirmed 2026-08-26 19:45 UTC by a clean unattended reboot.** `microshift-lvm-loop`
> reached `active (exited)` — the state it never reached on 2026-08-23 — all four mounts
> came up, and SSH answered with no console intervention.

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

### 1.2 ~~The offline break-glass envelope does not exist~~ — **PRINTED AND IN USE 2026-08-17; item 7 added 2026-08-21**

**Every one of items 1-6 was drilled and worked.** The gap found by drilling was not a
broken item — it was a missing category: **all six are things you need once you are
already on a machine, and none of them gets you onto one.**

The login account username and password are now **item 7** (`docs/BREAK-GLASS.md`). It is
not derivable from anything else in the envelope:
`ansible/inventory/group_vars/all/secrets.yml:10` stores `lab_user_password_hash`, so item
6 decrypts successfully and yields a **hash**, which cannot be used to log in. The obvious
repair — `rotate-passwords.yml` to set a known password — needs SSH access you do not have,
and password authentication is disabled on every Linux host by that same playbook
(`:104-105`).

Console is then the only route: workable on the H4 and N150s, but the OPi Zero 2Ws and the
RPi 3B are headless and would need a serial cable or a reflash.

**Item 8 added 2026-08-21: a dedicated break-glass SSH key.** Item 7 only works at a
physical console, and the OPi Zero 2Ws and RPi 3B do not have one — item 8 is the network
route back in. `ansible/playbooks/break-glass-key.yml` installs the public half on every
Linux host; the private half is generated offline and lives on paper only.

- [ ] **Generate the pair offline** on a machine outside the lab, commit only
      `ansible/files/break-glass.pub`, run the playbook, then **test it** —
      `ssh -i ./break-glass -o IdentitiesOnly=yes <user>@192.168.1.160 'id'` — before
      shredding the file copy. An untested break-glass key is worse than none.
- [ ] Verify the paper transcription by typing it back **from the paper**. Diffing against
      the file proves the file is right, not the paper, and the paper is what you will be
      holding.

*Worth noting how this was found: not by review, but by actually running the drill. Items
1-6 all passed their tests; the missing one was invisible until someone needed to log in.*

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

### 1.9 Backup lock contention between `backup-nas` and `backup-offsite` — **both directions now handled**

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

**The reverse direction was still unguarded — fixed 2026-08-21 by chaining.**

Bounding the copy protected the nightly job from a long offsite run. Nothing protected
the offsite run from a long nightly job. `backup-nas` normally takes ~10 s, but
`docs/BACKUP-RESTORE.md` records that a large Immich import can push it to hours, and a
run still holding the primary repo lock at 02:30 fails the offsite copy with the
identical error. **Scheduling cannot fix this**, because neither job knows in advance
how long the other will take — an hour of clock separation is a guess, not a guarantee.

`backup-offsite.service.j2:4` carried `After=backup-nas.service`, which reads like
protection and was not: ordering directives apply only within a single systemd
transaction, and two independent timer activations never share one. The file's own
comment admitted this.

`backup-nas.service` now carries **`OnSuccess=backup-offsite.service`**. The two run in
one transaction, so the `After=` finally means what it appears to mean and the offsite
copy waits for the lock to be released however long that takes. Requires systemd >= 249
(22.04 ships 249).

**Accepted trade-off:** the offsite copy no longer runs when `backup-nas` fails.
Correct in principle — copying a repository that just failed to update has little value
— but one root cause now raises two alarms: the failed unit, and the offsite
healthchecks.io check going silent at 25h/3h. Two alerts beat a silent gap.

**Applied and verified 2026-08-21.** `systemctl show backup-nas.service -p OnSuccess`
returns `OnSuccess=backup-offsite.service` on the host, and `systemd 249.11` supports it
(249 is the version that introduced it — no margin, but supported). That `show` output
is the real check: it proves systemd *parsed* the directive rather than that the file
merely contains the text. Compare `Docs=` in `microshift-lvm-loop.service`, which sat
there looking correct and meant nothing (§3.11).

- [x] **`backup-offsite.timer` removed 2026-08-29, on journal evidence.** The entry
      demanded the journal rather than the config, and the journal is unambiguous — the
      gap between `backup-nas` finishing and `backup-offsite` starting, four nights:

          Aug 23  01:30:34.507098 -> 01:30:34.511941    4.8 ms
          Aug 27  01:30:38.955609 -> 01:30:38.961735    6.1 ms
          Aug 28  01:30:20.372400 -> 01:30:20.376809    4.4 ms
          Aug 29  01:30:25.183937 -> 01:30:25.188767    4.8 ms

      **Millisecond gaps are `OnSuccess=` inside one systemd transaction. A timer cannot
      produce that.** The separate 02:30:00 entries on the 27th, 28th and 29th are the
      timer's duplicate run — 9-10 seconds each, finding nothing new, exactly as this
      entry predicted a redundant copy would look. Aug 24-25 are absent because the H4
      was down (§0); Aug 26 19:08 is the hand-run during recovery.

      This is the check `systemctl show -p OnSuccess` could not perform. That command
      proves systemd *parsed* the directive; only the timestamps prove it *fired*, and
      the entry was right to insist on the difference.

      **How it actually happened is worth recording, because it was not a decision.**
      `backup-offsite.yml` manages the timer through `offsite_timer_enabled`, which
      defaults to false — so running that playbook to apply the §1.12 retention scoping
      disabled the timer as a side effect. The playbook was right and the enabled timer
      was the drift, but nobody chose the moment. It was then re-enabled by hand while
      the journal was still being read, creating fresh §3.11 drift minutes after the run,
      and disabled again once the evidence was in. Live state and git now agree:
      `systemctl is-enabled backup-offsite.timer` -> `disabled`.

- [x] **The comment-only divergence closed with it.** `backup-offsite.service.j2`'s
      comment block, updated 2026-08-21 and never applied, synced when `backup-offsite.yml`
      ran on 2026-08-29 — as this entry predicted it would, on the run that removed the
      timer. Recorded as closed rather than deleted: a divergence that was declared, dated,
      and then resolved by the exact mechanism named is the good outcome, and the contrast
      with §3.11's unnoticed kind is the whole point.

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

> **CORRECTION 2026-08-29 — "it will linger until roughly 2027-02" is wrong. It will
> linger forever.** Measured with `forget --dry-run` while validating §1.12's scoping
> change, and the mechanism is the same one that made lldap's history unreadable.
>
> restic groups snapshots by **host + paths**. Dropping `/mnt/cold-8t/VMs` from the
> `ExecStart` did not shorten the retention of the old snapshots — it started a *new*
> series and froze the old one. And `--keep-daily 7` keeps the seven most recent days
> **that have snapshots**, not the last seven calendar days. A group receiving no new
> writes therefore never ages out at all.
>
> The dry-run keeps **all 13** VMs-era snapshots: 2 in `VMs + /srv/nas`, 11 in
> `VMs + immich + /srv/nas`. The union of daily-7, weekly-4 and monthly-6 covers every
> distinct day those frozen groups contain, and always will.
>
> **So the removal freed nothing.** It stopped new copies. Measured on R2, 2026-08-29:
>
>     restic stats --mode raw-data
>     Snapshots processed:   47
>     Total Size:            203.579 GiB
>
> At R2's $0.015/GB-month that is **≈ $3.05/month, indefinitely** — not until 2027-02.
> The bill this removal was meant to stop is still being paid in full, and will be
> until somebody forgets those groups deliberately.
>
> The figure is a measurement rather than the inference it replaced. The original
> version of this correction reasoned that the image *must* still be there, because the
> offsite seed predated the 08-13 removal and frozen groups never age out. That chain
> was sound and it was still only a chain; `stats --mode raw-data` is the number it was
> predicting.
>
> **Group coverage verified in all three repositories the same day**, which is what
> made scoping the `forget` commands safe rather than merely plausible:
>
>     primary   23 h4-core/nas   25 lldap-k8s/lldap
>     cold-sec  35 h4-core/nas   34 lldap-k8s/lldap
>     R2        23 h4-core/nas   24 lldap-k8s/lldap
>
> Two groups everywhere, nothing else — so no snapshot escapes the two scoped rules.
> R2 trailing the primary by one lldap snapshot is the expected lag: the offsite copy
> chains off `backup-nas` at 01:30 and lldap writes at 02:30, so the newest lldap
> snapshot always goes over on the following night.
>
> The same arithmetic explains what `nas` retention actually looks like today. Four
> path groups exist, each with its own independent 7/4/6:
>
>     /mnt/cold-8t/VMs + /srv/nas                             2   Jun 24-25   frozen
>     /mnt/cold-8t/VMs + immich + /srv/nas                   11   Jun 29-Aug 13  frozen
>     /mnt/cold-8t/immich + /srv/nas                          8   Aug 16-27   frozen
>     /mnt/cold-8t/immich + /srv/nas + /var/lib/lab-ledger    2   Aug 28-29   LIVE
>
> **Adding `/var/lib/lab-ledger` on 08-27 silently reset the NAS retention series.**
> The live path set is two snapshots deep. The seven-day guarantee everyone believes
> in will be true in a week; it is not true now, and nothing said so.
>
> **The transferable rule: editing a backup's path list is a retention event.** It
> creates a new series with no history and freezes the old one with permanent history.
> Nothing in this lab announces either half.

- [ ] **Reclaiming the VHDX is now a deliberate deletion, not a wait.** Since those
      groups never age out, the only way to remove 224.7 GiB from three repositories is
      an explicit `restic forget` targeting them by path. That is irreversible removal
      of the only remaining copies of that image, against this entry's own advice to
      "restore it by hand from a snapshot older than this change if it is ever wanted."
      Decide which of those two you mean — both are defensible, but they are not
      compatible and the current state quietly chose the expensive one.

- [ ] **Reset the offsite repo while it is cheap.** Existing snapshots still contain
      the VHDX, so it is billed indefinitely (see the correction above). With the VHDX
      excluded, the real data is
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

### 1.12 ~~lldap's backups failed intermittently through August~~ — **NO FAILURE EXISTED. RESOLVED 2026-08-27**

> **Third correction, and the last one. The premise was wrong, not the numbers.**
>
> This entry has now claimed, in order: a continuous 15-day outage; then two gaps of 5
> and 7 days with intermittent success; then an image-pull hypothesis. All three were
> wrong, and all three were wrong the same way — **reading the residue of a retention
> policy as the record of a job**.
>
> **What actually happened: nothing failed.** `restic forget --prune` has been thinning
> lldap's snapshots every night since the repo was created, because the host policy is
> not scoped to the host.

**The line that did it** — `ansible/templates/backup-nas.service.j2:78`:

    ExecStartPost=/usr/bin/restic forget --prune \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 6

No `--tag`, no `--host`, no `--group-by`. restic's default grouping is `host,paths`, so
this applies the NAS retention policy to **every group in the repository** — including
`lldap-k8s` + `/dump/lldap.sql`. `backup-nas` runs at 01:30; the lldap CronJob writes the
same repo at 02:30. Every night, a unit that does not know lldap exists prunes lldap's
history.

**The proof is arithmetic, and it is exact.** All 24 surviving `--tag lldap` snapshots
(2026-08-27) decompose by path group, each group independently subject to the policy:

| group | surviving dates | count | why |
|---|---|---|---|
| `/data/users.db` | 07-19 … 07-26 | 8 | frozen group: last 7 daily + 1 weekly, preserved forever |
| `/tmp/lldap.sql` | 07-28, 29, 31, 08-01 … 08-04 | 7 | frozen group: exactly `--keep-daily 7` |
| `/dump/lldap.sql` | 08-09, 08-16, 08-18 … 08-22, 08-26, 08-27 | 9 | 7 daily + **2 weekly** |

8 + 7 + 9 = 24, matching `restic snapshots --tag lldap --json | jq length`.

**`08-09` and `08-16` are `--keep-weekly` picks, seven days apart.** They are the entire
evidentiary basis for "intermittent success", and they are an artefact of retention. The
older groups look dense because they are frozen — no new snapshots arrive to push their
dailies out — while the live group is continuously thinned. That contrast is what made
July look healthy and August look broken.

**Direct proof the backups ran.** Loki still held the 08-12 job's own output, and its
snapshot listing showed five consecutive nights inside what this entry called a gap:

    e6c33bc9  2026-08-08 02:30:13  /dump/lldap.sql
    7f8b5e42  2026-08-09 02:30:05  /dump/lldap.sql
    3c436b8c  2026-08-10 02:30:04  /dump/lldap.sql
    80d85dc8  2026-08-11 02:30:04  /dump/lldap.sql
    4261428a  2026-08-12 02:30:05  /dump/lldap.sql

Those snapshots existed on 08-12 and are gone now. Nothing deleted them but the nightly
`forget`.

**The one genuine gap, and it is already documented.** `/dump` is missing **08-23, 08-24,
08-25**. That cannot be retention: `--keep-daily 7` keeps the seven most recent days *that
have snapshots*, so had those nights produced snapshots they would have been kept and
08-18/19/20 evicted instead. 08-18/19/20 survived, so those three nights genuinely
produced nothing — which is the **H4 boot incident** (§0,
`docs/INCIDENT-2026-08-23-h4-boot.md`). The restic repo is an NFS export from the H4; the
H4 was down; the job had nowhere to write. Expected, explained, not an lldap defect.

**Also disposed of:** the "two-day gaps on 07-27 and 07-30 that nobody noticed at all."
Aged past their group's `--keep-daily 7`. Nobody noticed them because there was nothing
to notice.

**Retracted by name, so it is not re-proposed:** the image-pull hypothesis recorded here
on 2026-08-27 — that `imagePullPolicy: IfNotPresent` plus an unpinned node made the job
depend on docker.io at 02:30. It was measured and it does not hold: `k3s ctr images ls`
across all five nodes returned `restic=1` everywhere except n150-1, and `postgres=1`
everywhere except n150-2. Three of five nodes need no pull at all, which cannot produce an
80% failure rate — and there was no failure to explain in the first place. The sweep also
showed the control image is patchy in a *different* place, which is a real finding about
image-cache variance and belongs somewhere other than here.

**All four closed 2026-08-29** — merged in #489 and applied to the H4 the same day. Both
halves landed together, as this entry required.

- [x] **Scope the host `forget` to its own data.** Done in **all three repositories**, not
      just the primary: `backup-nas.service.j2` (primary), `backup-nas-copy.sh.j2`
      (cold-sec) and `backup-offsite.sh.j2` (R2). All three carried the same unscoped
      command; fixing only the one that caused this entry would have left the identical
      defect in two places looking fixed — the §4.1 trap. Each is now two scoped forgets
      followed by a single `prune`, since pruning is the expensive part and doing it twice
      buys nothing.
- [x] **lldap has its own retention: 30 daily / 12 weekly / 24 monthly.** Identical in all
      three repos, because there is no tiering argument at this size.
- [x] **The policy was chosen, not inherited.** The dump is ~17.5 KiB and changes little,
      so restic dedup makes depth almost free — the storage economics behind 7/4/6 on
      225 GiB of NAS data simply do not apply. Two years of monthly restore points for the
      directory every other service authenticates against costs kilobytes. On R2 depth does
      cost money, and it is still a rounding error at this size.
- [x] **Swept, and the answer made the scoping safe rather than merely plausible.** Exactly
      two groups exist in every repository — primary 23 `h4-core/nas` + 25
      `lldap-k8s/lldap`, cold-sec 35 + 34, R2 23 + 24 — so nothing escapes the two rules.
      **That guarantee is now enforced rather than remembered:** `backup-verify` §2c
      enumerates the groups weekly and fails on any that matches no forget rule, because
      the likeliest way to break this is a `--tag`/`--host` rename in
      `gitops/workloads/lldap/backup-cronjob.yaml` that `backup.yml` does not follow. It
      also treats an empty enumeration as *failure to verify* rather than as a pass.

**Verified before applying, with a falsifiable prediction.** `forget --dry-run` under the
new policy was predicted to remove nothing, on the grounds that `--keep-daily n` keeps the
most recent snapshot for each of the last *n days that have snapshots* — so a deeper policy
keeps a superset. Result: **25 of 25 lldap kept, 23 of 23 nas kept, zero removals.** The
applied run then converged to `changed=0`.

**One number is the proof this landed on the host and not merely in git**, and it is the
number this entry was always about: the lldap snapshot count should now *climb* nightly
instead of holding flat while quietly rotating. It was 24, then 25, and 2026-08-18 was taken
by the unscoped policy overnight while this fix was being written.

**Three false diagnoses, three unscoped defaults.** Worth stating plainly because the
pattern is the transferable part, not the incident:

- `restic snapshots --latest 5` — truncates per `host,paths` group, displayed 15 of 24
  and looked like a complete history.
- `restic ... | wc -l` — printed `0` on a permission error, indistinguishable from
  "no snapshots exist".
- `restic forget --prune` — applied to every group in the repo, not just its own.

In each case the tool did exactly what it was told, the default scope was wider or
narrower than assumed, and the output was *plausible*. A wrong answer that looks wrong
costs minutes. These cost three investigations across two days, and the last one was
nearly written up as a fix to a job that was working correctly the whole time.

**And the cheapest thing that would have prevented all of it:** `restic snapshots --tag lldap`
with no flags, run once, on 08-26. The full listing was always one command away.

---

### ~~1.12 lldap had no backup for 15 days in August and nothing recorded it~~ (original entry, retained)

**Found 2026-08-26**, incidentally, while reading `restic snapshots` output during the H4
recovery. The lldap repo's snapshot list has two holes:

    fd2689a6  2026-07-31  /tmp/lldap.sql
    ...
    fe9f1e59  2026-08-04 15:28  /tmp/lldap.sql     <- last before the gap
    4ad08fd9  2026-08-19 02:30  /dump/lldap.sql    <- first after it

That is **15 days with no lldap backup**, plus a shorter 07-27 → 07-30 hole earlier. The
path changes across the gap (`/data/users.db` → `/tmp/lldap.sql` → `/dump/lldap.sql`), so
the boundaries look like job-spec rewrites rather than infrastructure failure — the 08-02
hard-NFS incident in §1.8 sits immediately before the first one, and lldap's Argo app last
synced **08-04 13:14**, two hours before the last good snapshot.

**What makes this a §1 item rather than a monitoring one:** for 15 days the only copy of
the lab's identity database was whatever `lldap-data` held on a single `local-path` PV. The
directory service that every other service authenticates against had no copy-of-record.
Nobody knew until three timestamps were read three weeks later, by accident, while looking
for something else.

**It is also no longer investigable.** Prometheus has evicted that window (§3.14), the
Kubernetes events expired within the hour, and the Job objects rotated out. Three restic
snapshot IDs are the entire surviving record of a two-week outage. This is the concrete
case for `docs/LEDGER-DESIGN.md`: not "it would be nice to query history" but "a two-week
failure of the identity database's only backup left no evidence anywhere except a file
listing."

**To do:**

- [ ] `git log -- gitops/workloads/lldap/backup-cronjob.yaml` across 08-04 → 08-19 and
      identify what changed. The answer is in git even though it is nowhere else.
- [ ] Whatever broke it, add the failure mode to the CronJob's comments — this is the
      second lldap backup outage in a month (§1.8 was the first) and both were found by
      accident.
- [ ] Decide whether §3.5's never-succeeded blind spot was the reason it went unseen. Do
      **not** assume it was: the metric history that would prove it is gone, and the
      2026-08-26 investigation nearly recorded that assumption as fact.

### 1.4 ~~`storage.yml` can `mkfs` a cold mirror by unstable device name~~ — **FIXED 2026-08-21, one step left**
`docs/REVIEW-2026-07-24.md:291` (H15)

The cold disks are the copy-of-record. Device-name-based formatting is how a reboot
that reorders `/dev/sdX` destroys them.

**What the exposure actually was.** `community.general.filesystem` ran with
`force: false`, so it would not overwrite an existing filesystem — the original finding
slightly overstated the destruction. The real risks were subtler and still serious:

- **Mounting the wrong array.** `/dev/md0` and `/dev/md1` are assembly-order names, not
  identities. A reboot, a degraded member, a disk replacement or an added controller can
  renumber them. Restic would then write the primary repo onto the secondary mirror and
  apply each tier's retention policy to the other tier's data.
- **Formatting a blank device that inherits a free `mdX` number.** `force: false` stops
  overwrites but not creation, and a replacement disk is exactly a blank device.

**The fix: no device names anywhere in the cold-tier path.** Filesystem UUIDs are
properties of the filesystem and survive every renumbering. `storage.yml` now:

1. Asserts `cold_primary_fs_uuid` / `cold_secondary_fs_uuid` are defined, refusing to
   fall back to device names.
2. Resolves each UUID with `blkid -U` (read-only, `check_mode: false` so `--check`
   reports true state) and prints which device it currently occupies — informational
   only.
3. **Fails loudly if either filesystem is absent**, with a message saying explicitly
   that this means the array is not assembled, *not* that a filesystem needs creating.
   Creating a cold tier is a deliberate separate act, and the playbook no longer
   contains a task that could do it by accident.
4. Mounts by `UUID=`, so `/etc/fstab` is renumber-proof too.

The `community.general.filesystem` task that remains applies to the NAS logical volume
on the hot tier (`/dev/vg_microshift/lv_nas`) — a stable LVM path, deliberately kept.

**To do:**

- [x] **UUIDs captured into inventory** 2026-08-21 under `h4-core`:
      `cold_primary_fs_uuid: 9880ec9a-…` (8 TB, `/mnt/cold-8t`) and
      `cold_secondary_fs_uuid: 2b91e96d-…` (~5.45 TB, `/mnt/cold-sec`).
      `cold_primary_device` / `cold_secondary_device` deleted — no code references
      either name anywhere in the repo.
- [x] **Applied 2026-08-21 18:38 UTC.** `/etc/fstab` now reads
      `UUID=9880ec9a-… /mnt/cold-8t xfs defaults,noatime 0 0` and
      `UUID=2b91e96d-… /mnt/cold-sec xfs …`. Both UUIDs resolved to their expected
      arrays (`/dev/md1`, `/dev/md0`), so the numbering had not drifted yet — the fix
      landed before the risk materialised rather than after.
- [ ] Consider pinning array assembly as well, with `ARRAY` lines carrying UUIDs in
      `/etc/mdadm/mdadm.conf`. Not required now that nothing depends on the numbering,
      but it would stop the numbers moving in the first place. Deliberately not
      auto-generated here: writing wrong `ARRAY` lines is its own way to lose an array.

### 1.5 ~~Nothing ever trims the cold-sec copy repo~~ — **FIXED, confirmed 2026-08-21**

Verified in code, not inferred from another document. `ansible/templates/backup-nas-copy.sh.j2:98-101`
runs `restic -r "$DST" … forget --prune --keep-daily/--keep-weekly/--keep-monthly` against
`{{ restic_copy_repo }}` = `/mnt/cold-sec/restic`, and it is wired in un-swallowed at
`backup-nas.service.j2:71` (`ExecStartPost`, no `-` prefix, so a failure fails the unit).
Retention values 14/8/12 at `ansible/playbooks/backup.yml:31-33`.

The heading claimed "Nothing ever trims" while the body already said "possibly fixed 07-25".
The body was right.
`docs/REVIEW-2026-07-24.md` (M-new-1) — *possibly fixed 07-25 via `backup-nas-copy.sh`
retention; verify against the live repo rather than the doc.*

### 1.6 ~~R2 retention has never deleted a snapshot and cannot~~ — **FIXED, confirmed 2026-08-21**

Both halves of the mechanism are gone. Stable staging path: `backup-cloud.yml:204`
`STAGE=/var/tmp/backup-cloud-stage`, with `:200-203` explaining it is deliberately NOT
`mktemp` because "a varying name broke retention grouping". Grouping: `:304-305`
`restic forget --prune --group-by host,tags`. `grep -rn TMPDIR ansible/` returns nothing.

**Proven live, not just in code.** `backup-verify` reported `R2 holds 11 cloud snapshots`
on 2026-08-16 and `R2 holds 10 cloud snapshots` on 2026-08-21. The count went *down*:
retention is deleting.
`docs/REVIEW-2026-07-24.md` (M-new-4) — `TMPDIR` in `SOURCES` means the staging path
varies per run, so `--group-by` never matches an existing series. Every cloud snapshot
is kept forever, and the 10 GB free tier is the ceiling.

### 1.13 An unattended upgrade silently stopped time sync on an etcd voter — **FIX APPLIED FLEET-WIDE 2026-09-02; one policy decision open**

> Recovery is now in place on all 11 chrony hosts and verified by the number that
> identified the fault: `0 sources offline`, everywhere, plus an hourly reconcile timer
> so recovery no longer depends on an event hook firing. Applying it found six hosts that
> had never received the backstop at all (see To do). What remains is not a repair but a
> question: whether etcd voters should self-upgrade networking packages unattended.

**Found 2026-08-26.** n150-2 ran **18 hours with no time synchronisation at all**, and the
sequence is fully in the journal:

    06:10:49  apt-daily-upgrade.service starts (unattended-upgrades)
    06:11:37  systemd re-executes, pulled in by a package upgrade
    06:11:38  Stopping systemd-networkd.service
    06:11:38  chronyd: "Source <all 17> offline"

chronyd marks a source offline when a transmit returns `ENETUNREACH`, which every source
did the moment networkd tore down the addresses. networkd returned one second later.
**chrony did not, and never would have** — it does not retry a source it has marked
offline. It waits to be told, and nothing on this host could tell it: the chrony package
ships its come-back-online hooks for **ifupdown** and **dhclient**, and neither is
installed (`dpkg -l ifupdown` → `un`, no `/etc/network/interfaces`, no
`isc-dhcp-client`). `networkd-dispatcher` *was* installed with **every hook directory
empty**. The offline path fired; the online path did not exist.

**Why this is a §1 item.** `apt-daily-upgrade` runs nightly on every Debian/Ubuntu host in
the lab, so this is reproducible fleet-wide, on any package that restarts networking.
n150-1 escaped by timing, not configuration — its `chrony.conf` is byte-identical (verified
by `diff`). It is filed next to §1.7 because it is the same shape: **unattended upgrades
change running behaviour with nothing watching**, and here the victim was an etcd voter.

**How close it came to mattering, honestly:** the final offset was **4.9 microseconds**.
Chrony's frequency estimate held the clock accurate for 18 undisciplined hours, so nothing
broke. The exposure is the next reboot, a warm RTC, or a longer gap — and the fact that
`systemctl is-active chrony` said `active`, ICMP worked, and the config was correct
throughout.

**The number that identified it:** `chronyc activity` → `0 sources online / 17 sources
offline`. `Reach 0` on every source reads identically to a firewall blocking UDP 123, and
that misreading cost a round trip; the online/offline count is the value the firewall case
cannot produce.

**Fixed** in `ansible/chrony.yml` — a `/etc/networkd-dispatcher/routable.d/50-chrony` hook
running `chronyc onoffline` (not `online`: it reconciles against the current routing table,
so it is correct on a host that genuinely has no route), plus a `chrony-onoffline.service`
oneshot bound to networkd's lifecycle for the seven hosts that have no dispatcher. And
`LabClockUnsynced` in `gitops/workloads/monitoring/lab-alerts.yaml`, critical so it reaches
the phone.

**Verified the only way that counts:** `systemctl restart systemd-networkd` on n150-2,
then `chronyc activity` → `17 sources online`. That is the exact test the pre-fix host
failed.

**A caution for whoever re-tests this.** The same test at `sleep 5` returned `0 sources
online` and was briefly diagnosed as networkd-dispatcher being unable to observe a networkd
restart. It was a five-second wait against an event that takes longer. Allow **at least 20
seconds**. This was the fourth wrong cause proposed for this one fault — after the
firewall reading of `Reach 0`, the ifupdown hook, and the choice of `routable.d` — and each
was proposed from convention rather than from something measured on these hosts. The
measurement that held up every time was: restart networkd, count sources online.

**To do:**

- [x] **Run `chrony.yml` fleet-wide — done 2026-09-02.** `--check` clean, real run
      `failed=0` on all 13 hosts. Fleet state afterwards, on every one of the 11 chrony
      hosts: `0 sources offline`, and `chrony-onoffline.timer` armed with a next run.
      Ten of eleven now track `h4-core.lab.home.arpa` at stratum 5; h4-core itself tracks
      Cloudflare, as designed. The two Arch boards sync via timesyncd to 192.168.1.160.

      **And running it found the thing running it was supposed to find.** Six hosts —
      `rpi4b`, `rpi5`, `opi5pro-1`, `opi5pro-2`, `opi-zero2w-4`, `octopi-dns` — reported
      `changed` for *Install oneshot unit*, meaning **`chrony-onoffline.service` had never
      existed on them at all**. The install task had been gated on systemd-networkd being
      active, which reads sensibly and is wrong: the oneshot is precisely the backstop for
      hosts where the dispatcher path is unavailable, and the gate excluded exactly those.
      `opi5pro-1`/`-2` had the `routable.d` hook but no backstop; the other four had
      neither, so from 2026-08-26 until today they carried **no come-back-online path of
      any kind**. The fix was un-gating the install (`chrony.yml`).

      §3.11 says *merged is not applied*. This is its sibling and it is nastier, because
      the run is green either way: **applied is not applied everywhere.** A play whose
      install task is conditional will report `ok` on a host it deliberately skipped, and
      the `PLAY RECAP` looks identical to full coverage. The only signal was reading
      *which* hosts said `changed` on a run that was expected to be a no-op.

- [x] **Fleet-wide `chronyc activity` sweep — done, and it was not empty.**
      `opi-zero2w-3` was parked: its LAN source had been offline **five days** while
      `timedatectl` reported `System clock synchronized: yes`, because it had silently
      fallen back to a Cloudflare pool source. Both statements were true simultaneously,
      which is the whole hazard in this entry — the host is synchronised *to the wrong
      stratum via the wrong path*, and every green indicator stays green. Corrected with
      `chronyc onoffline` (Reach 0 → 37); it now holds `h4-core` at 171 µs.

      Also confirmed here: **`chronyc burst` does not fix this.** It produced a sample and
      even a `^*` selection while `Reach` stayed `0` and the source stayed offline. It
      makes the display look repaired without repairing anything. `onoffline` is the verb.

- [x] **`systemd-networkd-wait-online` exit 1 on n150-2 — root-caused and fixed
      2026-09-01, and it was not the veths.** The guess in the original entry ("the bridge
      plus k8s veths") was wrong. `enp1s0` is a *bridge port* that `50-cloud-init.yaml`
      set `dhcp4: true` on (50 sorts after `10-kvm-bridge.yaml`, so cloud-init won). A
      bridge port cannot complete a DHCP lease, so the link never reached
      `SETUP=configured` and netplan's own drop-in waited for it forever — n150-1 since
      2026-06-29, n150-2 since 2026-07-25. Same file also produced the duplicate-resolver
      count in §4.12. See `playbooks/kvm-netplan-fix.yml` and
      `playbooks/network-online-wait.yml`; both applied, both verified.

- [ ] **Still open: should etcd voters hold `systemd` out of unattended-upgrades?**
      Everything above fixes the *symptom class* — the clock now recovers within an hour
      on every host, by hook where a dispatcher exists and by timer everywhere else. The
      unanswered question is upstream of that: whether a node holding an etcd vote should
      restart its own networking stack unattended at 06:10 with nothing watching. The hook
      makes the blast radius small; it does not make the decision. Filed next to §1.7,
      which resolved the same tension for restic by pinning rather than by monitoring.

**Two smaller things surfaced by the verification, neither worth its own entry:**

The play's *Report which chrony recovery mechanism covers this host* task prints
`package hook: /etc/network/if-up.d/chrony, /etc/dhcp/dhclient-exit-hooks.d/chrony` for
**every** host — including the four that were provably uncovered. It measures that the
files exist, which was the correct 2026-08-29 fix for an earlier version that merely
asserted they did. But existence is not a working trigger: this entry established at the
top that neither `ifupdown` nor `isc-dhcp-client` is installed, so those files are
inert. The one task designed to report coverage honestly currently overstates it. It
should gate on the consumer being installed, not on the file being present — the same
distinction as §4.12's `resolvectl` versus `resolv.conf`.

And the verification one-liner used above ends `chronyc activity | sed -n "2p;3p" ||
echo "(timesyncd)"`. A pipeline's exit status is the *last* command's, so `sed` returns 0
on empty input and the `|| echo` fallback can never fire. The two Arch hosts printed
nothing at all, and that read correctly only because we already knew why. Per *empty
output is not a finding until you prove the check can speak* — a host that had simply
lost `chronyc` would have printed the identical nothing.

### 1.7 ~~Nothing pins restic, so an unattended upgrade can change copy semantics~~ — **FIXED AND APPLIED 2026-08-27**

> `backup.yml` now holds restic via `dpkg_selections` after installing it, and verifies
> by reading dpkg's own record rather than trusting that the module reported `changed`.
> Applied to h4-core the same day:
>
>     restic 0.12.1 compiled with go1.18.1 on linux/amd64 held (dpkg 'hi')
>
> The `h` prefix is the value that cannot be produced without the hold sticking — the
> module reporting `changed` says only that it ran. 0.12.1 is well below the 0.14
> boundary, so the held version is one both copy scripts already parse correctly.
>
> **Not pinned to a version string on purpose:** the available version differs by distro
> and arch across this fleet, and a pin naming a version a host's repo does not carry
> would fail the play on hosts that were previously fine.
>
> The `--check` run beforehand printed `dpkg 'ii' (NOT held; this run would apply the
> hold)` — the control that proved the check could speak before the real run made it say
> something different. Both read-only commands carry `check_mode: false` for that reason.
>
> **Found while doing it, and bigger than this entry:** the same `--check` reported
> `backup-nas.service` as `changed` — the live unit was missing `/var/lib/lab-ledger`,
> merged to main at 15:09 the same day and never applied. See §3.11. Original finding
> below.

**Reframed 2026-08-21 — the original heading described a requirement, not the risk.**

The version guard the entry asks for **already exists** in both copy paths:
`backup-nas-copy.sh.j2:50-67` parses the version, refuses a non-numeric result
("Refusing to guess which copy syntax is safe"), and branches at `:84-90`; the same logic is
at `backup-offsite.sh.j2:64-78`. So the copy syntax is handled.

**What is actually open is the pin.** `ansible/playbooks/backup.yml:45-48` installs restic with
a bare `state: present` — no version, and there is no `apt-mark hold`, `dpkg_selections`, or
`/etc/apt/preferences.d` entry anywhere in the repo. An unattended `apt upgrade` can move
restic under the backup path at any time.
`docs/BACKUP-RESTORE.md:360-372` (M-new-2), `ansible/templates/backup-nas-copy.sh.j2:9-19`

Upgrading past 0.14 reverses `copy` argument semantics. The version guard catches it,
but an unattended `apt upgrade` crossing that boundary is a real path to overwriting
the primary from the secondary. Pin it.

---

## 2. Security

### 2.1 ~~Pi-hole admin UI deploys unauthenticated~~ — **RESOLVED 2026-08-28; the primary really was, the secondary never was**
`ansible/playbooks/dns.yml:12`, `ansible/templates/pihole.toml.j2:21` (H16)

```
pihole_web_password_hash: ""     # double-sha256; source from Vault, NOT plaintext here
password = "{{ pihole_web_password_hash | default('') }}"
```

Those are the only two occurrences in the entire repo — the variable is set to empty
and never overridden, so it always renders empty. The template's own comment says
empty = no auth. This is the lab's load-bearing resolver.

**CORRECTION 2026-08-27 — the fix this entry prescribes would not have worked.** Checked
against Pi-hole's v6 documentation before writing the change. Two defects in that one
template line, and the entry only names the empty variable:

- **`password` is the wrong key.** In v6 `webserver.api.password` is the *plaintext*
  setup field; FTL consumes it and writes the hash to `webserver.api.pwhash`. The hash
  field is the one a config file should carry.
- **"Double-sha256" is the wrong algorithm.** That is Pi-hole **v5**'s scheme
  (`WEBPASSWORD` in `setupVars.conf`). v6 uses BALLOON-SHA256:
  `$BALLOON-SHA256$v=1$s=1024,t=32$<salt>$<hash>`.

So "source `pihole_web_password_hash` from Vault", done literally, would have written a
v5 hash into a plaintext field — setting the admin password to the literal text of a
hash — and every status signal would have looked fixed. Recorded because the shape
recurs: the entry was right that the value was empty and wrong about what the value was
*for*, and only reading the current upstream docs separated the two.

**Also wrong in this entry's framing:** `dns.yml`'s header calls the Pi-hole path
"preserved for future use once octopi is upgraded to Bookworm". The inventory disagrees —
`dns-1` (octopi, .148, primary) and `dns-3` (rpi4b, .116) both carry `dns_engine: pihole`.
Two live resolvers, not zero. The header comment is stale (§6).

**Fix written, on `feat/pihole-vault-password`, not yet merged.** `dns.yml` reads the
hash from Vault (`secret/lab/pihole`, key `web-pwhash`) delegated to `h4-core`, since the
resolvers have no `vault` CLI; gated so a dnsmasq-only `--limit` still runs without a
token; and asserts the value starts with `$BALLOON-SHA256$` — shape rather than mere
presence, because the old variable was always *defined* and always empty. The template
writes `pwhash` with no `default()`, so an unset variable cannot quietly deploy an open
UI again.

- [x] **Populate Vault** — done 2026-08-28. `secret/lab/pihole` key `web-pwhash`, a
      101-character BALLOON-SHA256 hash lifted from the live `rpi4b` config rather than
      generated fresh, so no working credential was changed to store one.
- [x] **The overwrite hazard** — fixed the same day, and it was worse than this entry
      said. See the resolution below.

---

**RESOLVED 2026-08-28 — and the entry was half right, per host, which nobody had checked.**

The claim "Pi-hole admin UI deploys unauthenticated" was about what the *template* would
render. It was never checked against either live resolver. Checked now, they disagreed
with each other:

| host | live state before 2026-08-28 |
|---|---|
| `octopi-dns` (.148, **primary**) | **no admin password at all** — `pwhash=0` |
| `rpi4b` (.116, secondary) | password set since ~July; `pihole.toml` carries FTL's own `### CHANGED, default = ""` annotation |

So the lab's **primary** resolver really was serving an unauthenticated admin UI, and the
secondary never was. A blanket claim was 50% right and 100% unverified — and the half that
was true was the more important half.

**Why they diverged: neither file was ever templated.** `rpi4b` was added to the `dns`
group on 2026-07-27 and, as the inventory comment says, no playbook ever touched it. Its
`pihole.toml` is 70,528 bytes written by FTL and the web UI. `octopi-dns` is the same
shape. The template renders about thirty lines, so **a `dns.yml` run would have replaced a
live resolver's entire configuration** — including `webserver.api.app_pwhash`, a second
credential nothing in this repo manages. That is what the "pre-seed … on a fresh host"
task did on every run, despite its name.

**What shipped:**

- `dns.yml` reads the hash from Vault via `h4-core` (the resolvers have no `vault` CLI),
  gated so a dnsmasq-only `--limit` still runs without a token, and asserts the value
  starts with `$BALLOON-SHA256$` — shape, not mere presence, because the variable this
  replaced was always *defined* and always empty.
- The seed task carries `force: false`, so it seeds a fresh host and never overwrites a
  live one. Its name is now true.
- A read-only check of the two facts that have actually caused outages here — that
  `*.apps` answers `ingress_vip` and not `.160` (§6.1), and that `pwhash` is non-empty —
  asserted against **the file FTL loads**, not the template that would have been written.

**The check found the real instance on its first use.** Run against `octopi-dns` it failed
with `pwhash=0`, naming the host and the remedy. After `pihole setpassword` there it
returned `wildcard=1, stale160=0, pwhash=101` and passed. Both directions observed on the
same host in the same hour, which is the only way to know a check can do more than be
reliably angry.

Also settled in passing: `wildcard=1, stale160=0` on **both** resolvers. The inventory's
worry that `.116` "kept handing out 192.168.1.160 indefinitely" is no longer true of
either host.

**Deliberately not done:** the live hashes differ between the two hosts — same password,
different salt — because each was set with `pihole setpassword` locally rather than
templated. That is fine now that the file is not rendered; Vault's copy only feeds a
fresh-host seed. Do not "fix" the divergence by templating the file.

**Still open, small, and split out rather than buried here:**

- [ ] `webserver.api.app_pwhash` on both hosts is a second credential nothing manages,
      rotates, or records. It exists because FTL wrote it.
- [ ] `secret/lab/pihole` version 1 (created 2026-07-17 by the `root` actor, before the
      root token was revoked) held a key named `password` — plaintext, presumably for
      `tofu/dns`'s `TF_VAR_pihole_password`. It survives in kv2 history. Establish whether
      anything reads it, then decide whether a plaintext Pi-hole password should still be
      in a Vault that serves HTTP in the clear (§2.6).
- [ ] The `--check` also caught the playbook wanting to *widen* two permissions the hosts
      had tighter (`/etc/pihole` 0755→0775, `lab-clients.sql` 0640→0644). Git was wrong,
      the hosts were right; corrected in `fix/pihole-config-modes`.

Original finding retained below.

### 2.2 GitLab runner mounts the host Docker socket read-write
`gitops/workloads/gitlab-runner/values.yaml:40-45` (C5)

CI job pods get `/var/run/docker.sock` with `read_only: false` — that is node root for
anything that can open a merge request. Also no CPU/memory limits on build pods.

### 2.3 ~~Plaintext credential in git~~ — **FIXED 2026-08-27; live exposure checked and absent**

> `passwd` now renders `{{ lab_user_password_hash }}` — the Ansible Vault variable in
> `inventory/group_vars/all/secrets.yml` that `rotate-passwords.yml` already resolves.
> No new mechanism, same credential as the rest of the fleet, one place to rotate.
> `LabTemp123` no longer appears anywhere in the repo outside this file.
>
> **A detail the entry missed: the salt was fixed** (`labsalt`), so the hash was
> byte-identical in every VM ever built from this playbook. One disclosure covered all
> of them, retroactively and going forward — the usual "each build gets its own hash"
> intuition did not apply.
>
> **Fails closed now.** A `localhost` preflight play asserts the variable resolved to a
> `$6$` hash that is not the retired one. Without it, an unresolvable variable renders
> `passwd: ""` and builds a VM whose console account has *no* password — worse than the
> hardcoded one, and indistinguishable from success. The failure message names §4.1c as
> the likely cause, since running from the repo root skips `ansible.cfg` and therefore
> `vault_password_file`, which is exactly the 08-09 decryption failure.
>
> **`NOPASSWD:ALL` deliberately left alone** and commented as such: this password gates
> console/rescue login only, not privilege escalation — SSH uses the key. Tightening it
> is a separate change with its own blast radius on automation.
>
> **The half this entry did not have.** Fixing the playbook only affects VMs built from
> now on; `gitlab-1` already existed. Checked rather than assumed:
> `getent shadow swares | cut -d: -f2` on gitlab-1 does **not** begin
> `$6$rounds=4096$labsalt$`, so the published credential was never live there, or was
> rotated off it. Note precisely what that establishes — the hash in git was not the
> hash on the box. It says nothing about the strength of the one that is.
>
> gitlab-1 is in `gitlab_servers` and `standalone_vms`, and `rotate-passwords.yml`
> targets `all:!x86_nodes:!embedded` (`x86_nodes` is only `n150-3`), so it was in scope
> for rotation all along. Whether that playbook had *run* is not knowable from git —
> §3.11 — which is why the check was one command against the host rather than an
> inference from the inventory. That distinction is the whole reason this closed as a
> build-time defect instead of an incident.

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

**Scoped 2026-08-21.** Verified still true: `ansible/templates/vault.hcl.j2:9`
`tls_disable = true`, listening on `0.0.0.0:8200`, and §2.9 confirms no host firewall
anywhere — so every device on the LAN can reach it. Two of the entry's three citations
are now stale (`README.md` and `docs/OVERVIEW.md` no longer flag it; only the template
does).

**Blast radius: 19 files reference `http://192.168.1.128:8200`** — 7 Ansible playbooks,
3 scripts, the ESO `ClusterSecretStore` (`gitops/workloads/immich/external-secret.yaml:20`),
and 8 documents. Everything in the lab transits in clear: the Immich DB password, Grafana
admin, five Authelia OIDC secrets, restic repository passwords, R2 credentials, the ArgoCD
deploy key — and the tokens themselves.

The point is not that it is likely exploited. It is that **one compromised LAN device
converts directly into total lab compromise with no second step required.**

**Do it staged — Vault supports multiple listeners.** Flipping TLS on in place would
simultaneously break ESO, `backup-cloud`, `backup-offsite` (both fetch R2 credentials from
Vault), `healthchecks.yml` and the break-glass path, and it would surface at 02:30.

1. Add a TLS listener on `:8210` beside the existing plaintext `:8200`. Nothing moves.
2. Distribute the CA to hosts via Ansible.
3. Migrate consumers **one at a time**, verifying each — ESO first (most visible:
   `kubectl get externalsecrets -A` should stay `SecretSynced`), then the backup
   playbooks, then scripts, then docs.
4. Remove the plaintext listener last, once nothing references it.

Every step is independently reversible and there is no flag day.

**Open decision:** whether Vault's certificate is signed by the existing `lab-ca` root —
which means extracting that root's private key from the `lab-root-ca` secret so Ansible can
sign outside the cluster, putting the root key in a second place — or by a separate CA used
only for Vault, which avoids that but gives every client a second root to trust.

See **§6b.1** for the larger idea this scoping produced: Vault as an intermediate CA
issuing certificates for the whole lab. That is a different, bigger project; this entry
should be closed on its own first.

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

**Verified still true 2026-08-21.** Nothing in the repo installs or enables a firewall.
The only matches are conditional and would no-op on a host without ufw already present
(`node-exporter.yml:79-88`, `promtail.yml:197-206`, both gated on
`'ufw' in ansible_facts.services`), plus dead MicroShift-era `firewalld` at
`microshift.yml:47-60` and `iptables` appearing merely as a package dependency.

This is what makes §2.6 sharp rather than theoretical: Vault listens on `0.0.0.0:8200`
in clear, and nothing stands between it and any device on the LAN.

See **§6b.2** for the design and the reason not to start by writing rules.

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

### 2.13 ~~k3s server token was exposed during Drill 2c~~ — **ACCEPTED 2026-08-21, with triggers**
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

**DECISION: accept, and rotate for free during the next k3s upgrade.** Taken
2026-08-21, after weighing both sides rather than by default.

**Why not rotate now.** Rotation means a serial restart of k3s across a three-node
embedded-etcd control plane — the highest-risk routine operation in this lab, and the
one that has already cost a quorum (§ the `serial: 1` note). It also cascades: every
snapshot predating the rotation needs the OLD token, so the envelope gains an item 4b
carried until the R2 retention window closes, exactly like the Vault 5b item running to
November. That is a half-day of self-inflicted availability risk to close a bounded
exposure.

**And it is not the biggest hole.** The realistic threat here is someone already on the
LAN. That person has better options: §2.6 (Vault serving plaintext HTTP — live tokens
sniffable continuously), §2.1 (Pi-hole admin unauthenticated), §2.9 (no host firewall
anywhere). Rotating this token while those stand is bolting one door in a building with
open windows. **If security effort is going anywhere, it should go to §2.6 first.**

**Why accepting is defensible.** The token alone grants nothing. It needs either network
access to the cluster or an etcd snapshot, and the lab is LAN-only with remote access
explicitly deferred (§8). Snapshots live on the H4 and in R2, the latter encrypted under
a separate credential.

**Rotate immediately if any of these become true:**

- Remote access is un-deferred (§8 — Tailscale or WireGuard changes the threat model
  from "someone on my LAN" to "the internet", and this decision does not survive that).
- Any etcd snapshot leaves storage you control.
- Any host on the LAN is suspected compromised.

**Scheduled to happen anyway:** `make update-k3s` already drains and restarts every node
serially. Rotating during a planned upgrade costs almost nothing extra — the restarts
are happening, the procedure is gated, and attention is already on it. Added as a step
in `docs/UPDATES.md` §2 so the next upgrade picks it up.

- [x] Decision recorded 2026-08-21.
- [ ] Scrub the token from the H4's shell history:
      `grep -n 'K10' ~/.bash_history` then remove those lines and
      `history -c && history -w` in any live shell. Note this is hygiene, not
      remediation — the transcript copy is outside your control either way.
- [ ] Rotate at the next k3s upgrade, per `docs/UPDATES.md` §2.

Process note worth keeping: this happened while pasting command output for diagnosis, in a
session that had twice explicitly said not to paste the value. Reading a rule and applying
it under debugging pressure are different things — the durable fix is not typing secrets on
command lines at all, which is why `--token-file` was reached for in the first place. That
it is unsupported on the restore path (§ Drill 2c) is an upstream gap worth knowing.

### 2.12 Vault is never restarted, so it silently runs an old binary — **mechanism open; the seven-week instance was resolved 08-16**
**Heading corrected 2026-08-21** — it described an instance that the entry's own first sentence
says is fixed. The mechanism is what remains, and both defects are intact:
`update-non-apt.yml:221` `when: vault_svc.status.ActiveState != "active"` means a *running*
Vault is never restarted, and `:248` reports the version from `vault version` (the CLI, captured
at `:205`) rather than `vault status`, so the report cannot detect the drift it exists to catch.
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

### 3.2 ~~No etcd metrics, therefore no quorum-loss alerting~~ — **CLOSED 2026-09-04**

> Both halves done and verified. Three targets `health=up`, `etcd_server_has_leader=1`
> on all three, and fifteen built-in etcd rules now evaluating against real data.
>
> **The title's "therefore" was wrong, and that is the useful part.** The alerting was
> never missing: `defaultRules.rules.etcd` is on by default, so `etcdInsufficientMembers`,
> `etcdNoLeader` and thirteen others have been loaded and reporting `inactive` this whole
> time — against no data. **An `inactive` rule with no data and an `inactive` rule with a
> healthy cluster are indistinguishable from the rules API.** Nothing was broken, nothing
> was missing, and every status signal was green while quorum loss would have gone
> unremarked. What changed today is that those rules acquired something to evaluate.
>
> Same shape as §3.16's systemd collector and §3.14's retention: the machinery existed,
> looked healthy, and was pointed at nothing.

`docs/REVIEW-2026-07-24.md:306` (H26) — `kubeEtcd: enabled: false` on a 3-node HA cluster.
Losing one etcd voter is survivable and silent; losing two stops the cluster. Nothing
today reports the difference between three healthy members and two.

**THE OBVIOUS FIX IS WRONG, and this is the finding that scopes the work.** Setting
`kubeEtcd: enabled: true` in `monitoring.yaml` is not sufficient and must not be done
first. Measured on h4-core 2026-09-02, both curls run **from h4-core itself**:

    http://127.0.0.1:2381/metrics       -> 200
    http://192.168.1.160:2381/metrics   -> 000      <- its own LAN IP

Same host, two addresses. No network path, no second machine, no firewall in between —
so this is purely a bind-address fact: k3s binds the etcd metrics listener to loopback
only. Prometheus runs as a pod on n150-1 and cannot reach a loopback port on three
different machines. Enabling `kubeEtcd` alone would create a target that exists and
never scrapes, which reads as coverage on every dashboard. That is §3.16's shape and it
is worse than having no target at all.

(The first version of that test was going to be "curl from a different node", which
would have confounded binding with routing. Running both from the same box was
accidental and strictly better — it removes every variable except the one in question.)

**Estimate, revised.** This was called "a one-line Helm value plus alerts, about fifteen
minutes" earlier the same day. That was wrong. It is a control-plane change: an Ansible
config change plus a rolling restart of three etcd voters, then the monitoring side.
**2–3 hours**, in two halves that verify independently.

#### Half one — DONE 2026-09-02, applied via `playbooks/k3s-etcd-metrics.yml`

- [x] `etcd-expose-metrics: true` added to `k3s-h4.yml` and `k3s-ha-join.yml` so a
      rebuild keeps it. **Those plays write the config and do not restart k3s** — on a
      live server they change the file and nothing else until the next restart, which
      is why applying it needs its own playbook rather than a re-run.
- [x] `playbooks/k3s-etcd-metrics.yml` — `serial: 1` with `any_errors_fatal: true`
      across the three voters, each gated on a pre-flight health check that refuses to
      restart anything unless every node is Ready and `/healthz/etcd` says `ok`.

      The pre-flight gate asserts **`total >= 3`** as well as `notready == 0`,
      deliberately: a failed `kubectl` produces empty output, a bad-node count of 0,
      and a gate that passes on a cluster it never saw. Node count is the value no
      failed call can fabricate.

      The closing assert reads `etcd_server_has_leader` **from the node IP, never
      loopback** — one number that cannot be produced unless the listener actually
      moved *and* etcd is healthy. A check against 127.0.0.1 would have passed before
      any of this existed, which is the whole point.

- [x] **APPLIED 2026-09-02 to all three voters**, `n150-2` → `n150-1` → `h4-core`, one
      host per invocation with `--check` first. Every run `failed=0`, `ok=13`, and each
      closed with the assert reading the node IP:

          192.168.1.21   etcd_server_has_leader=1     (was http_code=000)
          192.168.1.42   etcd_server_has_leader=1     (was http_code=000)
          192.168.1.160  etcd_server_has_leader=1     (was http_code=000)

      The `--check` run behaved exactly as intended and is worth noting as a positive
      result: it reported `config WOULD be updated (check mode — no restart, nothing
      below is verified)` and skipped all six downstream tasks. A dry run that claims
      nothing is the point — this was written the day after a play was found asserting
      success during a run that changed nothing.

      **kube-vip VIPs bracketed by hand around `n150-1`**, which carries both. The
      playbook has no knowledge of them, so before and after:

          https://192.168.1.200:6443/healthz -> 401    (unchanged)
          http://192.168.1.201/              -> 404    (unchanged)

      Both are "alive" answers — auth required, and Traefik with no route for `/`.
      `000` on `.201` would have taken every service URL in the lab with it.

      k3s#6833 did not bite; the boolean flag was sufficient on `v1.36.2+k3s1` and the
      `etcd-arg: listen-metrics-urls` fallback was not needed.

      **Found while verifying this, unrelated to it: there is no Samba on the H4 at
      all** — see §6.13. A `systemctl is-active smbd nfs-server` added to confirm the
      restart stayed inside CLAUDE.md's NAS boundary returned `inactive`, which meant
      "not installed" rather than "stopped". The boundary was respected; the
      documentation describing it was wrong.

#### Half two — WRITTEN 2026-09-04, NOT YET VERIFIED

Half one left the lab with **an open metrics port and no consumer** — a deliberate
intermediate state, recorded so it could not later be mistaken for an abandoned one.
It held: re-checked 2026-09-04, `etcd_server_has_leader=1` on all three node IPs, two
days after the rolling restart and with nothing scraping them.

- [x] `kubeEtcd` in `gitops/apps/monitoring.yaml` configured **explicitly**. Every value
      is load-bearing because the chart's defaults describe kubeadm, not k3s:

          default                     k3s reality
          -------------------------------------------------------------
          port 2379                   metrics are on 2381, not the client port
          https + client certs        2381 is plain HTTP, no client auth
          selector on kube-system     embedded etcd runs INSIDE the k3s process;
            etcd static pods            there is no etcd pod to select

      Left at defaults this yields a ServiceMonitor with no endpoints and a target that
      never scrapes — which renders as coverage. Worse than `enabled: false`, which is
      at least honest about what it does not watch.

      `endpoints` is hardcoded because there is no Service to discover; the chart builds
      an Endpoints object from the list. **That makes it a second place the control-plane
      node IPs are written down**, after `inventory/hosts.yml`, with nothing enforcing
      agreement. Checked mechanically at write time — the three are a subset of the
      inventory's `node_ip` values — but adding or replacing a server node means editing
      both, and only the target count will notice a missed edit.

- [x] **Verified 2026-09-04.** The Endpoints object carried all three addresses, and
      after one scrape interval:

          targets   http://192.168.1.160:2381/metrics  health=up
                    http://192.168.1.42:2381/metrics   health=up
                    http://192.168.1.21:2381/metrics   health=up
          count(etcd_server_id)          = 3
          count(etcd_server_has_leader)  = 3
          count(up{job=~".*etcd.*"})     = 3
          rules     15 etcd rules loaded, all inactive

      **The first read said `NO DATA`, 26 seconds after the Endpoints object appeared,
      and that was simply too early** — config reload plus one scrape interval. It was
      not investigated as a fault, because the identical early read on §3.3's blackbox
      Application two days earlier already cost a round trip.

      **Use `/api/v1/targets`, not a metric query, when asking whether scraping works.**
      A metric query returning nothing conflates three different states — target absent,
      target failing, wrong metric name — while the targets API reports the scrape URL,
      health and `lastError` verbatim. That distinction was live here: `etcd_server_id`
      was chosen from memory and its `NO DATA` could equally have meant the metric does
      not exist on this etcd version. It does (3), but the check was ambiguous until the
      targets API disambiguated it.

      `count(etcd_server_id) = 3` is the standing detector for the endpoints/inventory
      divergence noted above — a server node added to `hosts.yml` and not here shows up
      as a 3 that should have become a 4, and nothing else would notice.

- [x] The silent-failure risk was real but did not materialise: a wrong `endpoints` list
      gives a green Argo Application and a target that never scrapes. `up == 0` and a
      missing series look different in Prometheus and identical on a dashboard, which is
      why `up` was read explicitly rather than inferred from an empty graph.

### 3.3 ~~Nothing verifies that DNS actually resolves~~ — **BUILT AND VERIFIED 2026-09-02**

> Applied via #547. All four checks passed, in the order that makes them mean something:
>
>     Service name          blackbox-exporter-prometheus-blackbox-exporter   (matches the
>                           string hardcoded in all four Probes)
>     Probes                4
>     Series                count(probe_dns_answer_rrs{job=~"dns-.*"}) = 16
>     Rules loaded          6 of 6, all inactive
>     probe_success         16 of 16 = 1
>
> **The control is the result that matters**, and it was run before believing any of the
> rest: the same module against a real resolver and against 1.1.1.1, which cannot know
> `api.lab.home.arpa`:
>
>     real resolver (want 1): probe_success 1
>     cloudflare    (want 0): probe_success 0
>
> Green on arrival proves only that Prometheus is scraping something. `1` then `0` proves
> the answer assertion is actually applied — the difference between six working rules and
> six decorative ones, and not visible from any dashboard.
>
> A first read reported the Application NotFound. That was an early read, not a defect:
> `root` reported `Synced 677f48d` moments later and the child appeared. Recorded because
> the reflex to debug a pipeline that has none cost an hour on 2026-08-26.

`docs/REVIEW-2026-07-24.md:306` (H29) — no blackbox exporter, so
`api.lab.home.arpa` and `*.apps.lab.home.arpa` failing to resolve is invisible.
DNS is the lab's most load-bearing dependency.

**Why this was next.** `CLAUDE.md` names DNS load-bearing and instructs "suspect DNS
before the cluster". On 2026-07-27 a single wildcard A record took down every service
URL in the lab. §4.12 was a resolver fault that ran for months. Four resolvers, one
documented total outage, a standing rule to check DNS first — and nothing measuring
any of it. Everything else open has a narrower blast radius.

**What was written** (PR pending; nothing applied yet):

- `gitops/apps/blackbox-exporter.yaml` — chart 11.17.2, four `dns` modules.
- `gitops/workloads/monitoring/dns-probes.yaml` — four `Probe` CRs × four resolvers
  = 16 series. Picked up by the `monitoring-config` Application, which syncs
  `gitops/workloads/monitoring` (that path is *excluded* from `workloads-appset` —
  checked, because a file that nothing syncs is §3.11 all over again).
- `lab.dns` group in `lab-alerts.yaml` — six rules.

**The design point worth remembering.** Every module asserts the **answer**, not the
response. In July, rpi4b was up, fast, and handing out `192.168.1.160`; a probe that
checked only "did DNS reply" would have been green throughout the outage it exists to
catch. So severity is assigned by *kind of failure*, not by count:

| condition | severity | why |
|---|---|---|
| wrong answer, even one resolver | critical | clients don't fail over from a wrong answer — they use it |
| no answer, one of four | warning | redundancy lost, clients fail over |
| no answer, all four | critical | lab-wide; four boards don't fail together — suspect a `dns.yml` run |

`probe_dns_answer_rrs` is what separates "never replied" from "replied wrongly".

There is also a `fail_if_matches_regexp` on `192.168.1.160` alongside the
`fail_if_not_matches_regexp` on `.201`. Not redundant: the latter passes if *any*
answer RR matches, so a resolver returning `.201` **and** a stale `.160` — which fails
intermittently and is miserable to diagnose — slips through it and not through the pair.

**Verification, none of it done yet.** In order, and the third is the one that matters:

1. Service name. The Probe CRs hardcode
   `blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc:9115`.
   `fullnameOverride` was deliberately **not** used — it is undocumented in this
   chart's `values.yaml`, and Helm discards unknown value keys silently (§3.9, the
   Alloy journal mount that never existed while Argo said Healthy). Confirm the
   generated name: `kubectl -n monitoring get svc | grep blackbox`.
2. The series exist at all: `count(probe_dns_answer_rrs{job=~"dns-.*"})` → want **16**.
   If it returns nothing, four of the six rules are silent rather than broken, which
   is §3.16's failure mode exactly.
3. **Prove a probe can go red.** Green on arrival proves only that Prometheus is
   scraping something. Temporarily change `dns_api_vip`'s expected address to one that
   is wrong, watch `probe_success` go 0 and `LabDNSWrongAnswer` fire, then revert. Per
   the house rule, this control has twice produced findings of its own — and here it is
   the only thing that distinguishes a working alert from an alert whose regexp never
   matches anything.

**This settles §4.12's open `.217` question as a side effect.** Three places in the
repo describe the resolver fleet and they disagree: `CLAUDE.md` lists `.148`/`.116`/
`.184` and does not have `.217` serving DNS at all; `monitoring.yaml` calls `.217`
"DNS quaternary, dnsmasq"; `hosts.yml` gives `.184`, `.116` **and** `.217` all
`dns_role: secondary`. All four are probed. Within a minute of the first sync,
`probe_success{instance="192.168.1.217:53"}` says whether it answers authoritatively
for `lab.home.arpa`. Whichever way it lands, two of those three descriptions are wrong
— record the answer in §4.12 rather than leaving the disagreement standing.

**What this does NOT cover**, so a green dashboard isn't over-read: it queries each
resolver **by IP**, so it tests the resolvers, not whether any client is configured to
use them — §4.12 was precisely that class of fault and this would not have caught it.
No ICMP (chart drops `ALL` capabilities; reachability is `LabExternalHostDown`'s job).
No HTTP probes — H29's other half, cert-manager expiry, is separate work, and an
unused module shipped "for later" is a thing that rots.

### 3.4 ~~`LabBackupEtcdSilent` may fire permanently against a weekly timer~~ — **FIXED, confirmed 2026-08-21**

`ansible/templates/backup-etcd.timer.j2:11` is `OnCalendar=*-*-* 00:30:00` — daily, with an
inline note that the old Sun 03:00 slot collided with `backup-cloud`. The alert threshold is
90000s (25h) at `lab-alerts.yaml:129-137`, so daily plus `Persistent=true` clears it with an
hour of margin. Corroborated by `healthchecks.yml:12`.

The entry said "possibly fixed; verify" for weeks. Resolving that ambiguity took one look at
the timer.
`docs/REVIEW-2026-07-24.md:306` (H27) — *possibly fixed; verify the timer cadence
against the 25h threshold.*

### 3.5 A CronJob that has never succeeded is invisible
`gitops/workloads/monitoring/lab-alerts.yaml:262-269` — `LabCronJobStale` keys off
`kube_cronjob_status_last_successful_time`, which does not exist until the first success.

**2026-08-26:** this is the obvious explanation for the 15-day lldap backup gap (§1.12),
and it remains **unproven** — the metric history that would confirm or refute it has been
evicted (§3.14). Recorded here so the next person does not mistake a plausible fit for a
diagnosis. The fix is worth making on its own merits either way; the sketch is already in
the rule's comment (`kube_cronjob_info unless on(namespace, cronjob) …`).

### 3.14 Prometheus evicts well inside its nominal 30-day retention

**Found 2026-08-26.** `gitops/apps/monitoring.yaml:156-157` sets `retention: 30d` and
`retentionSize: "15GB"`. Whichever limit is reached first wins, and **`retentionSize` is
winning by a wide margin**: a query for `up` at ~2026-08-11 — fifteen days back, half the
nominal window — returned an empty vector. There is no data at all before roughly two
weeks ago.

This was found by running a control query, not by looking for it. An empty result for
`kube_cronjob_status_last_successful_time` mid-August was about to be recorded as proof
that §3.5's blind spot caused the §1.12 lldap gap. Querying `up` at the same instant
returned empty as well, which meant the first query had proved nothing.

**Why it matters beyond the one investigation:** `30d` appears in the config, in the docs
and in everyone's head. The actual answer to "what did this look like two weeks ago" is
*nothing*. Any post-incident analysis reaching back further than about a fortnight will
silently return empty vectors that look like healthy zeroes or absent series — and an
empty result from Prometheus is indistinguishable from a metric that never existed.

**To do:**

- [x] **Measure the real horizon** — done 2026-09-02, and Prometheus keeps counters
      that answer it outright rather than by inference:

          prometheus_tsdb_size_retentions_total   19
          prometheus_tsdb_time_retentions_total    0     <- NEVER fired
          prometheus_tsdb_storage_blocks_bytes    12.2 GiB
          prometheus_tsdb_retention_limit_bytes   15 GiB  ("15GB" is parsed BINARY)
          lowest_timestamp 1787119200 vs now 1788357374 = 14.33 DAYS

      `retention: 30d` had never evicted a single block. The number in git was
      decorative for as long as it has existed.

      **CORRECTION 2026-09-04 — "NEVER fired" overstates what those counters can
      say.** Re-read two days later they were BOTH zero:

          prometheus_tsdb_size_retentions_total    0     (was 19)

      A counter cannot decrease. It reset because Prometheus restarted when Argo
      applied the `30d -> 15d` change — so these two only ever mean "since the last
      restart", and this pod restarts on every `monitoring.yaml` merge.

      **The conclusion above still holds**, because both figures were read in the
      same process lifetime: 19-against-0 in one window is real evidence that size
      bound first and time never did *in that window*. What does not hold is the
      absolute reading. On a pod that restarts weekly the counters can never
      accumulate enough to support "never once", and anyone re-running the query to
      confirm this entry would find two zeros and no way to tell a healthy TSDB from
      one that has just been restarted.

      **Use the horizon instead — it survives restarts, because the blocks do:**

          (time() - prometheus_tsdb_lowest_timestamp_seconds) / 86400

      Measured 2026-09-04: **16.57 days**, against a config that now says 15d.

      That reads as "over the limit" and is not. Prometheus deletes whole blocks, and
      a block survives until its *newest* sample ages out — so a healthy TSDB sits
      slightly ABOVE its nominal window by up to one block width. The 1.57-day
      overshoot is consistent with blocks laid down under the old 30d config, which
      permitted wider ones. It also confirms nothing has evicted since the restart,
      exactly as the two zeros say.

      **So the direction of the error has flipped, which is the outcome §3.14 wanted.**
      Before: config claimed 30d, reality gave 14.33 — git promised more than the
      system delivered. Now: config claims 15d, reality gives 16.57 — the config is
      conservative. `LabPrometheusRetentionShort` fires below 12d and is comfortably
      clear. Two days is not enough to say where it settles once size binds again;
      re-read the horizon, not the counters, in a fortnight.
- [x] **Made the config honest** — `retention: 30d -> 15d` 2026-09-02. Lowering was the
      only option available today; raising `retentionSize` has nowhere to go. Measured
      on n150-1:

          /              65G total, 44G used, 18G avail (71%)
          Prometheus PV  13G      Loki PV  12G      <- 25G of the 44G used
          VG free        7.89G

      Nothing was reduced in capability: the change makes git describe the system
      instead of contradicting it.
- [x] **Alert added** — `lab.prometheus-retention` in lab-alerts.yaml, 2026-09-02.
      `LabPrometheusRetentionShort` fires when the horizon drops under 12d (2.3 days of
      margin below today's 14.33), plus `LabPrometheusRetentionMetricMissing` on
      `absent()`, because a rule on a gauge cannot fire when the gauge is gone. Ships
      green — checked before merging, per the §3.11 rule about alerts that arrive
      already firing.
- [x] **`docs/LEDGER-DESIGN.md` corrected** 2026-09-02, in §3.3 where it says metrics
      are out of scope because "Prometheus has them". It now records that this means 14
      days rather than 30. That sharpens the case for the ledger rather than weakening
      it — §5's example query ("which claimed-DONE items have no supporting ledger event
      in the last 30 days?") cannot be answered from Prometheus at all.

**REMAINING, both opened by this work:**

- [x] **Loki claims 30 days and nobody has checked it** — **CHECKED 2026-09-02, and
      unlike Prometheus the claim is now true.** The prior was poor and deserved to be:
      `30d` was decorative here too until the compactor was enabled the same day.

          Loki PV      12 GB  ->  4.4 GB
          July window  0 results          (2026-07-01..07-10, limit 1)
          control      1 result           (last 1h, same query)

      The control ran first and is why the second line means anything. An empty Loki
      response and a malformed query are indistinguishable, and this exact confusion —
      a control query for `up` coming back empty at the same instant as the query under
      investigation — is how §3.14 was found in the first place.

      **The first attempt at this check was the wrong check, and it is worth recording
      why.** `find -printf '%T+' | head -1` on the PV returned `2026-07-04`, unchanged,
      which read as "retention deleted nothing" while the size had in fact dropped by
      7.6 GB. Oldest *file mtime* is a filesystem fact; retention is about what Loki
      will *return*. The stale timestamp is a bootstrap artifact — a WAL or index file
      written at PV creation and never rewritten — and no amount of chunk deletion
      moves it. Same failure as reading `resolvectl` when the kubelet reads
      `resolv.conf` (§4.12): check the artifact the consumer reads.

      `LEDGER-DESIGN.md` needs no correction on this row after all — 30 days for Loki
      is now accurate. Note the asymmetry with Prometheus directly above: there the fix
      was to lower the config to match reality (15d), here it was to make reality match
      the config. Both were `30d` that meant nothing; they were not the same defect.
- [ ] **302 GB sits idle in `vm-storage` while retention is disk-bound.** Measured
      2026-09-02: the LV is 400 GB, `/var/lib/libvirt/images` holds 72 GB (one 71 GB
      gitlab-1 qcow2, fully allocated), 20% used. Reclaiming even 100 GB into
      `ubuntu-lv` would let `retentionSize` rise and take the horizon back toward 30d
      for real. **This is an `lvreduce` on a mounted ext4** — stop gitlab-1, `e2fsck`,
      `resize2fs` shrink, `lvreduce`, then `lvextend` the root LV. It is the one
      operation in this area that destroys data if a step is skipped or ordered wrong.
      A deliberate maintenance window, not a config change.

### 3.15 ~~The H4's node-exporter pod crashlooped for 19 days~~ — **FIXED 2026-08-27**

`monitoring-prometheus-node-exporter-fmxwl` was in CrashLoopBackOff for **19 days**, 273
restarts, firing `KubePodCrashLooping` and `KubeDaemonSetRolloutStuck` throughout. One log
line was the entire diagnosis:

    listen tcp 0.0.0.0:9100: bind: address already in use

`ss -lntp` named the holder: `prometheus-node`, PID 986, the **Debian
`prometheus-node-exporter` package** running as a host service from boot. It is not in the
`node_exporter` inventory group — cluster nodes are meant to get metrics from the
DaemonSet — so it was unmanaged drift, most likely a MicroShift-era leftover.

**Scope correction, added after the fix ran: the package was on all three x86 cluster
nodes**, not just the H4 — `state: absent` reported `changed` on `h4-core`, `n150-1` and
`n150-2` (the two opi5pro agents were clean). The N150s' pods were healthy, so their copy
of the unit must have been losing the boot race quietly and sitting failed or disabled.
The H4 is simply where the host service won the port and the condition became visible.
**A 19-day crashloop was the loud instance of a silent condition on three machines** — and
the original wording here implied an H4-only problem, which is the same tense-and-scope
error that made the `.99` comment in `gitops/apps/monitoring.yaml` misleading a month
after it was written.

Confirmed after the run: all five cluster nodes show `node_exporter` (the DaemonSet
binary) on 9100, and every external scrape target is `up` except `.184` and `.99`, which
are physically down.

**This was already written down, about a different host.** The comment excluding
`gitlab-1` from the `node_exporter` group describes the identical collision: "GitLab
Omnibus ships its own node_exporter already bound to 127.0.0.1:9100, so the Debian package
can't bind 0.0.0.0:9100 and its unit dies on start." Same conflict, opposite winner, and
nobody connected the two for nineteen days.

**Two beliefs it corrects:**

- It was recorded as "a monitoring blind spot on the most important host." It was not —
  the host package was serving metrics the whole time, including `node_systemd_*`. The
  cost was 19 days of alert noise, not missing data.
- The 2026-08-02 and 08-07 DaemonSet work (D-Bus socket mount, `appArmorProfile:
  Unconfined`, widening `--collector.systemd.unit-include`) was justified on the grounds
  that "backup-nas.timer and backup-etcd.timer exist only on odroid-nas." Those series were
  coming from the **host package**. That work was right for the other nodes and was never
  what delivered the H4's timer metrics.

**Verified before removing, and the control is the point.** With the host unit stopped and
the pod deleted to clear its 5-minute backoff, the pod reached `1/1 Running` in 25 seconds
and returned **52** `node_systemd_unit_state` series. The control on n150-1 returned **0** —
correct, because the collector is scoped to `backup-.+\.(service|timer)` and those units
exist only on odroid-nas. Without running the control, 52 was a number with no scale and 0
would have looked like failure.

A first attempt at this test returned 0 on the H4 and proved nothing: the host unit was
stopped and the pod had not yet retried through its backoff, so **nothing was listening at
all**. The check had two ways to produce a zero and only one was accounted for.

**Fixed** in `ansible/playbooks/node-exporter.yml` — a new play removes the package from
`k3s_server:k3s_agents`, then verifies by what is *listening* rather than by what the
package manager said, and warns by name if a host process holds 9100 on a cluster node.

- [ ] Run it, then confirm the H4 target is `up` in Prometheus and
      `node_systemd_unit_state{name=~"backup-.+"}` still has series — those feed
      `LabBackupUnitFailed` on the one host where backups run.

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

### 3.11 Nothing reconciles Ansible, and nothing reports the drift

**Found 2026-08-21**, incidentally, while applying §1.4. Running `storage.yml` produced
an unrelated diff:

    -Docs=file:///.../ARCHITECTURE.md
    +Documentation=file:///.../ARCHITECTURE.md
    +Before=lvm2-monitor.service microshift.service

The deployed `microshift-lvm-loop.service` on the H4 was **older than the template in
git**. Commit `68d6320` ("idempotent loop device service") fixed two things — `Docs=`
is not a valid systemd directive and does nothing, and the missing `Before=` meant LVM
could begin scanning before `/dev/loop100` was attached — and the fix sat merged and
unapplied for an unknown period.

**This is structural, not a one-off.** Argo CD reconciles the cluster continuously with
`selfHeal`, so a merged manifest reaches the cluster within ~30 seconds whether anyone
is watching or not. **Ansible reconciles nothing.** A merged host-layer change takes
effect only when a human remembers to run the playbook, and no check anywhere reports
the gap. The repo's whole mental model — "change it in git and it happens" — is true of
one layer and false of the other, with no marker at the boundary.

The boot-ordering fix is the illustrative case rather than the worst case: it is
invisible until a reboot, and the H4 has a reboot pending from §4.12.

**Second instance, 2026-08-27 — and the victim was the ledger.** A `--check` of
`backup.yml`, run to verify the §1.7 restic hold, reported `backup-nas.service` as
`changed`:

    ExecStart=/usr/bin/restic backup /srv/nas \
      /mnt/cold-8t/immich \
    + /var/lib/lab-ledger \

`/var/lib/lab-ledger` entered the template with PR #474 at **15:09**; the live unit did
not have it at **17:00**. Hours, not weeks — so this is a near miss rather than a hole,
and it is recorded as one. But nothing was going to close it: the next `backup-nas` at
01:30 would have run without the ledger, successfully, and reported success.

Three things make it worth an entry rather than a footnote:

- **It was found by accident**, during a `--check` run for an unrelated item. The
  detection method was luck, which is the same detection method as §1.12 and §3.15.
- **The gap is invisible from either side.** Git says the ledger is backed up. The
  timer says the backup succeeded. Both are true statements about different objects.
- **The ledger is the one file designed to outlive everything else.** The template's own
  comment argues it: a ledger that records backup outcomes and is not itself backed up
  is the first thing lost in the incident it exists to explain. That was the live state
  for two hours, on the day the ledger was built.

Applied the same day; `changed=2` (the hold, and the unit). This is the concrete cost
case for the scheduled `--check` below — the run that found it took under a minute.

**BUILT 2026-08-29.** `ansible-drift-check.sh` + a weekly timer on h4-core, publishing
`lab_ansible_drift{playbook}` through the node_exporter textfile collector. 23
steady-state playbooks checked, 8 knowingly skipped and published as
`lab_ansible_drift_skipped` so the coverage gap is visible next to the results.

**First run found 13 drifted hosts across 5 playbooks**, none of which anything would
have reported: `k3s-registry` 4, `node-dns` 4, `shared-storage` 3, `mqtt` 1,
`h4-dns-resolvers` 1. Plus 3 playbooks that cannot complete `--check` at all
(`home-assistant`, `k8s-secrets`, `mount-nvme`).

- [x] **Run every playbook in `--check` on a schedule.** Sunday 05:00, `Persistent=true`.
- [x] **The check-mode honesty prerequisite**, for the in-scope set. Five playbooks were
      fixed (`chrony`, `zswap`, `ai-nodes`, `github-runner`, `shared-storage`); a static
      audit of `command`/`shell` tasks with consumed registers now returns zero.
      `github-runner.yml` then revealed a class the audit could not see — a `get_url`
      no-op cascading into `unarchive` — so it was dropped from the checked set as
      one-shot provisioning rather than fixed.
- [x] **What the report does:** three metrics, because the states want different
      responses. `lab_ansible_drift` (hosts changed), `lab_ansible_check_failed` (the
      check could not run — NOT the same as zero drift), and
      `lab_ansible_drift_last_run_seconds`. The third is the one that matters: without
      it a dead timer freezes every other gauge at its last reassuring value, which is
      precisely what `LabBackupEtcdSilent` exists to catch on the backup timers.

**A third property nobody had named: check-mode ACCURACY.** Honesty is "the play
completes a dry run". Accuracy is "and what it reports is true". A task can be perfectly
honest and still lie.

`k3s-registry`'s *Add ansible user to docker group* reported `changed` on every run.
`getent group docker` on h4-core returns `docker:x:124:swares` — the user was already a
member. `ansible.builtin.user` with `append: true` cannot determine supplementary group
membership under `--check` and reports changed regardless. Fixed by reading the group
first and gating the task, but the general problem is bigger than one task:

**A permanently-wrong `changed` puts a non-zero FLOOR under the drift metric**, and an
alert that can never go green is an alert that gets ignored. `lab-alerts.yaml` already
records `LabExternalHostDown` firing for three weeks against a decommissioned VM and
training the eye past it. So the alert rules are deliberately NOT written yet.

- [x] **Drive the floor to zero before alerting.** Done 2026-08-30.
      **The diagnosis written above was WRONG and is left in place as the record.**
      `h4-dns-resolvers` did *not* report 1 "by design"; the deliberate
      write-without-apply had nothing to do with it. Its netplan tasks reported `ok`
      throughout — the config on disk already matched git. The entire drift was one
      task backing up the cloud-init netplan to
      `…50-cloud-init.yaml.bak-{{ ansible_date_time.date }}`, whose `force: false`
      ("never clobber an existing backup") was defeated by a **destination path that
      moves every midnight**. There was never an existing backup to protect. No DNS
      decision was required and no baseline exclusion was needed.
- [x] **Audit the checked set for accuracy, not just honesty.** Answered empirically
      rather than statically: all 21 covered playbooks now report 0 against real hosts
      (commit `98be83e`), which is a stronger result than an audit — a permanently-wrong
      `changed` cannot hide in a set that sums to zero.
- [x] **Then write the alert rules.** Done 2026-08-30, group `lab.ansible-drift` in
      `lab-alerts.yaml`, and only after the floor hit zero. Four rules, not three:
      `LabAnsibleDrift`, `LabAnsibleCheckFailed`, `LabAnsibleDriftStale` (>10 days on a
      weekly timer), and `LabAnsibleDriftMetricMissing` — `absent()`, because a rule on
      a gauge cannot fire when the gauge stops existing. Verified before merge that
      Prometheus was already scraping the series from `192.168.1.160:9100`, so the
      alerts would not arrive pre-firing.

**CLOSED 2026-08-30. 21 playbooks, 0 drift, 0 check failures, 4 alerts watching.**

**The finding that matters is what it found.** All seven items the check surfaced were
**broken automation, not drifted hosts** — the opposite of what this entry was written
to catch:

| playbook | what it actually was |
|---|---|
| `home-assistant` | used `community.docker`, undeclared in `requirements.yml` — never parsed, ever. Would have installed Docker + a second HA onto rpi4b, the **live Pi-hole secondary DNS**. HA has run in k3s for 50 days. Deleted. |
| `k8s-secrets` | templated `authelia_storage_pg_password`, commented out in the vault file. `failed_when: false` does not rescue a *templating* error and `no_log: true` censored it. Same defect as `zot_admin_password` (2026-08-09). |
| `mount-nvme` | check-mode cascade hiding `changed=3`/`changed=2`; its Ollama half described a host install that moved into k3s. |
| `mqtt` | could not be run without accepting an unattended `pacman -Syu` on a rolling distro. |
| `github-runner` | one-shot provisioning, miscategorised. |
| `shared-storage` | `ansible_date_time.iso8601` in file **content** + the play deleted the file it then read back. |
| `h4-dns-resolvers` | `ansible_date_time.date` in a backup **filename**. |

Two consequences worth carrying forward:

1. **Both floor items were the same bug: a date rendered into a path or a payload.**
   If a newly-covered playbook pins the gauge at a constant non-zero, look for a
   timestamp before looking for a drifted host.
2. **Non-zero drift is not a licence to apply.** Three of four non-zero readings meant
   *git* was wrong. `mount-nvme.yml` would have stripped `nofail` from a headless SBC's
   fstab and replaced a UUID with a device path — to add one `noatime` it was missing.
   The alert annotation says this in as many words.

Both permanent-`changed` bugs were also **masking a real defect underneath**, which is
the argument against tolerating a non-zero floor rather than merely disliking it:
`shared-storage`'s NFS round-trip assertion had **never once passed** — it read a file
the play deleted at the end of every real run, failing silently into `failed_when: false`
— and `h4-dns-resolvers` was re-defining "the original" every day it ran, so only the
earliest dated backup held the pristine file. Both now verified: the round-trip prints
real content, and `50-cloud-init.yaml.orig` is the 164-byte Jun 24 file that still
contains the `nameservers` block.

**Its yield should now fall.** The check was built to answer "have the hosts diverged
from git" and mostly answered "which of your playbooks are fiction". That backlog is
finite, and a quiet weekly run will start meaning something once it is cleared.

### 3.16 The systemd collector exports ONLY backup units, so every other failed unit is invisible

**Found 2026-08-30**, by the drift check's first run finding a service that had been dead
for 37 days.

`gitops/apps/monitoring.yaml` scopes node_exporter's systemd collector:

    --collector.systemd.unit-include=backup-.+\.(service|timer)

So `node_systemd_unit_state` exists for backup units **and nothing else**, on any of the
13 hosts. `LabBackupUnitFailed` can only ever fire on those. This is not a rule that fails
to match — **the series does not exist**, which is a different and worse thing, because
no query can be written that would find the problem.

That narrowing was deliberate on 2026-08-07 and correct at the time: the regex was widened
*from* `(backup-nas|backup-etcd)` because backup-cloud, backup-verify and backup-offsite
produced no series at all. Nobody wrote down what stayed excluded, which is everything.

**The instance that exposed it.** `nfs-server` on `n150-1`:

    Active: failed (Result: exit-code) since Fri 2026-07-24 06:12:26 UTC; 1 month 7 days ago
    Duration: 2d 23h 16min 11.488s

It ran for three days after `shared-storage.yml` configured it, exited `1/FAILURE` once,
and stayed down for **37 days**. `/srv/libvirt-shared` was therefore unmounted on
`n150-2` the whole time, both libvirt pools were degraded, and **live migration between
the two KVM hosts was impossible** — on the pair that runs `gitlab-1`. Nothing alerted,
because nothing could.

**The cause is unrecoverable.** `journal has been rotated since unit was started` →
`-- No entries --`. Three timestamps and an exit code are the entire surviving record,
exactly as in §1.12. The service started cleanly on 2026-08-30 with no error, so the
failure was transient rather than structural.

**Why it lasted 37 days rather than until the next boot:** the host has **62 days of
uptime**, and `nfs-server.service` carries no `Restart=` policy. One transient failure is
therefore permanent until a human intervenes. The unit was `enabled` throughout, which
looks reassuring in `systemctl list-unit-files` and means nothing about whether it is
running.

**Three fixes — ALL THREE DONE 2026-08-30.** They turned out not to be independent:
the fleet sweep produced the cardinality number the collector decision needed.

- [x] **Widen the collector.** Done — to a NAMED SET, not `.+`:
      `(backup-.+|ansible-drift-check|nfs-server|k3s|k3s-agent|containerd|docker|libvirtd|mosquitto)\.(service|timer)`
      Every name was measured to exist and to be healthy first, so the new alert ships
      green. Verified in Prometheus afterwards: `nfs-server.service` now returns series
      — the first time in this lab's history that a query could have found the outage
      this entry is about.
- [x] **Give `nfs-server` a `Restart=on-failure` drop-in.** Done, `RestartSec=10s`,
      **scoped to n150-1 only**. h4-core also runs `nfs-server` with `Restart=no` and
      that one is THE NAS — CLAUDE.md forbids reconfiguring it. Verified with a
      negative control after applying: n150-1 reports `on-failure` with
      `/etc/systemd/system/nfs-server.service.d/10-restart.conf` in `DropInPaths`,
      h4-core still reports `no` with only its generator drop-in. The play asks
      systemd (`systemctl show -p Restart`) rather than checking the file exists,
      because a drop-in not ending in `.conf`, or with a malformed section header, is
      silently ignored — the file is there, the copy reports `changed`, and the policy
      is still `no`.
- [x] **Fleet-wide `systemctl list-units --failed` sweep.** Run for the first time.
      Results below.

**THE CARDINALITY ESTIMATE IN THE ORIGINAL ENTRY WAS RIGHT TO WORRY AND WRONG ON THE
NUMBER.** Measured: 3,430 systemd units across the 13 real hosts, so `.+` would be
~20,600 series *if the fleet had been at `backup-.+` everywhere*. **It was not.** The
H4 and cluster nodes run the DaemonSet with the regex; rpi5, rpi4b, octopi-dns and the
Zero 2Ws run the Debian `prometheus-node-exporter` package with `ARGS=""`, whose
systemd collector defaults to `unit-include=".+"`. **Half the fleet has been exposing
every unit all along.** The change therefore cost only the five DaemonSet nodes,
~180 series.

That mistake had a consequence worth keeping: **the alert's name filter is
load-bearing, not defensive.** `LabSystemdUnitFailed` is scoped by unit name rather
than left open, because an unscoped `state="failed"` rule would have fired on arrival
against `smartmontools`, `nvmf-autoconnect`, `openipmi` and `systemd-remount-fs` on the
already-open hosts — no matter what the DaemonSet regex said. The collector regex
controls what exists; the rule's name filter controls what pages.

**And a hypothesis measured and killed, so nobody re-proposes it:** if half the fleet
exposes every unit, is the systemd collector a meaningful part of §3.14's retention
shortfall? **No.** `count(node_systemd_unit_state)` = **3,580** against
`count({__name__!=""})` = **334,102** — **1.07%**. Narrowing those hosts' `ARGS=""`
would reclaim about one percent. §3.14's cause is elsewhere.

**THE SWEEP'S OWN FINDINGS — ALL FIVE RESOLVED 2026-08-30.** Four were systemd
bookkeeping; one was a real bug two years old.

| host | unit | what it was | outcome |
|---|---|---|---|
| opi5pro-2 | `zswap-config.service` | artefact of `ansible/roles/zswap/` — an ORPHAN role invoked by no playbook | role **deleted**, unit removed, failed state cleared |
| opi5pro-1 **and** -2 | `dnsmasq.service` | arrived via dnsmasq-base/resolvconf as a dependency, enabled by package default, failed since 2026-07-19 and 07-29 | **disabled + reset-failed** in `node-dns.yml`, gated on measured failure |
| gitlab-1 | `prometheus-node-exporter.service` | package not installed, no unit file anywhere — a failure record with nothing behind it | `reset-failed` |
| h4-core | `prometheus-node-exporter.service` | deliberately **masked to /dev/null** 2026-08-27 because the k8s DaemonSet owns :9100 (confirmed listening) | `reset-failed` |
| opi-zero2w-1, -2 | `systemd-remount-fs.service` | **REAL BUG** — malformed fstab | repaired and **proven** |

**THE ORPHAN ROLE IS THE MOST IMPORTANT OF THESE**, because it explains six of the
eight OPi 5 Pro divergences unpicked in §3.11 the same evening. `roles/zswap/` created
the 8 GiB swapfile with `dd`+`mkswap`, added its fstab record, deployed
`zswap-config.service`, and ran **`swapoff /dev/zram0`** under `zswap_disable_zram` —
whose own default comment reads "Set true on hosts that use zram for swap (OPi 5
Pros)". Its attempt to disable the zram service named `zram-generator` and
`systemd-zram-setup@zram0`, which are Fedora/Arch units; these boards use
`orangepi-zram-config`, so that half failed silently under `failed_when: false`,
leaving the service enabled to keep re-creating a device nothing then swapped on.

Nothing invoked the role, so it was invisible to §3.11's drift check — **`--check` can
only run playbooks; an orphan role stays armed indefinitely.** That is a third category
beyond "broken automation" and "drifted host": automation outside the checker's reach.
`roles/` now contains only `cups_printer`, which `playbooks/printer.yml` does invoke.

**THE FSTAB BUG.** `opi-zero2w-1` and `-2` share one cloned card (identical PARTUUID
`5910ca3d`) whose root line is missing the fstype column:

    PARTUUID=5910ca3d-02   /        defaults    0   1     <- five fields, needs six

`mount` therefore reads `defaults` as the TYPE and `0` as the OPTIONS:

    mount: /: fsconfig() failed: ext4: Unknown parameter '0'

**It went unnoticed since 2024-07-06 — two years — because the boards work.** The
kernel mounts root `rw` from the boot cmdline before fstab is consulted, so `touch`
succeeds and nothing visibly breaks. What silently does not work is the remount: any
option ever added to `/` would never apply. Fixed by
`playbooks/fstab-root-fstype.yml`, which is gated on the field COUNT rather than a host
list (so a re-flashed clone self-repairs), backs up first, and **proves the fix by
restarting the very unit that was failing** rather than by asserting the file looks
right — the only check that works without rebooting a headless board.

**THE ELEVEN REMAINING FAILURES, and the decision about them.**
`playbooks/mask-inapplicable-units.yml` masks units whose hardware provably does not
exist — `smartmontools` (SD/eMMC/virtio implement no SMART), `openipmi` (no
`/dev/ipmi*`), `nvmf-autoconnect` (no NVMe-over-Fabrics; unrelated to the OPi5s' local
NVMe). Masked rather than disabled, because `disable` only removes [Install] symlinks
and a dependency or a package upgrade re-enables it.

Gated on **proven hardware absence AND the failed state together** — "it is currently
failing" alone would suppress a genuinely broken monitor on a box that does have SMART.

Three are deliberately left failing:

- `systemd-networkd-wait-online` — **RESOLVED 2026-08-31** by
  `playbooks/network-online-wait.yml`, and it was TWO different faults, not one:

  **n150-1 / n150-2.** netplan had ALREADY scoped the wait — my prediction that
  `--interface=br0` was missing was wrong. Its generated drop-in waits for BOTH links:
  `-i br0:degraded -i enp1s0:carrier`. `enp1s0` is a bridge slave that never leaves
  `SETUP=configuring`, so the wait hung on a port while `br0` had been routable since
  boot — carrying, on n150-1, the kube-vip VIPs .200 and .201. Fixed with an /etc
  drop-in named `20-lab-scope.conf`, which sorts after netplan's `10-netplan.conf` and
  resets ExecStart to wait on the bridge alone. Proven by restarting the unit, not by
  inspecting the file.

  **opi-zero2w-1 / -2.** Not a tuning problem: **NetworkManager and systemd-networkd
  are both running**, every link is `unmanaged` by networkd, so its wait-online waits
  for zero links and times out by definition. `NetworkManager-wait-online` is enabled
  and active on both, so `network-online.target` already had a working provider —
  which is what made disabling networkd's version safe rather than the
  ordering-guarantee-destroying move that masking would have been. DISABLED, not
  masked, so switching back to networkd re-enables normally.

  The play discovers the bridge (the link networkd reports `routable` + `configured`)
  rather than hardcoding `br0`, and refuses to act — printing `UNHANDLED` — when the
  unit fails but neither branch applies.

  **This took the fleet to ZERO failed units on every reachable host**, the first time
  that has been true. `systemctl list-units --failed` is now a check where any output
  at all is a finding, which is the whole point of §3.16.

  Still unexplained and worth its own look: WHY `enp1s0` never reaches
  `SETUP=configured` on either hypervisor. Waiting on the bridge is correct regardless,
  but that is a workaround for a netplan/networkd behaviour nobody has understood.
- `systemd-ask-password-*.path` — these deliver passphrase prompts. Masking them on
  hardware with no console means a box needing one at boot would never show it.
  Cleared, not masked; a recurrence is a finding.
- `snap.lxd.activate` on h4-core — RESOLVED 2026-08-31 by removing LXD entirely.
  A boot race with snapd.apparmor left it failed for 5 days; the unit restarts cleanly
  now, but LXD had never run a container and was holding ~37.5 MiB on the NAS + k3s
  control-plane node. `snap remove lxd` (no --purge, snapshot retained). See
  docs/HARDWARE.md.

**Why this is worth doing at all:** `systemctl list-units --failed` is now a tool this
lab uses, and a sweep that always returns eleven expected failures is a sweep nobody
reads carefully. That is precisely how `nfs-server` hid for 37 days — not because
nobody looked, but because looking was unrewarding. Same argument as driving §3.11's
drift floor to zero before writing its alerts.

**A pattern worth naming, since it appeared four times in one evening: SYSTEMD
REMEMBERS FAILURES FOREVER AND NOTHING HERE WAS CLEARING THEM.** Deleting a unit file
does not clear its failed state. Neither does masking it, disabling it, uninstalling
its package, or `daemon-reload`. Only `systemctl reset-failed` does. A removed unit, an
uninstalled package and a masked service all keep reporting `failed` indefinitely —
and `node_systemd_unit_state` keeps exporting `state="failed"` for something nobody
runs. That now matters directly: `LabSystemdUnitFailed` went live the same day, so any
unit added to its name filter carrying a stale failure would page immediately and
permanently.

**Also: `n150-3` (HTPC) is unreachable over WinRM** — `No route to host`. Probably
powered off, but it is in the inventory and nothing reports on it either way.

**A trap found while running the sweep, and it is not a repo defect.** The first
attempt used `ansible 'all:!xu3-1'` and three of sixteen result blocks were **h4-core
wearing other names**. `hostmon` and `m5stack` are ESP32-S3 microcontrollers in an
`embedded` group carrying `ansible_connection: local` — which does not mean "skip
these", it means **run on the control node**. Every playbook in the repo already
excludes them correctly (`all:!x86_nodes:!embedded:…`, five of them, and
`break-glass-key.yml` even explains why). The safety lives in each play's host pattern,
so **ad-hoc commands must repeat it**: use `all:!xu3-1:!embedded:!x86_nodes`. A
mutating ad-hoc against `all` would hit the NAS core three times.

**Sharpest framing, because it generalises past NFS:** this lab now has three recorded
cases of a fault persisting because nothing exported a metric for it — §3.15's 19-day
node-exporter crashloop, §1.12's lldap misdiagnosis, and this at 37 days. Each was found
by accident. The drift check found this one on its first run, which is encouraging, but
a weekly Ansible dry run is a poor substitute for a metric that would have fired the same
afternoon.

### 3.17 Nothing can see a WiFi drop on the Zero 2W pool — **watchdog written 2026-09-04, not yet applied**

**Reported symptom:** the Orange Pi Zero 2Ws disconnect from WiFi at random. **Measured
finding: nothing in the lab records a WiFi disconnect on those boards, so the symptom
can be neither confirmed nor sized.** That is the actual gap, and it is why the valuable
half of `playbooks/wifi-watchdog.yml` is its telemetry rather than its reconnect logic.

**The discovery pass contradicted three assumptions, including two of mine.**

- **Power save was already off on all four.** `iw dev wlan0 get power_save` → `off`
  everywhere, and NetworkManager already had `wifi.powersave = 2` on `-3` and `-4`. The
  requested fix was a no-op. It is worth codifying anyway — NM re-applies powersave on
  every reconnect, so a value that is correct today is not one that stays correct — but
  it was never the cause.

- **No disconnects in seven days: `0, 1, 0, 0`.** Unusually, this negative is
  trustworthy, because the check was proven able to speak: wpa_supplicant and
  NetworkManager both log to the journal here (`CTRL-EVENT-*` and
  `device (wlan0): state changed` were both observed). What *cannot* speak is the
  kernel — `journalctl -k` holds 560–668 lines with **zero** mentions of
  `wlan|unisoc|cfg80211|nl80211`. The out-of-tree `unisoc_wifi` driver is silent at
  kernel level. Do not build a kernel-log detector; it has nothing to read.

- **The reboots were manual.** `--list-boots` showed `-2` restarting twice in five days
  and `-3` four times inside 45 minutes; both were hand power-cycles. Worth recording
  because an automated reboot escalation is only defensible once spontaneous reboots are
  ruled out — a watchdog that reboots boards which already reboot on their own turns one
  fault into two.

**And one finding that was an artefact of looking.** A first pass counted **2 hits each**
of `under-voltage`, `out of memory`, `kernel panic` and `hardware error` — on all four
boards, identical counts, four unrelated causes. They were `sudo`'s log of the diagnostic
command, whose grep pattern contained all four phrases. `journalctl -k`, which cannot
contain sudo lines, returns 0 for every one. **The measurement had been reading itself**,
and "under-voltage on all four boards" was one sentence from being written down as fact.
Grep patterns run under `sudo` land in the journal they are searching.

**Design decisions, recorded because they were close calls:**

- **systemd timer, not cron, though cron was what was asked for.** `cron`/`crond` are
  inactive and `crontab` absent on `-1` and `-2` (Arch); `-3`/`-4` (Debian) have cron.
  Honouring cron means installing `cronie` on half the pool and managing two package and
  two unit names for something a timer does natively on all four.
- **The script detects its network stack at runtime rather than being templated.** The
  pool is split three ways: `-1`/`-2` NetworkManager, `-3` systemd-networkd, `-4` NM with
  networkd inactive. A manager baked in at template time produces a script that silently
  no-ops on the hosts it was not written for — and a no-op reconnect is indistinguishable
  from a successful one in every log it writes.
- **Reboot policy 30 min / max 2 per 24h, uniform across the pool.** Reboot stamps live
  in `/var/lib` so the cap survives the reboot it is counting; a counter in `/run` would
  reset each time and cap nothing. Three independent guards must all pass, including a
  15-minute minimum uptime that stops a board which comes back still broken from burning
  both allowances in ten minutes.

**To do:**

- [x] **Applied to all four, 2026-09-04**, `--check` first then `-3` → `-4` → the Arch
      pair. Every host `failed=0`, `ok=22`, and each closed on the assert reading a file
      the script had actually written:

          lab_wifi_watchdog_up 1  associated 1  reconnect_total 0  reboots_24h 0

      **The runtime stack detection is demonstrated, not assumed** — the one real design
      risk in the script. `lab_wifi_watchdog_info` came back with three different
      configurations resolving correctly:

          opi-zero2w-3   manager="wpa"   networkd + wpa_supplicant, NM inactive
          opi-zero2w-4   manager="nm"    NetworkManager, networkd inactive
          opi-zero2w-1   manager="nm"    NM + networkd + wpa all active
          opi-zero2w-2   manager="nm"    ditto

      A manager templated in at install time would have produced a silent no-op on at
      least one of these, and a no-op reconnect logs identically to a successful one.

      The `--check` run behaved correctly too: `changed=6`, then every task below
      `Enable and start the watchdog timer` skipped, with the report saying in its own
      output that nothing beneath it had been verified.

      **Two small things noted and not fixed.** `manager=networkd` is effectively
      unreachable on a WiFi host — wpa_supplicant is checked first and you cannot
      associate without a supplicant, so that branch is dead code that reads as live
      coverage. And the `reload NetworkManager` handler is `changed_when: true` with
      `failed_when: false`, so it reported `changed` on `-3` where NM is inactive and
      `nmcli` must have failed: a task claiming success without checking.

- [x] **Textfile collector enabled and APPLIED to all seven `node_exporter` hosts**
      2026-09-04. The number that proves the whole chain, on each Zero 2W:

          flag=1 | node_textfile_series=2 | wifi_watchdog_series=9

      `wifi_watchdog_series=9` — all nine metrics the script emits — means the script
      wrote the file, the collector read the directory, and the exporter served it.
      `flag=1` alone would only have proved the argument landed. And Prometheus has
      them: `lab_wifi_watchdog_up` returns 1 for `.184`, `.188`, `.217`, `.99`.

      **It also measured the metric names the assert could not risk.** Non-watchdog
      hosts (`octopi-dns`, `rpi4b`, `rpi5`) report `node_textfile_series=1` against 2 on
      the pool — the second series is the mtime gauge, which exists only once a `.prom`
      file is present. So the names are now known and the assert can be tightened from
      the ExecStart flag to the metric itself.

      **Found while doing it: `gitlab-1` is in neither `node_exporter` nor
      `node_exporter_binary`.** The groups hold 7 hosts and 1 (`xu3-1`) respectively.
      Yet this play's header claims *"Debian — octopi-dns, rpi4b, rpi5, gitlab-1,
      opi-zero2w-3, opi-zero2w-4 (apt)"*, and `monitoring.yaml` scrapes
      `192.168.1.50:9100`. `up{instance="192.168.1.50"}` is **1**, so it has a working
      exporter that something else installed — no outage, but nothing in Ansible manages
      it and the header describes coverage this play does not provide. Same shape as
      `rpi4b` answering DNS for weeks while outside the `dns` group (§4.12), and as this
      very file listing `opi-zero2w-4` as Arch when it is Debian (corrected 2026-08-27).
      Fix is to add it to the group or state plainly why not.

      It belongs there rather than in a new play: that file
      already owns node_exporter on exactly these hosts and already carries the
      Debian/Arch split.

      **Measured rather than branched on.** The reports from all four boards gave
      `unit=prometheus-node-exporter` uniformly, but `default_file=yes` only on the
      Debian pair — `/etc/default/prometheus-node-exporter` does not exist on Arch. So
      instead of branching on `os_family` (which this same file got wrong on 2026-08-27,
      having listed `opi-zero2w-4` as Arch when it is Debian), the play **reads the
      ExecStart the unit actually has** and re-issues it with the flag appended. That
      preserves whatever `$ARGS`/EnvironmentFile indirection each package uses and works
      on both — and on whatever the next re-image does.

      Guarded: the drop-in is written only if the captured ExecStart is non-empty and
      contains a path. An empty capture written into `ExecStart=` leaves the unit
      unstartable, and that failure would surface at the *next* restart rather than
      during the run that caused it.

      The assert checks the **flag in ExecStart**, not a metric name.
      `node_textfile_scrape_error` is the expected indicator but its exact spelling was
      not measured on these exporter versions, and an assert on a metric that does not
      exist fails identically to one on a collector that is not running. The series
      counts are reported so the real names can be read off a working host and the check
      tightened afterwards.
- [x] **Alert rules written 2026-09-04**, deliberately after the metrics were confirmed
      arriving rather than alongside them — a `lab.wifi` group added earlier would have
      fired on arrival because the series did not exist yet, and an alert that is noise
      on day one is an alert that trains the eye past it (`LabExternalHostDown`, three
      weeks critical, is the lab's own case study). Five rules in `lab-alerts.yaml`.

      **What these rules can and cannot see, which is not obvious.** If a board drops
      WiFi entirely, **Prometheus cannot scrape it** — the scrape fails before any gauge
      can be read, and the event surfaces as `up{job="node-exporter-external"} == 0`,
      already covered by `LabExternalHostDown` at critical. So none of these are the
      primary detector for "the board fell off the network". What they add is the part
      that was previously invisible: the **recovery**. Counters are read after the board
      is back.

      - `LabWifiFlapping` — `increase(reconnect_total[6h]) > 5`. The answer to the
        original question, and the reason the watchdog exists: a board reconnecting
        repeatedly is working *and* broken at once, which is exactly the state that
        leaves no trace without this counter.
      - `LabWifiWatchdogRebooted` — an automated reboot must never be silent.
      - `LabWifiWatchdogStale` — **the subtle one.** The `.prom` file persists on disk,
        so if the timer stops, node_exporter keeps serving the last values forever:
        every gauge stays at its final healthy reading and `absent()` never fires. Only
        `time() - last_run_timestamp` reveals it. Without this rule a dead watchdog is
        indistinguishable from a perfectly behaved one.
      - `LabWifiGatewayUnreachable` — `up == 0` while the board is still scrapable.
        Possible because Prometheus and these boards share a subnet, so traffic between
        them does not traverse the router: the board can fail to reach `192.168.1.1`
        while remaining perfectly visible. Different fault, different response.
      - `LabWifiWatchdogMetricsMissing` — the `absent()` companion. Note it does **not**
        cover a stopped watchdog; the file outlives the writer, which is what
        `LabWifiWatchdogStale` is for.
- [ ] **Re-ask the original question with data.** After a week, `increase(
      lab_wifi_watchdog_reconnect_total[7d])` answers whether the boards actually drop
      WiFi. If it is ~0, the reported symptom is something else — most likely the manual
      power-cycles above, which are indistinguishable from a WiFi drop when observed from
      the network.

**Two findings from this work that belong elsewhere:**

- **Hostname collision — §4.14.** `/etc/hostname` against the Ansible key:
  `.184` → `opizero2w-4`, `.188` → `opizero2w-1`, `.217` → `orangepizero2w`,
  `.99` → `opi-zero2w-4`. **`.184` and `.99` differ by a single hyphen.** Metrics are
  unaffected (`monitoring.yaml` relabels `instance` from the scrape address), but journal
  entries and anything Promtail/Alloy ships carry the hostname, so logs from `.184` land
  under a name belonging to a different machine. Not fixed in passing: renaming hosts
  mid-play would invalidate the metrics being installed.
- **No battery-backed RTC, and `fake-hwclock` only on `-4` — §1.13.** `/dev/rtc0` exists
  on all four and reads correctly while powered, but `fake-hwclock` is `not-found` on the
  Arch pair and `masked` on `-3`. `-1` came up stamped **2024-07-06** and `-2`
  **2026-07-24**, until NTP corrected them. This is §1.13's "warm RTC" exposure realised:
  every boot passes through a window where TLS sees certificates as not-yet-valid, and
  any `journalctl --since` query is unreliable across it.

---

## 4. Broken or blocked, live

### 4.1 CI depends on an image with no build definition — **verified; two broken refs, not one**

**Found 2026-08-21 during the backlog sweep:** there are *two* references to the nonexistent
image, at **different registry hosts that disagree with each other** —
`.gitlab-ci.yml:24` uses `registry.apps.lab.home.arpa/tools/homelab-ci:latest` and
`ansible/.gitlab-ci.yml:17` uses `registry.lab.home.arpa/tools/homelab-ci:latest` (no `apps.`).
Only one of those hostnames resolves in this lab. Fixing one and not the other leaves CI
broken in a way that looks fixed.
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

### 4.4 ~~k3s version — pinned for servers, but agents hardcode a five-minor-old downgrade~~ — **FIXED 2026-08-27**

> All three fallbacks removed, not just the agent's. `k3s_version` now resolves from
> `inventory/group_vars/all/k3s.yml` only — the pattern `update-non-apt.yml` already
> used — and each play asserts it is present and matches `^v\d+\.\d+\.\d+\+k3s\d+$`
> before doing anything.
>
> **It was three fallbacks pointing in two directions**, which the entry had as one:
> `k3s-agent.yml` fell back to `v1.31.4+k3s1` (a *downgrade*, five minors behind the
> pin, on both inference nodes), while `k3s-h4.yml` and `k3s-ha-join.yml` fell back to
> the `stable` channel (an *upgrade*, on the control plane — and `k3s-ha-join.yml` is
> `serial: 1` across the etcd voters, so it would have been carried in one node at a
> time). Fixing only the agent would have left two open paths looking closed — the
> §4.1 trap, where one of two broken refs gets fixed and CI looks repaired.
>
> **Nothing to apply:** these playbooks execute only during an install or a join, so
> the guard is live on merge. Unlike §1.7, there is no host-layer gap here.

**Reframed 2026-08-21.** The `default('stable')` fallbacks at `k3s-h4.yml:16` and
`k3s-ha-join.yml:29` are real but unreachable for the standard inventory:
`ansible/inventory/group_vars/all/k3s.yml:7` has pinned `k3s_version: "v1.36.2+k3s1"` for all
hosts since 2026-06-23, which this entry never mentioned.

**The live defect is the opposite of a float.** `ansible/playbooks/k3s-agent.yml:17` falls back to
a hardcoded `v1.31.4+k3s1` — five minor versions behind the pin. That is a silent *downgrade*
path on the two inference nodes, which is worse than drifting forward and was unrecorded.
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

### 4.7 ~~PDBs block node drains~~ — **FIXED 2026-07-26 (`ccfb9b3`, PR #308) — recorded 2026-08-21**

All three PDBs use `maxUnavailable: 1`: `lldap/pdb.yaml:18`, `authelia/pdb.yaml:11`,
`immich/pdb.yaml:9`, each carrying a comment on why `minAvailable` was wrong for a
single-replica workload. `grep -rn minAvailable gitops/` returns nothing.

**This sat under "Broken or blocked, live" for 26 days after it was fixed**, and was nearly
picked as the top priority on 2026-08-21 because the entry still read as open. That is the
cost of the backlog drifting, paid in the currency it is supposed to save.
`docs/REVIEW-2026-07-24.md:271` (H7) — three PDBs with `minAvailable: 1` against
`replicas: 1`. Any drain hangs forever.

### 4.8 OVMS is disabled and its config is invalid — **1 of 3 blockers cleared**
**Heading corrected 2026-08-21**: a service that `ai-nodes.yml:199-206` stops and disables is
not crash-looping.

Cleared: the GPU runtime is now installed (`ai-nodes.yml:300-308` — `intel-opencl-icd`,
`intel-level-zero-gpu`, `level-zero`), though both tasks carry `ignore_errors: true` and can
therefore no-op silently.

**Not cleared, and worse than the entry states:** the invalid `config.json` is no longer merely
deployed, it is **generated from git**. `ai-nodes.yml:327-340` writes
`/opt/ovms/models/config.json` with `// TODO: download and convert bge-small …` appended
*after* the closing brace — JSON with a comment after the document ends. `force: false`, so it
never self-corrects. Model IR conversion is still absent.
`ansible/playbooks/ai-nodes.yml:191-198` — needs `intel-opencl-icd` + level-zero, model
IR conversion, and a valid `config.json` (the deployed one contains `//` comments).

### 4.9 Kyverno `cleanupJobs` block is a confirmed no-op
`gitops/apps/kyverno.yaml:55-66` — creates nothing as of chart 3.3.4.

### 4.10 Kyverno `require-resource-limits` skips initContainers — **a live workload is exploiting the hole**

**Found 2026-08-21:** this is not hypothetical. `gitops/workloads/home-assistant/deployment.yaml:51-53`
runs an initContainer `seed-config` on `busybox:1.38` with **no `resources` block at all**, while
the main container at `:44-50` has limits. The policy is `validationFailureAction: Enforce`, so
this is an enforced rule with a hole that something is already through — not an audit gap.
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

> **CORRECTION 2026-08-29 to the opi5pro row.** "No event, list is ≤3, not truncated"
> was inferred from the absence of a kubelet warning, and absence of an event is not
> evidence of a short list — the same reasoning §1.12 and §3.14 both punish. Measured
> directly with `resolvectl status`, `opi5pro-1` had **six**: four in the global scope
> (`1.0.0.1 .148 .116 .184`) plus two on Link 2 (`.148 .116`). §4.16's count was right
> and this table's was not.
>
> Now **five**, after applying `node-dns.yml` to both OPi5s on 2026-08-29 — a task that
> had been written since August and never run, found by §3.11's first drift check. The
> removed entry was `1.0.0.1` sitting inside the `~lab.home.arpa` routing-only scope,
> where it could only ever have answered lab queries it cannot resolve. See §4.16 for
> the full finding.

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
- [x] **Reboot the H4** — **DONE 2026-08-31, and it worked.** The boot-time path that
      `netplan try` cannot test came up clean. Measured immediately after:

          $ grep -c nameserver /run/systemd/resolve/resolv.conf
          3
          nameserver 192.168.1.148
          nameserver 192.168.1.116
          nameserver 192.168.1.184

      **That number was 6.** `.152` is gone. All five k3s nodes returned `Ready`, both
      backup timers active, zero failed units after boot. The pristine backup is now at
      `/etc/netplan/50-cloud-init.yaml.orig` (§3.11 promoted it from the dated copy).
- [x] Confirm no *new* `DNSConfigForming` events for `odroid-nas` — **CONFIRMED
      2026-08-31.** Events kept firing 3–4 minutes after the reboot, which looked like a
      failed fix until the pods were attributed:

          node-exporter tch26 -> n150-2      node-exporter k8f96 -> n150-1
          kube-vip 7tzlg      -> n150-2

      Every recent event is a pod on an N150. **None on `odroid-nas`.** Worth noting how
      close this came to a wrong conclusion: the events' applied line reads
      `.148 .116 .184`, which is exactly what the H4 now has — so the message looks like
      it is describing the fixed host. Only `-o wide` distinguishes them.
- [ ] **Should the H4 join `node-dns.yml`? Answer 2026-09-02: eventually yes, but NOT
      as a simple group addition — it would recreate this very entry's bug.**

      The two mechanisms supply resolvers by different routes:
        - `node-dns.yml` writes a GLOBAL `DNS=` drop-in for systemd-resolved
        - the H4 gets its three PER-LINK on enp2s0, from netplan

      Measured after the 2026-08-31 reboot: `resolvectl dns` shows `Global:` empty and
      `Link 3 (enp2s0): .148 .116 .184`. Adding the global drop-in on top would give
      **3 global + 3 link = 6 nameserver lines** — exactly the >3 condition this entry
      exists to fix, reintroduced on the node that just got fixed. It is the same
      concatenation that put the N150s at five.

      So joining requires FIRST removing the netplan-supplied nameservers from the H4,
      then letting the drop-in provide them — a second DNS change to the core, on top
      of a reboot it has just had. Worth doing for consistency and drift coverage;
      not worth doing casually. Sequence it deliberately.
- [x] **`lab_dns_servers` in `node-dns.yml` corrected** 2026-08-21, from
      `.148 .184 .217` (one Pi-hole, two dnsmasq) to `.148 .116 .184` (two Pi-holes,
      one dnsmasq). ~~**Not yet applied**~~ — **APPLIED 2026-08-31**, incidentally: the
      play was run for real to disable a competing dnsmasq (§3.16), and the drop-in on
      all four managed nodes now reads `DNS=192.168.1.148 192.168.1.116 192.168.1.184`.
      Verified by reading `/etc/systemd/resolved.conf.d/10-lab-dns.conf` on n150-1 and
      n150-2. A correction that sat unapplied for ten days went out as a side effect of
      unrelated work — which is §3.11's whole thesis, arriving from the other direction.
- [x] **The N150 warning — RESOLVED 2026-09-01.** Root cause was NOT what this entry
      assumed. See the block appended at the end of this section.

- [x] ~~The N150 warning persists, exactly as predicted~~ — and 2026-08-31 measured the
      composition rather than inferring it. Both hypervisors carry FIVE lines that are
      only THREE distinct servers:

          nameserver 192.168.1.148    <- global, from node-dns.yml's 10-lab-dns.conf
          nameserver 192.168.1.116    <- global
          nameserver 192.168.1.184    <- global
          nameserver 192.168.1.184    <- br0 link, from DHCP   DUPLICATE
          nameserver 192.168.1.116    <- br0 link, from DHCP   DUPLICATE

      `resolvectl dns` shows it plainly: `Global: .148 .116 .184` and
      `Link 4 (br0): .184 .116`. The kubelet counts LINES, not distinct servers, so
      three unique resolvers trip a three-server limit. Nothing here is stale or wrong;
      **our own drop-in collides with what the router advertises on the bridge.**

      THE FIX, not yet applied: `dhcp4-overrides: {use-dns: false}` on the br0 definition
      in netplan, leaving the Ansible-managed three as the only source. Takes both hosts
      to exactly 3.

      WHY IT WAS NOT DONE THE SAME NIGHT: it is a netplan change on both KVM
      hypervisors, and `br0` on n150-1 was carrying the kube-vip VIPs **.200 and .201**
      at the time. An apply that briefly drops the bridge takes the control-plane VIP
      and the ingress VIP with it. `netplan try` reverts after 120 s so it is
      survivable, but it wants doing deliberately, with the current VIP holder known,
      and one node at a time. Same posture `h4-dns-resolvers.yml` already takes.

      Original reasoning, which was correct: `node-dns.yml` writes a *routing-only* drop-in
      (`Domains=~lab.home.arpa`), so its three servers apply to lab queries while the
      nodes' global resolvers still come from DHCP. The union is what the kubelet
      truncates. Correcting the list fixes *which* three get used; it does not reduce
      the count. Suppressing the DHCP-supplied global DNS on those nodes is a netplan
      change (`dhcp4-overrides: use-dns: false`), the same mechanism that worked on the
      H4's `enp1s0` — and a separate piece of work from this list.
- [x] **Docs disagreement RESOLVED 2026-09-02: README was right.** The code settles
      it — `node-dns.yml`'s `lab_dns_servers` is the only list cluster nodes resolve
      against, and its own comments name each role:

          .148   Pi-hole v6 PRIMARY     (octopi-dns)
          .116   Pi-hole v6 SECONDARY   (rpi4b)
          .184   dnsmasq TERTIARY       (opi-zero2w-1)

      CLAUDE.md called `.184` "secondary" and `docs/HARDWARE.md` was internally
      inconsistent, calling BOTH `.116` and `.184` secondary in different tables. Both
      corrected, plus three more instances found while checking. A reference table now
      lives in HARDWARE.md so the next reader gets position, not adjective.

      **The confusion has a traceable origin: the legacy names.** `.184` is `dns-2` by
      NAME but third by POSITION, because the old `dns-1..dns-4` numbering never
      matched resolver order. §3.12 collapsed those names; the mismatch outlived them.

      **AND IT SURFACED A THIRD THING.** The docs called FOUR boxes "DNS secondary".
      The fourth is `.217` (opi-zero2w-3), which is **in the `dns` inventory group —
      so `dns.yml` configures and maintains it — but is NOT in `lab_dns_servers`.**
      `node-dns.yml`'s comment preserves why: the old list was `[.148, .184, .217]`
      (one Pi-hole, two dnsmasq), corrected on 2026-08-21 to `[.148, .116, .184]`
      (two Pi-holes, one dnsmasq). `.217` was dropped from the list and no document
      was updated. It is a configured DNS server that nothing resolves against.

- [ ] **Decide what `.217` is for** — **half answered 2026-09-02 by §3.3's probes; the
      decision is now an informed one rather than a guess.**

      **Measured, not assumed.** `.217` answers every probe correctly, alongside the
      three resolvers actually in `lab_dns_servers`:

          dns-api-vip           192.168.1.217:53  1
          dns-apps-wildcard     192.168.1.217:53  1
          dns-nxdomain-control  192.168.1.217:53  1
          dns-recursion         192.168.1.217:53  1

      **And it is genuinely independent, which the probe alone does not prove.** A
      dnsmasq that merely forwarded to `.148` would return identical answers and look
      just as green — so redundancy has to be read from the config, not the response.
      Both dnsmasq boxes carry:

          domain=lab.home.arpa
          local=/lab.home.arpa/                          <- never forward this zone
          address=/apps.lab.home.arpa/192.168.1.201
          host-record=api.lab.home.arpa,192.168.1.200

      `local=` is the load-bearing line: it makes dnsmasq answer the zone from local
      config and never ask upstream. So `.184` and `.217` are authoritative for
      `lab.home.arpa`, not proxies. The lab has **four real resolvers**, not two and two
      pass-throughs. (`.148`/`.116` hold their records in Pi-hole's own `hosts` list —
      that half of the check was cut short by a `head -8`, the same truncation mistake
      logged three times already this fortnight, so read their independence from
      `probe_success` rather than from that output.)

      **What this changes.** The entry previously read as dead weight: "a configured DNS
      server that nothing resolves against." It is now a **verified** warm spare, proved
      good every 60 seconds by a probe that would go red the moment it stopped being
      one. That is a different proposition — the usual objection to an unused spare is
      that nobody knows whether it still works, and that objection no longer applies.

      **Still a decision, and still open.** Promoting it is a one-line `lab_dns_servers`
      edit; removing it from the `dns` group would discard a resolver now known to be
      correct. Leaving it exactly as it is has become defensible for the first time.
      What is NOT acceptable is leaving the docs disagreeing — see the CLAUDE.md fix
      below, and note `monitoring.yaml` calls it "DNS quaternary" while `hosts.yml`
      gives it `dns_role: secondary`.
- [x] **`.152` — ANSWERED 2026-09-02: the interface is fine; it was never the problem.**
      `.152` is octopi's WiFi — the SAME box as the DNS primary `.148`, by a flakier
      path. It appears nowhere live: not in `lab_dns_servers`, and gone from the H4
      since the 2026-08-31 reboot. It survives only in `h4-dns-resolvers.yml`'s
      historical comments, this backlog, and HARDWARE.md's `(avoid)` marker.

      The fault was never that `.152` exists — it was that it got INTO a resolver list,
      where it added a fourth entry pointing at a box already listed as `.148`. That is
      fixed at the source. Keeping the interface is defensible: a second path to the
      DNS primary is useful for out-of-band access, and disabling WiFi on a Pi 3B that
      serves DNS removes the fallback if its wired link dies. The `(avoid)` note is the
      right control, and it worked — nothing put `.152` back. An address documented as "avoid" that
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

**Blocker cleared 2026-08-28, and it was never written down here.** This play could not
have been written safely before §3.12 was fixed, for a reason neither entry mentioned:
**`inventory_hostname` was ambiguous for four machines.** 192.168.1.116 answered to both
`dns-3` and `rpi4b`, .148 to both `dns-1` and `octopi-dns`, and so on. A play setting
`hostname` from `inventory_hostname` would have set each of those four twice per run, to
two different values, last writer wins — non-deterministically, depending on play order.
The dedupe removed that: one machine now has exactly one inventory name.

**The danger it does not remove, restated because it is the one that matters.** The naive
form of this play — `hostname: name={{ inventory_hostname }}` across the fleet — would
rename the core of the lab. **`h4-core` is an inventory name; the machine's actual
hostname is `odroid-nas`**, which is what k3s registered as its Node name and what six
`kubernetes.io/hostname` selectors pin to. Running it would leave the old Node object
`NotReady`, register a new empty one, and strand the `local-path` PVs that cannot follow.
The same applies to `n150-1`/`n150-2` (12 selectors) and both opi5pro agents.

So for the cluster nodes the mismatch is in the **inventory**, not on the machines, and
the correct direction is to rename the inventory entry — not the host. That is a
different, cheaper change, and it is not what this entry describes.

**Scope it accordingly:**

- [ ] **Non-cluster hosts only, to begin with** — the Pis and Zero 2Ws. They are the
      ones that are actually inconsistent, they carry no `kubernetes.io/hostname`
      selectors, and the blast radius is a reboot.
- [x] Identify `orangepizero2w` — **ANSWERED 2026-08-31.** It is `opi-zero2w-3`
      (192.168.1.217, Armbian Trixie, DNS secondary). Not an unattributed host; just a
      board whose hostname was never set past the image default.
- [x] Resolve the `opi-zero2w-4` / `opizero2w-4` duplicate — **ANSWERED 2026-08-31, and
      THERE IS NO DUPLICATE. They are two different machines**, which is worse than a
      duplicate would have been. Measured `/etc/hostname` and `hostnamectl --static` on
      all four boards:

      | inventory name | IP    | ACTUAL hostname  | role                |
      |----------------|-------|------------------|---------------------|
      | opi-zero2w-1   | .184  | **opizero2w-4**  | **DNS secondary**   |
      | opi-zero2w-2   | .188  | **opizero2w-1**  | MQTT broker         |
      | opi-zero2w-3   | .217  | **orangepizero2w** | DNS secondary     |
      | opi-zero2w-4   | .99   | opi-zero2w-4     | MQTT secondary      |

      Only one of four matches. **The dangerous pair: `opizero2w-4` is the hostname of
      the board inventory calls `opi-zero2w-1` — the DNS secondary at .184. A DIFFERENT
      board, at .99, is named `opi-zero2w-4` in inventory and runs MQTT.** Anyone who
      reads `opizero2w-4` in a journal line, Loki label or alert annotation and then
      runs `ansible opi-zero2w-4 ...` operates on the wrong machine — MQTT instead of
      DNS, and CLAUDE.md is explicit that DNS is load-bearing here.

      Found 2026-08-31 while chasing `systemd-remount-fs`: the journal on the host
      Ansible addressed as `opi-zero2w-2` printed `opizero2w-1`, which is what made the
      names worth checking at all. Neither .184 nor .188 has the `hostname` binary
      installed, so `hostname` returns nothing and the mismatch is invisible to the
      obvious check — `cat /etc/hostname` is required.
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

- [x] **Persistent `storagePath`** — done 2026-09-02. `hostPath /var/lib/alloy`
      (`DirectoryOrCreate`), mounted read-write, with `alloy.storagePath` pointed at it.

      Confirmed against the running pod before writing anything, rather than inferring
      from the rejection messages:

          --storage.path=/tmp/alloy                     <- chart default, as claimed
          /tmp/alloy/loki.source.journal.systemd/       <- the position stores
          /tmp/alloy/loki.source.kubernetes.pods/
          28K total, mtimes updating minutes before the check

      The positions were being written correctly all along and discarded on restart.
      28K per node to keep them.

      `DirectoryOrCreate` here is deliberately the OPPOSITE of the journal volume's
      `Directory`, and the contrast is worth keeping: the journal MUST pre-exist —
      its absence is §3.9's bug, so auto-creating it would hide the fault behind a
      silently-succeeding mount. Alloy's state directory legitimately does not exist
      before its first run on a node, so creating it empty is correct rather than a
      mask. Same option, opposite meanings, ten lines apart in the same file.

      No fsGroup or chown initContainer needed: Alloy runs as uid 0 (verified — `id`
      in the pod, and an empty securityContext), so a kubelet-created root:root
      directory is writable.

- [x] **`reject_old_samples_max_age`: NOT raised** — decided 2026-09-02, and the
      original reasoning holds with an extra argument on top.

      The rejection is correct behaviour. Raising the window would let stale replays
      land silently, trading visible noise for invisible bad data — strictly worse.

      And as of today it would also be futile: Loki's compactor retention was enabled
      the same day (§3.14), so anything older than 30d is now actively deleted.
      Widening the acceptance window would ingest data destined for immediate
      deletion — cost with no benefit.

      Left unset, so Loki's default applies. Recorded here so the next person hitting
      the rejection messages knows it was considered and declined, not overlooked.

### 4.16 Decide whether cluster nodes should resolve public DNS through the lab

**Deferred deliberately 2026-08-21**, split out of §4.12 because it is a design choice,
not a defect.

> **UPDATED 2026-08-29 — the OPi5s are now 5, not 6, and the reason they were 6 was
> that this playbook had never been applied to them.**
>
> The first run of §3.11's drift check reported `node-dns` at 4. The diff was the
> `DNS=1.0.0.1` neutralisation, still un-applied on `opi5pro-1` and `opi5pro-2` — the
> N150s were clean. So the parenthetical below, *"(done in `node-dns.yml`)"*, meant
> **written there**, not **applied there**. §3.11 in miniature, inside the entry that
> documents §3.11's own subject.
>
> **A worse thing was hiding behind the count.** `resolvectl status` on `opi5pro-1`
> before the fix:
>
>     Global
>       DNS Servers: 1.0.0.1 192.168.1.148 192.168.1.116 192.168.1.184
>       DNS Domain:  ~lab.home.arpa
>
> The `~lab.home.arpa` applies to the **whole global scope** — this playbook's own
> comment says so — which makes every server in it *routing-only*: they receive
> `lab.home.arpa` queries and nothing else. So `1.0.0.1` was never providing public DNS
> here. It was sitting in the pool answering **lab** names, which Cloudflare cannot
> resolve; `home.arpa` is special-use and returns NXDOMAIN.
>
> Two consequences neither this entry nor §4.12 had noticed:
>
> - **Lab resolution could fail intermittently.** resolved rotates servers on timeout,
>   and any rotation onto `1.0.0.1` for a lab name returns NXDOMAIN — a DNS fault with
>   no obvious cause, on the class of thing §4.11 and §6.1 are both scars from.
> - **Internal hostnames leaked.** Every `*.lab.home.arpa` query that landed on
>   `1.0.0.1` told Cloudflare the lab's naming.
>
> **Applied 2026-08-29 to both OPi5s, one at a time**, and the claim below that "public
> DNS still works via the links" is now measured rather than asserted:
>
>     Global DNS Servers: 192.168.1.148 192.168.1.116 192.168.1.184   (4 -> 3)
>     api.lab.home.arpa -> 192.168.1.200      lab resolution intact
>     github.com        -> 140.82.114.4       public DNS via Link 2 (.148, .116)
>
> Link 2 carries `.148` and `.116` with **no** domain restriction, so those are the
> general-purpose resolvers and always were. 3 global + 2 on the link = **5**, exactly
> the 6→5 predicted below.
>
> **This entry stays open.** 5 is still above the kubelet's cap of 3, so the design
> question is unchanged. What changed is that the discarded nameserver is no longer a
> public resolver answering lab queries.

The four `node-dns.yml` nodes exceed the kubelet's three-nameserver limit —
**5 on n150-1/n150-2, and 5 on opi5pro-1/2 since 2026-08-29** — and the remaining count
cannot be reduced without answering a question this lab has never explicitly decided.

`node-dns.yml` writes `Domains=~lab.home.arpa`. The `~` makes the lab servers
**routing-only**: they answer lab names and nothing else. Public DNS therefore comes
from the links' DHCP servers. That is why the count stays above three, and why the H4's
fix does not transfer:

- ~~Removing the distro's `DNS=1.0.0.1` (done in `node-dns.yml`) takes the OPi5s from 6
  to 5 and makes lab resolution deterministic. Public DNS still works via the links.~~
  **Done 2026-08-29 — see the update above.** Both halves of that sentence turned out
  to be true; neither had been verified when it was written, and "done in
  `node-dns.yml`" meant written rather than applied.
- Adding `use-dns: false` on the links — the H4 recipe — would leave three
  routing-only servers and **nothing at all serving public names**. Image pulls from
  ghcr.io and docker.io would fail on every affected node.

**The decision.** To reach three, the `~` has to go, making the lab Pi-holes the
default resolver for everything and letting them forward public queries upstream.

Arguments for: Pi-hole filtering would apply to node-level traffic, which it currently
does not; the resolver list becomes deterministic and countable; the warning stops.

Arguments against: node internet DNS then depends on the lab resolvers being up. Two of
the three are Raspberry Pis, one of which (`octopi`, a 1 GB RPi 3B) is already the
lab's most overloaded DNS host. Losing them would stop image pulls cluster-wide rather
than just breaking lab-name resolution — a strictly larger blast radius than today.

**Not urgent.** The current state resolves correctly; the cost is a recurring warning
and an arbitrary omission. Worth deciding when there is appetite to test it, not while
closing something else.

### 4.17 Container images exist only where a workload has already run — **ACCEPTED 2026-08-28, with detection**

**Measured 2026-08-28**, while chasing a hypothesis about §1.12 that turned out to be
wrong. The lldap backups were never failing, so this is not the cause of anything. It is a
real latent condition found by accident on the way to a different answer.

**Why it exists.** `registries.yaml` mirrors only the lab Zot registry; docker.io and
ghcr.io mirroring was removed on 2026-08-09 and deliberately not restored, because routing
every pull through a registry that runs *inside* the cluster it serves is a cold-start
dependency (see `k3s-registry.yml`'s own comment — that reasoning still holds and this
entry does not reopen it). Every public pull therefore goes straight to the internet from
whichever node needs it. Combined with `imagePullPolicy` defaulting to `IfNotPresent`, an
image is present on a node **only if that workload has already run there**.

**14 of 20 workload directories pin to a node** via `kubernetes.io/hostname`, so their
images only ever need to exist in one place. The exposure is the mobile set — `replicas: 1`
Deployments with no scheduling constraint at all:

| image | cached on | of 5 |
|---|---|---|
| `home-assistant:2026.7.2` | opi5pro-2 only | 1 |
| `busybox:1.38` (its init container) | opi5pro-2 only | 1 |
| `immich-machine-learning:v2.7.5` | h4-core only | 1 |
| `immich-server:v2.7.5` | h4-core, opi5pro-2 | 2 |
| `lldap:v0.6.3` | n150-2, opi5pro-1, opi5pro-2 | 3 |
| `authelia:4.39` | all but n150-1 | 4 |
| `postgres:16-alpine` | all but n150-2 | 4 |
| `restic:0.17.3` | all but n150-1 | 4 |
| `redis:6.2-alpine` | all but n150-1 | 4 |

**Home Assistant is the sharpest case:** both its image and its init container are cached
on one node of five, so losing opi5pro-2 gives it a 4-in-5 chance of needing two public
pulls before it can start. `postgres:16-alpine` backs Authelia's database, and Authelia is
what everything else authenticates through.

**A wrong alarm, recorded so it is not raised again.** `kube-vip:v0.9.2` was initially
flagged as the worst case — a DaemonSet missing from two nodes. It is not a gap:
`kube-vip/daemonset.yaml` carries `requiredDuringScheduling` nodeAffinity on
`node-role.kubernetes.io/control-plane`, so it only ever runs on the three servers, and it
is cached on all three. The error came from testing for `kubernetes.io/hostname` alone and
treating everything else as unpinned. **A workload can be constrained by something other
than the selector you grepped for.**

**DECISION: accept, and detect.** Taken deliberately rather than by default. Nothing has
broken; the condition is invisible until a reschedule coincides with a registry being
unreachable or rate-limiting anonymous pulls. The alternatives were weighed:

- *Pre-stage the mobile images with a play.* Works, adds no runtime dependency, but drifts
  every time Renovate bumps a tag — so it belongs in the upgrade flow, not as a one-off.
- *Constrain scheduling.* Pinning HA and Immich removes the pull and removes the
  availability those unpinned Deployments presumably exist to have.
- *Zot as a pull-through cache.* Already rejected 2026-08-09 for cold-start reasons that
  have not changed.

**The detection**, in `gitops/workloads/monitoring/lab-alerts.yaml` group `lab.images`:
`LabImagePullFailing` (10m, warning) and `LabImagePullStuck` (45m, critical). Two
severities because warnings route to the m5stack display only — a workload that has been
unable to start for three quarters of an hour is an outage, not a notice. Same split as
`LabClockUnsynced` against the built-in: the metric is not the question, the routing is.

**Validated in both directions before merging**, which is the part worth copying.
`count(kube_pod_container_status_waiting_reason)` returned nothing — the shape this lab has
misread three times in a week. It was *not* a missing metric: kube-state-metrics emits that
family only for containers currently waiting, so empty is the correct steady state. The
control that established it was `count(kube_pod_info)` -> **93**. Then a deliberate failure
— a pod pulling `ghcr.io/swares/does-not-exist:v0` in a scratch namespace — reached
`ImagePullBackOff` and produced the series with the labels the annotations use.

**Revisit if any of these become true:**

- [ ] A pull failure actually causes an outage (the alerts exist to tell you).
- [ ] Any mobile workload stops being `replicas: 1` — coverage gaps matter more when
      several pods must schedule at once.
- [ ] docker.io rate limiting starts biting. Anonymous pulls are the current posture and
      nothing tracks how close the lab runs to the limit.
- [ ] A node is rebuilt or added. It starts with an empty image store, and every mobile
      workload that lands on it needs the internet.

**Open, and not about caching:**

- [ ] **Does `immich-machine-learning:v2.7.5` have an arm64 manifest at all?** It is cached
      only on h4-core (amd64) and has therefore never run on an opi5pro. Nothing constrains
      it by architecture, so if it reschedules onto an arm64 node and no manifest exists it
      fails regardless of what is cached. `home-assistant` and `immich-server` are proven
      multi-arch by their presence on opi5pro-2. Answer it with `k3s ctr images pull` on an
      arm64 node.
- [ ] **`busybox:1.38` keeps turning up.** It is the Home Assistant init container, it is
      the workload exploiting §4.10's Kyverno resource-limits hole, and it is cached on one
      node. Three separate entries, one container.

---

## 5. Scheduled / time-bound

| Item | By | Ref |
|---|---|---|
| ~~Renew `token-admin` (720h TTL)~~ | ~~2026-09-06~~ | **Decided 2026-08-23: let it lapse.** Nothing automated uses it — see below |
| ~~ESO → Kubernetes auth (token expires)~~ | ~~2026-09-08~~ | **DONE 2026-08-23** — deadline eliminated, not renewed |
| Destroy superseded unseal shares (envelope item 5b) | **2026-11-16** | §1.2, `docs/BREAK-GLASS.md` |
| ~~Enable `backup-offsite.timer` after seed~~ | ~~Sunday 08-09~~ | done — §1.3 |

**Both September items are resolved, and neither by renewing anything.** ESO's expiry was
designed out — Kubernetes auth has no TTL to lapse. `token-admin`'s was dissolved by
checking what actually depends on it: nothing automated does, so its expiry is not a
failure, it is a door that locks. Mint a new one when needed
(`docs/OPS.md` → *Get a Vault admin token*).

The pattern worth carrying: **when something has a recurring deadline, ask what breaks if
it lapses before deciding how to keep it alive.** Twice today the honest answer changed the
fix — once to remove the mechanism, once to stop treating a non-event as an outage. Do them at a time of your choosing rather than theirs — and note that since §1.11,
letting `token-admin` lapse means a `generate-root` ceremony to get back in, so it costs
more than it used to.

#### ESO — ~~drafted~~ **DONE 2026-08-23. Deadline removed, not moved.**

All three steps applied and verified. `kubectl get externalsecrets -A` shows all **16**
with a `refreshTime` of `2026-08-23T01:14:38-40Z` — a full reconcile pass within two
seconds, under Kubernetes auth. The ~2026-09-08 expiry no longer exists to miss.

Verified by **content, not condition**: an advancing `refreshTime` can only be produced by
the operator actually reconciling. The `Ready: True` conditions are worthless as evidence
here — on 2026-08-21 all 16 reported `True` for twenty minutes while the operator was
deleted and nothing was syncing (§3.13).

Sequencing that made it safe: steps 1 and 2 were inert — they created an identity and
configured Vault to accept it, while ESO carried on using the static token. Step 2 ended
with a **real login**, printed explicitly, so step 3 was taken on evidence rather than
expectation.

> **CORRECTION, 2026-08-26. Step 3 shipped broken, and the paragraph above is how it was
> missed.** The `serviceAccountRef` was written without a `namespace`. A ClusterSecretStore
> has no namespace of its own, so the reference resolved against *each ExternalSecret's*
> namespace — ESO looked for an `external-secrets` ServiceAccount in `immich`, `monitoring`,
> `semaphore`, `lldap` and the rest, and failed all sixteen:
>
>     cannot request Kubernetes service account token for service account
>     "external-secrets": serviceaccounts "external-secrets" not found
>
> It surfaced only three days later, after the H4 recovery, as ten `Degraded` Argo
> Applications.
>
> **The `refreshTime` evidence was wrong, and wrong in the way this entry warns about.**
> Sixteen ExternalSecrets sharing a `refreshTime` inside two seconds proved the operator
> reconciled them; it did not prove any of them *authenticated*. A reconcile that fails
> stamps the same field as one that succeeds. The column that would have shown it was
> `READY`, which read `SecretSyncedError`.
>
> So this section correctly rejected `Ready: True` as proof — and then substituted a
> different signal that also could not distinguish success from failure. **"Verify by
> content, not condition" is not a rule about which field to read; it is a rule about
> finding a value that the failure case cannot produce.** `refreshTime` advances either way.
>
> The `ClusterSecretStore` also reported `Ready: True` throughout, because store validation
> never exercises the ServiceAccount lookup — the health signal closest to the fault was
> structurally incapable of seeing it.
>
> Fixed by adding `namespace: external-secrets`, with the reasoning inline at
> `gitops/workloads/immich/external-secret.yaml`. All 16 now read `SecretSynced` / `True`.
> Kubernetes auth itself was never the problem: the design was sound, the deadline is
> genuinely gone, and one missing field made it inoperative for three days.

- [x] **Cleanup done 2026-08-23.** Static token revoked (via the environment, never on a
      command line — §2.13), the `vault-token` Secret deleted, `secret/lab/eso` removed.
      No unused valid credential left behind.
- [x] **`docs/RUNBOOK.md` rewritten** — "ESO token expired" became "ESO cannot read from
      Vault". The old procedure minted a token that no longer exists, on the page someone
      reaches for in a panic. It now leads with *diagnose by content, not condition*, and
      gives the three independently-testable pieces (auth method, a real login, the
      token-reviewer identity) which fail in distinguishable ways.

<details><summary>Original three-step plan, retained for the reasoning</summary>

#### ESO — drafted 2026-08-21, three steps, deadline removed rather than moved

Kubernetes auth has no expiry: ESO presents its own ServiceAccount token and Vault
issues a short-lived token per request. This replaces the recurring deadline instead of
pushing it out another 768 hours.

1. `gitops/workloads/external-secrets/vault-auth-sa.yaml` — reviewer ServiceAccount,
   `system:auth-delegator` binding, and an explicit token Secret (SAs stopped
   auto-creating these in k8s 1.24). **Inert on its own**; changes nothing about how
   ESO authenticates.
2. `ansible/playbooks/vault-eso-k8s-auth.yml` — configures `auth/kubernetes/config` and
   the `eso` role on the rpi5 Vault, then **performs a real login and says whether it
   worked**. Also inert: ESO is still on the static token throughout.
3. Swap the auth stanza in `gitops/workloads/immich/external-secret.yaml` — the
   replacement is written there, commented, ready to uncomment. **Only do this once
   step 2 reports a successful login.**

The split is deliberate: steps 1 and 2 are reversible and provably correct before
anything depends on them. Step 3 is the only one that can break ESO, and its failure is
quiet — Secrets keep their last values, so nothing appears wrong. Check
`kubectl get externalsecrets -A` for `SecretSynced` on every row, not the pod's health.

</details>

#### `token-admin` — **decided 2026-08-23: let it lapse**

**The premise of this entry was wrong, and correcting it dissolves the deadline.**

It said `token-admin` "fails silently". Operationally it does not fail at all. Checked
2026-08-23: **nothing automated uses it.** Every playbook takes `VAULT_TOKEN` from the
environment, supplied by a human or Semaphore (`backup-cloud.yml:54`,
`backup-offsite.yml:74`, `sync-secrets-to-vault.yml:33`, `vault-eso-k8s-auth.yml`). The
only unattended Vault credential is `/etc/vault.d/backup-token`
(`backup-vault.yml:14`), which is a different token and whose failure trips
`LabBackupUnitFailed`.

So an expired `token-admin` breaks nothing. It is a locked door you meet next time you do
admin work — a different problem, needing a different answer.

**Decision: do not keep it alive.** A standing token carrying the `admin` policy is a
credential that can be stolen, and not having one is strictly better. The recovery path is
documented (`docs/RUNBOOK.md` → *Root token lost*), has been performed twice (2026-08-05,
2026-08-07) and its unseal-share half was drilled in Drill 2b. Paying ~20 minutes of
ceremony on the rare occasions admin is needed is a better trade than maintaining a
permanent admin credential to avoid it.

This is the same move as the ESO half above: **the deadline was not renewed, the thing
that had one was removed.** ESO's could be designed out entirely; this one is downgraded
from "recurring obligation" to "occasional ceremony", which is as far as it goes while
something must still hold admin.

**No alert is needed**, and one would have been the wrong fix — alerting on the expiry of
a credential nothing depends on is noise that trains you to ignore alerts.

- [x] **Canonical procedure written** — `docs/OPS.md` → *Get a Vault admin token*. Covers
      the still-valid case, the expired case via `generate-root`, and why `token-admin` is
      insufficient for rekey. Referenced from `RUNBOOK.md`, `WORKFLOWS.md` and the
      playbook headers, so "how do I get a token" has one answer rather than four.
- [ ] Remove the 2026-09-06 row from the table above once this is merged — it is no longer
      a deadline, it is a date on which a token quietly stops working, by design.
- [ ] **§1.11 becomes the load-bearing entry.** With no standing admin token, the ceremony
      is the recovery path rather than a fallback. It is documented and proven, but worth
      re-reading with that weight on it — particularly the config-line-and-restart step,
      which is easy to leave enabled.

---

## 6. Documentation drift — statements that are now false

> **Cite quoted text, not line numbers.** Swept 2026-08-21: of the 18 file:line citations in
> this section, **5 still landed** on the text they claimed, and only **2 of 10 entries** had
> every citation intact. `CLAUDE.md` references had drifted 35 lines, `BACKUP-RESTORE.md` ~94.
> Line numbers into a living document decay faster than the drift they track, so the index
> rots before the problem does. New entries should anchor on a short quoted phrase or a
> stable heading; a `grep` for the phrase survives edits that renumber everything.

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

### 6.2 ~~Offsite backup claimed DONE in three places~~ — **FIXED, confirmed 2026-08-21**

All three corrected: `README.md:184-187` now states it plainly and carries its own retraction;
`docs/services.md:122-126` likewise; `docs/STANDUP.md:180-185` splits Track 1 (done) from
Track 2 (deferred). None of the cited lines still contains a DONE claim.

- [ ] **One uncorrected instance the entry never cited:** `docs/services.md:21` still says
      "offsite via `backup-offsite.timer`".
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

### 6.12 ~~An "unresolved H4 CRC fault" appears only in `docs/STANDUP.md:213-215`~~ — **THE ENTRY ITSELF WAS WRONG, corrected 2026-08-21**

The citation lands — `docs/STANDUP.md:213-215` does say "the unresolved H4 CRC fault is the one
thing that can undermine the storage tier, so clear it first". **But "appears only there" is
false.** It also appears at `docs/STANDUP.md:27-32` (full triage instruction), `:75`, `:201`, in
a dedicated procedure at `docs/RUNBOOK.md:235-287` ("UDMA CRC errors (SMART 199) — triage
BEFORE replacing a disk"), and is tracked in `docs/DOC-CONSOLIDATION-PLAN.md:232,380`.

It is a documented open thread, not an orphaned claim. Note the shape of the failure: the line
numbers were right and the prose was wrong — the reverse of every other entry in this section,
and a reminder that a citation landing does not make the sentence around it true.

- [ ] The actual hardware question is still open and is not a documentation issue:
      `for d in sda sdb; do sudo smartctl -a /dev/$d | grep UDMA_CRC; done`
Called the critical path, referenced nowhere else. Either resolved and undocumented,
or a lost thread.

### 6.13 `CLAUDE.md` protected a NAS service that does not exist — **found and corrected 2026-09-02**

`CLAUDE.md` read *"the NAS services (`smbd`/`nfs`) and the data they serve are
off-limits"*. Half of that had no referent. Measured on h4-core:

    systemctl show smbd -p LoadState      ->  LoadState=not-found
    ss -ltnp | grep -E ':(139|445)\b'     ->  (nothing)
    list-units --all | grep -iE smb|nmb|samba  ->  (nothing)

There is no Samba on this box — not stopped, not masked, **absent**. Corrected in
`CLAUDE.md` to name `nfs-server` alone, with the measurement inline so the next person
does not helpfully restore `smbd` to the sentence.

**Why this is more than a doc nit: it changes an availability statement.** "One of the
two NAS services was down" and "the only NAS export path was down" are different
sentences, and the repo has been asserting the first. `nfs-server` is the sole path to
the NAS data, and §3.16 records it exiting 1/FAILURE on 2026-07-24 and staying down
**37 days** with nothing able to alert on it. Anyone sizing that risk from `CLAUDE.md`
would have believed a second export path was available. None was.

**How it was found, which is the part worth keeping.** It surfaced from a throwaway
`systemctl is-active smbd nfs-server` added to a verification block for something else
entirely — a check that a k3s restart had stayed inside its lane. It returned
`inactive` / `active`, and `inactive` was read as "installed and stopped", producing a
round trip diagnosing a service outage that could not exist.

**`systemctl is-active` returns `inactive` for a stopped unit AND for a unit that is not
installed.** Identical word, opposite meanings, and only `LoadState` separates them.
That is the same shape as `findmnt` printing nothing whatever is mounted, `No resources
found` covering both a deleted workload and a typo'd selector, and an Alertmanager
receiver logging nothing on success — the family this repo keeps re-learning. Use
`systemctl show <unit> -p LoadState` when absence is one of the possible answers.

**A live consequence for the alerting, not yet fixed:**

- [ ] `LabSystemdUnitFailed` matches `node_systemd_unit_state{state="failed"} == 1`
      with **no `absent()` guard**. If `nfs-server` were removed rather than failed,
      its series would vanish and the alert would go *silent*, not red — the exact
      generalisation of what happened to `smbd` here. Every other watcher-watching rule
      in this file has a companion (`LabDNSProbesMissing`,
      `LabAnsibleDriftMetricMissing`, `LabPrometheusRetentionMetricMissing`); this one
      does not. Add `absent(node_systemd_unit_state{name="nfs-server.service"})` at
      minimum, since it is now known to be a single point of failure.

---

## 6b. Design proposals — captured, not committed to

Ideas worth building, written down while the reasoning is fresh. Nothing here is
scheduled; each records what it would buy, what it would cost, and what would have to
be true first.

### 6b.1 Vault as an intermediate CA issuing certificates for the whole lab

**Proposed 2026-08-21**, while scoping §2.6 (Vault on plaintext HTTP).

**The shape.** `lab-ca` (the cert-manager self-signed root) stays the root. Vault's PKI
secrets engine gets an intermediate signed by it, and issues certs for lab devices —
Vault itself, the bare hosts that have no TLS today (rpi5, the Pis, the N150s), and
potentially in-cluster workloads via cert-manager's first-class `Vault` issuer.

**What it buys**

- One trust root, distributed once, instead of a self-signed cert per service and a
  growing set of exceptions.
- Short-lived certs with real rotation, rather than long-lived certs nobody tracks.
- TLS for the ~14 hosts that currently have none. Only cluster workloads get certs today.
- It is squarely the kind of thing `docs/LAB-DESIGN.md` says this lab exists to practise.

**Break the circular dependency permanently, not just at bootstrap.** Vault cannot issue
its own first certificate: no cert means no HTTPS means no API to call. The common fix is
to bootstrap once over the plaintext listener, which leaves the circularity in place for
every future rebuild. Better: **Vault's own certificate is signed directly by the root,
once, by Ansible; Vault's intermediate issues everything else.** Vault then never depends
on itself, and a bare-metal Vault rebuild does not require a working Vault.

**The cost that is easy to miss: renewal machinery on bare hosts.** Short-lived certs are
the point, and they need automated renewal. cert-manager covers the cluster. Outside it
that means `vault-agent` or cron+script on each host — including three OPi Zero 2Ws and
an RPi 3B. A renewal that silently stops is exactly the failure class this document is
full of, and it would be spread across fourteen machines instead of one.

**The objection to weigh heaviest.** This makes Vault a hard dependency for identity
everywhere. Today a Vault outage is *degraded*: ESO stops syncing but existing Secrets
persist, and backups cannot fetch R2 credentials. With Vault as CA, certificates stop
renewing, and when they expire services stop trusting each other.

And Vault is, by this document's own accounting, the least robust component in the lab:
§2.11 it cannot be sealed deliberately, §2.12 it is never restarted so it silently runs
an old binary, §1.11 regaining admin needs a `generate-root` ceremony, §5 its admin token
expires 2026-09-06. Single node, raft, `disable_mlock = true`, on a Raspberry Pi 5.

> **Do not make Vault the root of trust for the lab while Vault is the component with the
> most open reliability items against it.**

**Prerequisites, in order**

1. **§2.6 fixed minimally first** — one root-signed cert for Vault, staged behind a second
   TLS listener so nothing has a flag day. Closes the actual hole in ~1 day and forecloses
   nothing here.
2. **§5, §2.11, §2.12 cleared.** Deadline, sealing, and restart/version reporting. These
   are cheap and they are what "trusting Vault with more" actually rests on.
3. **A decision on renewal scope** — which hosts get automated short-lived certs, and which
   get long-lived certs and a calendar entry. Doing all fourteen is not obviously right.

**Related:** §2.6 (the immediate hole), §1.11 and §2.11-2.12 (Vault fragility), §8 (if
remote access is ever un-deferred, this becomes considerably more attractive, because
LAN-only plaintext stops being defensible at all).

---

### 6b.2 Host firewalls — discover the flows before writing any rules

**Proposed 2026-08-21.** §2.9 is the finding; this is how to act on it without taking the
lab down.

**Why not just write rules.** A naive default-deny breaks this cluster immediately. k3s
needs 6443 (API), 10250 (kubelet), 2379-2380 (embedded etcd, server-to-server), 8472/udp
(flannel VXLAN); kube-vip needs ARP/VRRP on the VIP subnet; the H4 additionally serves
SMB and NFS to the LAN, and NFS in particular negotiates ports that are not obvious from
a config file. Getting one of those wrong on the H4 means losing the NAS, the API server
and the ingress VIP simultaneously — from a machine you are connected to over SSH.

**The lesson from `netplan try` applies directly.** Any firewall change on the H4 needs a
timed auto-revert, not an apply-and-hope. `ufw`/`nft` have no equivalent, so the pattern
is a systemd timer that flushes the ruleset after N minutes unless cancelled.

**Do it in the right order — and note this only became possible this week.**

1. **Log-only first.** An `nftables` ruleset that matches what a deny rule *would* match
   and logs instead of dropping. Run it for a week.
2. **Read the logs.** Journal shipping to Loki now works on all five cluster nodes
   (§3.9, fixed 2026-08-21) and Kubernetes Events are captured (`alloy-events`), so the
   actual flows are observable for the first time. A week ago this step was impossible —
   the H4 shipped no host logs at all.
3. **Then enforce**, per role rather than uniformly: the H4 (NAS + server), the N150s
   (servers + KVM), the OPi5s (agents), and the standalone Pis have genuinely different
   surfaces.
4. Codify in Ansible with a revert timer, `--check` first, H4 last.

**What it buys.** It is the control that makes every other "fine on a trusted LAN"
acceptance in §2 honest — §2.6, §2.1, and the §2.13 token decision all rest on the LAN
being trusted, and nothing currently enforces even the weak version of that.

**Related:** §2.9 (the finding), §2.6, §6b.3 (which subsumes this if pursued).

---

### 6b.3 Zero trust — and the acceptances it would invalidate

**Proposed 2026-08-21.** The idea: stop granting trust on the basis of network location.
Vault is already the natural centre of it, and §6b.1 is the substrate.

**What it would concretely mean here**

- **mTLS between services**, which needs the PKI in §6b.1 — this is why that comes first.
- **Identity-based access rather than IP-based.** Authelia and lldap already exist and
  cover the web tier; the gap is everything non-HTTP.
- **Short-lived, dynamically issued credentials.** Vault's database secrets engine could
  replace the static Postgres passwords for Immich, Authelia and Semaphore that currently
  sit in Vault as long-lived KV entries — a meaningfully better use of Vault than as a
  password box.
- **Per-service authorisation**, not "on the LAN therefore allowed".

**The part worth stating plainly.** Zero trust is the position that the LAN is not
trusted. **Adopting it as a goal invalidates the reasoning behind several current
acceptances** — §2.6 (plaintext Vault is "fine on a trusted LAN"), §2.9 (no firewall),
§2.1 (unauthenticated Pi-hole admin), and the §2.13 decision to accept the k3s token
exposure, which rests explicitly on the threat model being "someone already on my LAN".

Those acceptances are defensible today. They are not defensible under a zero-trust goal.
So this is not an additive project — picking it up means re-opening decisions already
made, and that should be a conscious choice rather than a discovery halfway through.

**Realistic scope for a lab this size.** The full doctrine is not the goal; the parts with
the best ratio are. In rough order of value per unit of pain:

1. **Vault dynamic database credentials** — replaces the static Postgres passwords for
   Immich, Authelia and Semaphore. Self-contained, no PKI dependency, and a better use of
   Vault than a password box. Start here.
2. **Time-limited SSH via Vault-signed certificates** — §6b.4. The widest-reaching
   credential in the lab and currently the only one with no expiry at all. Carries the
   sharpest recovery-path risk, so it needs envelope item 7 first.
3. **mTLS on the highest-value paths only** — needs §6b.1.
4. **Extending SSO coverage** to what Authelia does not yet reach.
5. **Network policy.** `NetworkPolicy` resources already exist for `ai-gateway`,
   `authelia` and `lldap`, so the cluster half has a starting point; §6b.2 covers hosts.

**Prerequisites:** §6b.1 (PKI), and the same Vault-fragility items — §5, §2.11, §2.12 —
that gate everything else built on Vault.

---

### 6b.4 Time-limited SSH via Vault-signed certificates

**Proposed 2026-08-21.** Vault's SSH secrets engine in **CA mode** — Vault signs a user's
public key into a short-TTL certificate; hosts trust the CA via `TrustedUserCAKeys` in
`sshd_config`. Not OTP mode, which needs `vault-ssh-helper` resident on all fourteen hosts.

**What it buys.** `authorized_keys` stops being something to distribute — hosts trust a CA
rather than an enumerated list, which today is hand-managed via
`ansible.posix.authorized_key` (`bootstrap.yml:36`) and grows silently. Certificates expire,
so a stolen private key is worthless tomorrow. Principals encode who may log in as whom.
And Vault logs every signing request, which would be this lab's first real SSH audit trail.

**The circular dependency is the sharpest of any proposal here.** SSH is the recovery path
for everything, *including Vault*. If Vault is down and your certificate expired an hour
ago, you cannot log in to fix Vault. That is worse than §6b.1's case, where a stale cert
degrades trust between services; here it removes the means of repair.

> **A permanent break-glass key in `authorized_keys` on every host is mandatory, not
> optional — and becomes envelope item 7.** Vault-signed certs are for day-to-day access;
> the emergency key is the floor beneath them.

**Where this actually stalls: Ansible.** Plays run from the H4 and the Windows checkout
against fourteen hosts. If SSH requires a signed certificate, so does Ansible, and it
expires mid-week. Either a wrapper signs before each run, or the automation identity gets a
longer-lived certificate. If the answer becomes "Ansible uses the break-glass key", the
whole exercise is theatre — decide this before starting, not after.

**Fleet-specific risk.** A bad `sshd_config` on a headless OPi Zero 2W or the RPi 3B means
a reflash, not a console login. Roll it out with `--check` first, one host at a time,
lowest-value hosts first, H4 and rpi5 last — and keep an open second SSH session on each
host while changing it, so a broken config can be reverted through the existing connection.

**Prerequisites**

1. Envelope item 7 printed and stored *before* any host trusts the CA.
2. The Vault fragility items — §5, §2.11, §2.12 — same as everything else built on Vault.
3. A decided answer on the Ansible identity.

**Related:** §6b.3 (this is one of its highest-value components), §6b.1 (separate PKI —
SSH CAs and X.509 CAs are different trust roots and should not be conflated),
`docs/BREAK-GLASS.md` (envelope items 1-6 today).

---

## 7. Repo hygiene

- **There are three checkouts of this repo, and audits traverse all of them.**
  Found 08-09 while grepping for `ldap.yml`, which returned every hit twice:

      ~/lab/homelab/homelab                                        H4 working copy
      ~/lab/homelab/homelab/actions-runner/_work/HomeLab/HomeLab   runner checkout
      C:\Users\wares\Downloads\files (25)\homelab\homelab          Windows working copy

  The GitHub Actions runner is installed **inside** the repo, so its workspace holds a
  second, stale copy nested within the first. Correctly gitignored (`.gitignore:25`), so
  nothing reaches git — but every `grep -rn`, `find` and audit walks it and reports stale
  content as if it were live. That is exactly how the `ldap.yml` sweep doubled.

  Move the runner outside the repo (`~/actions-runner`), or at minimum pass
  `--exclude-dir=actions-runner` in any sweep. CLAUDE.md already warns that the two
  checkouts are invisible to each other; a third nested inside one of them is worse,
  because it is invisible to `git status` in *both*.

  **Recovered 2026-08-27 from a stash that was nearly dropped**, and it existed nowhere
  else — `grep -c "three checkouts of this repo"` against `origin/main:BACKLOG.md`
  returned 0. A finding parked in `git stash` is one `git stash drop` from gone, and the
  stash list is not a place anyone looks. If it is worth keeping, it goes in a file.

  Scope, checked 2026-08-27: **the Windows copy has no `actions-runner/` and no nested
  `HomeLab/`**, so sweeps run there are clean. This bites sweeps run on the H4.

- **`ansible/playbooks/sandbox-vm-update.yml` references `bootstrap-lldap.yml`** in a
  comment (1 hit, confirmed still present 2026-08-27). That playbook was deleted on
  08-03. Cosmetic, but it is the kind of stale pointer that sends someone looking for a
  file that has not existed for weeks.

- **`Makefile:2` still lists `ldap` in `.PHONY`** though the target was removed on
  08-09 and the file carries a comment explaining the removal. Harmless; finish the job.

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

### 8.1 kube-vip v1.x (Renovate PR #158) — parked deliberately, blocker under-recorded

**Opened ~2026-07, still open 2026-08-29.** `chore(deps): update ghcr.io/kube-vip/kube-vip
Docker tag to v1`, against the current pin `v0.9.2` in
`gitops/workloads/kube-vip/daemonset.yaml:32`.

**It is parked, not forgotten.** The PR was raised before there was appetite to work it,
and the check performed at the time concluded the lab does not support the newer API
version kube-vip v1.x requires.

**What is not recorded, and should have been: which API, and which version.** "Newer API
version not supported" is the whole of the surviving detail. That is enough to justify not
merging and not enough for the next person — or the same person in three months — to
evaluate it without repeating the work. The cluster runs `k3s v1.36.2+k3s1`
(`inventory/group_vars/all/k3s.yml:7`), which is recent, so the constraint is probably
narrower than a cluster-version floor: a specific API group/version, a CRD, or a k3s
feature gate. Nobody wrote down which.

**Why it deserves the care rather than a merge-and-see.** kube-vip owns **both** VIPs —
`api.lab.home.arpa` → `192.168.1.200` (control plane) and `*.apps.lab.home.arpa` →
`192.168.1.201` (Traefik). §6.1 records that a single wrong DNS record for the second one
took down every service URL in the lab. A major-version bump on the DaemonSet holding both
is not a routine dependency update, and `requiredDuringScheduling` nodeAffinity puts it on
all three control-plane nodes at once.

**To do, in order of cost:**

- [ ] **Cheapest, and do it first: comment the finding on PR #158 itself.** One line naming
      the actual requirement puts the knowledge next to the thing it is about. Right now it
      exists only in memory, and a parked PR with no stated reason is indistinguishable from
      an abandoned one — which is how it read when it surfaced in `gh pr list` on 08-29.
- [ ] Capture the specific floor (API group/version or feature gate) here when it is next
      looked at, so the revisit trigger below can actually be evaluated.
- [ ] **Revisit at the next k3s upgrade.** `docs/UPDATES.md` §2 already gates those and
      already carries the §2.13 token rotation; this belongs in the same checklist, since a
      cluster-version change is the most likely thing to move the blocker.

**If remote access is ever un-deferred, read §4.12 and §4.16 first.** Tailscale's
MagicDNS installs itself as a resolver and rewrites systemd-resolved state — the exact
layer that produced three separate merge bugs on 2026-08-21 (netplan merging nameserver
lists across files, resolved merging across links, resolved merging across config
files). On a cluster node it would become a fourth contributor to a list the kubelet
already truncates at three, and it would do so at Tailscale's discretion rather than
git's. Use `--accept-dns=false` on anything running k3s, and decide §4.16 before
installing rather than after — adding a resolver to an unresolved ownership question is
how the `.152` entry survived for months.

**Vault transit / cloud-KMS auto-unseal** — the only real escape from the trade in §2.5,
where auto-unseal requires a threshold of shares on the RPi5 and therefore makes root
there equivalent to full Vault access. Rejected because it introduces an external
dependency (or a second Vault) in the recovery path, which is the opposite of what the
break-glass work is for. Revisit only if the RPi5 stops being trusted.

---

### 3.13 ~~ApplicationSet name collisions are silent until Argo prunes something~~ — **GUARDED 2026-08-21**

**Found the hard way, same day.** `gitops/workloads/external-secrets/` was created without
adding the matching exclusion to `workloads-appset.yaml`. That generator names Applications
`{{path.basename}}`, so two Applications then claimed the name `external-secrets`: the
hand-declared Helm chart, and a generated one pointing at a directory containing three RBAC
objects. The generated one won, and its `prune: true` **deleted the entire external-secrets
Helm release**. The operator was gone for roughly twenty minutes.

**Nothing appeared to break, which is the part worth remembering.** The CRDs and all 16
ExternalSecret CRs survived, and the target Secrets carry ownerReferences to those CRs, so
every workload kept running on its existing values and every ExternalSecret still reported
`True` — a stale condition nobody was reconciling. The blast radius was "no secret can ever
refresh again", and it was invisible in every summary view.

**The generator had 11 exclusions before this, every one for the same reason** — a directory
basename colliding with a hand-declared Application. The pattern was documented in comments
and enforced nowhere, so the twelfth was a matter of time.

**Guarded by `scripts/check-appset-collisions.py`**, wired into `.github/workflows/validate.yml`.
It fails on:

- **collision** — a workload directory whose basename matches a declared Application and is
  not excluded (the destructive case);
- **orphan** — a directory that *is* excluded but which no Application deploys, so its
  manifests sit in git and never reach the cluster (silent no-op, equally invisible).

None of the existing CI jobs would have caught this: the YAML was valid, the schema was
valid, and no OPA policy covers cross-file naming. It was only detectable by knowing how the
generator constructs names — which is exactly the kind of thing to encode once rather than
remember eleven times.

Verified by reproducing the bug against a copy of the repo and confirming the check exits 1
with the right message, not merely that it passes on a healthy tree. It also caught a false
positive in its own first version — `gitlab-runner` uses multi-source `sources:` rather than
`source:` — which is worth noting because a check that cries wolf gets switched off.

---

### 3.12 ~~Four machines appear twice in the inventory under two names~~ — **FIXED 2026-08-28**

> Collapsed to one entry per machine, under the **hardware** name — the `dns-N` aliases
> were the duplicates, so they are the ones that went:
>
>     dns-1 -> octopi-dns     dns-2 -> opi-zero2w-1
>     dns-3 -> rpi4b          dns-4 -> opi-zero2w-3
>
> **21 inventory entries described 17 machines. Now 17 entries, 17 distinct IPs.**
> `dns_role` and `dns_engine` moved onto the surviving entries, so the `dns` group still
> resolves the same four hosts with the same variables.
>
> **The proof is a count Ansible produces, not a claim about the file:**
>
>     ansible 'all:!x86_nodes:!embedded' -i inventory/hosts.yml --list-hosts | wc -l
>     19 before  ->  15 after      (a header line plus 18 hosts, then 14)
>
> Down by exactly four. `ansible dns --list-hosts` returns the four hardware names, and
> `ansible-inventory --list | grep -c 'dns-[1-4]'` returns 0. Confirmed again in a live
> run the same day: `dns.yml --limit rpi4b` skipped *Set dns_engine from OS family*
> because the deduped entry now carries `dns_engine` explicitly.
>
> **The entry called this "mostly cosmetic until something counts hosts". Something
> already did.** Group memberships were disjoint, so no single-group play ever collided
> — but **six plays target `all` and no exclusion caught these four**: `bootstrap.yml`,
> `rotate-passwords.yml`, `break-glass-key.yml`, `apport.yml`, `journald.yml` and
> `chrony.yml`, the last of which has two plays and therefore made **four passes** per
> machine. Every task involved is idempotent, so nothing broke. What it would have broken
> is §3.11's scheduled `--check` drift report: doubled `changed` counts on four hosts, in
> the one mechanism built to detect disagreement between git and the machines.
>
> Only one *runnable* reference had to move — `update-non-apt.yml`'s `hosts: dns-1`.
> `bootstrap.yml`'s usage example was corrected too, on the grounds that a comment
> someone pastes is not really a comment. Old names are deliberately left in narrative
> comments (`chrony.yml`, `node-dns.yml`, `docs/UPDATES.md`, `scripts/lab-check.sh`
> labels); the mapping lives in the inventory now, and a mechanical diff is easier to
> review when it is only mechanical.

**Original finding, retained for the evidence it records:**

**Confirmed with evidence 2026-08-26.** A fleet-wide `chrony.yml` run printed byte-identical
`chronyc tracking` output — same Reference ID, same offsets to the nanosecond — for three
pairs: `dns-1`/`octopi-dns` (.148), `dns-3`/`rpi4b` (.116), `dns-4`/`opi-zero2w-3` (.217).
`dns-2`/`opi-zero2w-1` (.184) both failed with the same `No route to host`. So the playbook
configured, verified and reported on the same machines twice, and a run that says 13 hosts
succeeded actually touched about 10.

That is mostly cosmetic until something counts hosts — a rolling reboot, a quorum check, or
an alert threshold — and then it is not.


**Found 2026-08-21** while running `break-glass-key.yml` against `all`, which reported 18
hosts for a 14-machine fleet:

| IP | Inventory names |
|---|---|
| `192.168.1.148` | `dns-1`, `octopi-dns` |
| `192.168.1.184` | `dns-2`, `opi-zero2w-1` |
| `192.168.1.116` | `dns-3`, `rpi4b` |
| `192.168.1.217` | `dns-4`, `opi-zero2w-3` |

The `dns` group names the DNS *role*; the other names name the *machine*. Both resolve to
the same host, so any play targeting `all` visits those four twice.

**Mostly harmless, occasionally not.** Idempotent plays just do the work twice — visible in
the break-glass run, where the second visit reported `ok` because the first had already
installed the key. A non-idempotent play would apply itself twice. And every host count,
report and `PLAY RECAP` overstates the fleet by four.

It also confuses failure attribution: three hosts passed verification in that run, but two
of them were the same machine, which briefly looked like three independent data points.

- [ ] Decide whether the `dns` group should use the machine names as members
      (`dns: hosts: [octopi-dns, rpi4b, opi-zero2w-1, opi-zero2w-3]`) rather than defining
      parallel entries with their own `ansible_host`. That keeps the role grouping and
      removes the duplicate identity.

Related: §3.10 and §4.14 — the fleet's identity is inconsistent at the host level too.

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

---

**§4.12 N150 RESOLUTION, 2026-09-01 — the entry's own diagnosis was incomplete.**

This section assumed the N150 warning was a *union* problem: our routing-only drop-in
plus DHCP-supplied global resolvers, unavoidable without suppressing DHCP DNS. That was
half right. Suppressing DHCP DNS was indeed the fix for the count — but the same file
carried a second, worse defect that nobody had looked for.

**Two netplan files contradicted each other, and the wrong one won:**

    10-kvm-bridge.yaml   enp1s0:  dhcp4: no      <- correct; it is a bridge port
    50-cloud-init.yaml   enp1s0:  dhcp4: true    <- and 50 sorts after 10, so THIS won

`netplan get ethernets.enp1s0` returned `dhcp4: true`, and the generated unit proved
the consequence — `DHCP=ipv4` and `Bridge=br0` in the same stanza. **A bridge port
running its own DHCP client, which can never complete**, so networkd never marked the
link `configured`. That is why `systemd-networkd-wait-online` failed on n150-1 since
2026-06-29 and n150-2 since 2026-07-25 (§3.16), and §3.16's br0-scoped drop-in was a
correct workaround for a cause nobody had found yet.

Cloud-init network regeneration was **not disabled** on either hypervisor, so
`50-cloud-init.yaml` was rewritten at every boot — editing it would have achieved
nothing. The H4 has carried that disable stanza since this entry was written; the
hypervisors never got it.

Fixed by `playbooks/kvm-netplan-fix.yml`: disable cloud-init networking, remove the
conflicting file (pristine copies to `/var/backups/netplan/`), and add
`dhcp4-overrides: {use-dns: false}` to br0. Measured after applying:

    nameserver lines   5 -> 3
    enp1s0 setup       configuring -> configured
    n150-1 VIPs        .200 and .201 survived the apply
    new pod on n150-1  no DNSConfigForming event

**`netplan try` cannot be used on these hosts** and this is worth remembering:

    br0: reverting custom parameters for bridges and bonds is not supported

It refuses for any bridge with `parameters:`, applying nothing. A `systemd-run
--on-active` revert timer, armed before the apply and cancelled after verification,
gives the same guarantee. The playbook header carries the exact procedure.

**Method note.** The `DNSConfigForming` events kept updating their timestamps after the
fix, because Kubernetes refreshes `lastTimestamp` on recurrence and existing pods keep
their old `resolv.conf`. Read casually that says the fix failed. The honest test was to
delete a DaemonSet pod and check whether the *replacement* emitted the event. It did
not.
