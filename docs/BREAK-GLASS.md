# Break-glass envelope

**This file is the template. It contains no secrets and never should.**
The filled copy lives offline — printed, or on an encrypted USB stored somewhere
other than the house. If the filled copy is ever committed, treat every credential
in it as compromised and rotate all of them.

## Why this exists

Recovery from total loss needs credentials that are stored inside the thing you
lost. `docs/RUNBOOK.md` says to get the restic password from Vault. Vault runs on
the RPi5 and its raft snapshots live on `/mnt/cold-8t` — on the H4. Lose the H4 and
you need restic to recover, and Vault to get restic's password.

No automation closes that loop. Something has to live outside both systems.

## Contents

Fill each value from the source column, on a machine you trust, and write it into
the offline copy. Do not paste any of these into a terminal that logs, a chat, or a
file inside the repo.

| # | What | Source | Without it |
|---|------|--------|-----------|
| 1 | restic repository password | `/etc/restic/password` on the H4 | `/mnt/cold-8t/restic` and `/mnt/cold-sec/restic` are undecryptable ciphertext |
| 2 | R2 restic password | `/etc/restic/cloud-password` on the H4 | **both** R2 repos are undecryptable — `homelab-backup` and `homelab-nas` share this password |
| 3 | R2 account ID, access key ID, secret access key | `secret/lab/cloudflare-r2` in Vault, or `/etc/restic/cloud.env` | you cannot reach the R2 buckets at all |
| 4 | k3s server token | `/var/lib/rancher/k3s/server/node-token` on the H4 | etcd snapshots cannot be restored onto new hardware — k3s derives the datastore key from it |
| 5 | Vault unseal shares — **print all five**; threshold is 3 | `/etc/vault.d/unseal-keys` on the **RPi5** (`192.168.1.128`), `root:root 0400`, one key per line | Vault stays sealed; every ExternalSecret stays empty |
| 5b | **Superseded** unseal shares — **all five**, labelled with the date they were replaced and a destroy-after date | Wherever the previous set was recorded. After a rekey they exist nowhere else — the live file has been overwritten | Vault snapshots taken *before* the rekey cannot be opened. See below |
| 6 | Ansible vault password | `ansible/.vault_pass` | encrypted group_vars are unreadable, so no playbook that touches them runs |

**Not a secret, but write it down anyway** — you will not have the repo:

| What | Value |
|------|-------|
| Offsite NAS repo | `s3:https://<R2-ACCOUNT-ID>.r2.cloudflarestorage.com/homelab-nas` |
| Offsite cluster-state repo | `s3:https://<R2-ACCOUNT-ID>.r2.cloudflarestorage.com/homelab-backup` |
| Git remote | `git@github.com:swares/HomeLab.git` |
| Vault address | `http://192.168.1.128:8200` |

### A note on item 5

`vault-unseal.service` on the RPi5 reads shares from `/etc/vault.d/unseal-keys` at boot,
which is why Vault comes back unsealed after a restart without anyone typing anything.

- **Root on the RPi5 is equivalent to full Vault access.** The keys sit beside the data
  they unseal. This is a deliberate trade, not an oversight: under Shamir, auto-unseal and
  "no single location can unseal" are mutually exclusive, and auto-unseal was chosen
  because Vault gates every ExternalSecret. `docs/SECURITY.md` states this plainly now —
  it previously described the shares as "Offline, physically secure", which was false.
- **The envelope is the off-site redundant copy**, not a second line of defence against
  RPi5 compromise. Losing both the RPi5 and this envelope leaves Vault permanently sealed.
- **Print all five shares.** Three is the threshold, so five is no less secure — but a
  smudged character at 2am costs nothing if you have spares.
- **Rekey rather than hunt for stray copies.** `vault operator rekey` invalidates every
  existing share at once, which is stronger than deleting a copy you cannot prove is
  gone — see the flash-storage note under *Residual risk* below, which applies equally to
  a laptop. Procedure in `docs/OPS.md`, "Rekey Vault unseal shares". Rekeying also settles
  the old question of where shares 4 and 5 were: afterwards, the only shares that exist
  are the ones you just wrote down.
- **Do not add comments or labels to the unseal file.** `vault-unseal.sh` skips blank
  lines only; any other non-key line is passed to `vault operator unseal`, fails, and
  aborts the unit under `set -euo pipefail` — Vault stays sealed on boot. Keys only.

### Item 5b — why superseded shares stay in the envelope

**A rekey does not re-encrypt snapshots already taken.** A Vault raft snapshot carries the
barrier keyring as it was, so a pre-rekey snapshot is opened by the **old** shares and
nothing else. Those snapshots persist for **30 days** on `/mnt/cold-8t/vault-snapshots`
(`backup-vault.yml:18`) and up to **~3 months** in the R2 `homelab-backup` repo
(`--keep-monthly 3`). Discard the old shares and you discard every restore point older
than the rekey.

So the envelope carries two labelled sets. Keep **all five** of the superseded set, not
three: the threshold is 3, and a set of exactly 3 has no tolerance for one mistranscribed
character.

**Capture the outgoing shares before you overwrite the file.** `sudo cat
/etc/vault.d/unseal-keys` shows only what is currently live — after the rewrite, shares
that existed nowhere else are gone. If part of the outgoing set lived somewhere separate
(a workstation file, a second envelope), collect *that* part first; the live file alone
may hold fewer than the threshold.

Record them as:

    OLD — replaced 2026-08-16. Opens Vault snapshots taken before that date only.
    Destroy after 2026-11-16, once the last pre-rekey monthly has aged out of R2.

Diary the destroy date. A superseded set with no expiry becomes a permanent second copy of
full Vault access, which is the opposite of what the rekey was for.

      # if you still want to check for strays before rekeying:
      sudo find /etc /root /home -name 'unseal*' 2>/dev/null

## After printing — cleanup

Printing this document puts every credential in the lab into a CUPS spool file, a
pandoc temp directory, and onto paper. On 2026-08-15 a first attempt left **twenty**
rendered copies in `/var/spool/cups/` for fifteen hours. `scripts/print-offline-envelope.sh`
now handles the machine side; the rest is yours.

### Automated by the script

- Renders into `/dev/shm` (tmpfs — never touches persistent storage) and shreds it
  on any exit path, including Ctrl-C and errors
- Waits for the print queue to drain, **then** purges the CUPS spool, job cache and
  `tmp/` — purging before the job prints would cancel it
- Truncates the CUPS logs

### Manual — the script cannot do these

1. **Destroy every draft.** Cross-cut shred or burn. Strip-cut can be reassembled.
   Iterating on the layout produces a stack of complete credential dumps, and this
   is the copy that needs no root access to read.
2. **Power-cycle the printer.** A Brother HL-5100DN buffers jobs in RAM; a power
   cycle clears it. Check its web UI for secure-print or reprint storage while you
   are there — if the model has a disk, that is a longer conversation.
3. **Store the keeper copy off the property.** An envelope in the same building as
   the H4 solves the credential problem and not the fire.
4. **Tick the currency table below** for anything that has rotated since the last
   printing.

### Residual risk worth knowing

`rm` and `shred` do not reliably destroy data on flash storage — wear levelling
means the original blocks may persist regardless. `/var/spool/cups` lives on the
H4's eMMC. Removing the files is still correct and worth doing; just do not mistake
it for erasure. The `/dev/shm` rendering path avoids the problem entirely by never
writing to disk in the first place, which is why it is preferred over cleaning up
afterwards.

## Currency

A stale envelope is worse than none, because you will trust it. Anything that
rotates a credential in the table above **must** be followed by updating the
offline copy in the same sitting.

Checkboxes are `[  ]` rather than a ballot-box glyph (U+2610) deliberately — that
character is absent from Latin Modern, so xelatex drops it and the column you are
meant to tick prints blank. Keep this table to ASCII.

The glyph is named here rather than shown, for the same reason. Until 2026-08-16 this
paragraph contained a literal U+2610: the warning against the character was written
using the character, so every render logged a `Missing character` warning for it and
the printed sentence read "rather than&nbsp;&nbsp;deliberately", with a hole where the
example should have been. An example you cannot see in the output it describes is not
an example.

**Do not quote the warning text verbatim either.** The first attempt at this paragraph
reintroduced U+2610 inside a code span while explaining why not to use it. Refer to the
codepoint; never paste the glyph.

| Date | What changed | Envelope updated? |
|------|--------------|-------------------|
| 2026-08-07 | restic repository password rotated (#1) | `[x]` 08-17 |
| 2026-08-07 | Vault root token revoked — item 5 no longer includes one | `[x]` 08-17 |
| 2026-08-07 | offsite repo `homelab-nas` created, reusing the R2 restic password (#2) | `[x]` 08-17 |
| 2026-08-16 | Vault unseal shares **rekeyed** — all five of item 5 are new | `[x]` 08-17 |
| 2026-08-16 | superseded shares become item 5b — destroy after 2026-11-16 | `[x]` 08-17 |

**Envelope printed and in use from 2026-08-17.** All rows above are propagated. Item 1 and
items 2, 3 are additionally *proven* rather than assumed — Drills 1 and 2a opened real
repositories with them. Item 5 is proven against the live server but not yet against a
snapshot; that is Drill 2b.

## The drill

An untested restore is a belief, not a backup. **Drill 1 passed 2026-08-16** — the first
restore ever performed in this lab; see Results below. **Drill 2 has never been run**, so
cluster state, the Vault raft snapshots and envelope items 1, 4, 5 and 6 remain untested.

The drill is only meaningful if it simulates the loss it exists for. That means:

- **Run it on a host that is not the H4.** Restoring on the machine that still has
  the local repos, the config and the credentials proves almost nothing.
- **Use only the envelope.** If you find yourself reaching for something not on the
  list, the list is wrong — stop and add it.
- **Time it, and write the time down.** "It works" is less useful than "it takes
  four hours", which is what you actually need to know at 2am.

### Drill 1 — data restore from offsite (start here)

Bounded, read-only, and proves the chain: envelope → R2 → plaintext.

> **Corrected 2026-08-15.** The earlier version of this procedure restored
> `--include /srv/nas/<a known file>`. **`/srv/nas` is empty** — `BACKLOG.md` §1.10
> confirms it, by design, until the Immich migration. That drill would have restored
> zero bytes, exited 0, and been recorded as a pass. The same shape as `backup-offsite`
> reporting success for weeks without copying a byte. **Restore something that exists,
> and assert on its size.**

#### What is actually in the repo

Per §1.10, inspected 2026-08-13 — 35 files, and after the VHDX was dropped from
`backup-nas` on 08-13 the only real content is:

| Path | Contents |
|---|---|
| `/mnt/cold-8t/immich/backups/*.sql.gz` | **~250 MiB of nightly Postgres dumps — restore one of these** |
| `/mnt/cold-8t/immich/{library,upload,thumbs,profile,encoded-video}/.immich` | 13-byte init markers |
| `/srv/nas` | empty |

Snapshots older than 08-13 also hold `YIKW.VHDX` (224.7 GiB). Do not target it.

#### Scope — what this drill does and does not prove

Drill 1 uses **envelope items 2 and 3 only** (R2 restic password; R2 account ID and
API keys), plus the repo URL from the non-secret table. Passing it says nothing about
items 1, 4, 5 or 6 — the local restic password, k3s server token, Vault unseal shares
and Ansible vault password are all exercised by Drill 2. Do not record Drill 1 as
"envelope verified".

#### Host — a throwaway VM

**Provision a disposable VM, run the drill in it, destroy it.** Not a permanent node.
Three reasons, the third being the one that matters most:

1. **Clean room.** No restic, no `/etc/restic`, no lab config to fall back on — so "use
   only the envelope" is enforced rather than promised.
2. **Repeatable.** A fresh VM each time means the drill measures the same thing on every
   run, instead of gradually becoming a test of one host's accumulated state.
3. **Credential hygiene.** The envelope's R2 keys are read-write and reach the only
   offsite copy of the lab. On a permanent node they persist in `~/.bash_history`, in the
   environment, and the restored plaintext Postgres dump sits in `/tmp` indefinitely.
   Destroying the VM takes all of it at once.

`ansible/playbooks/create-vm.yml` already does this — Ubuntu 24.04 cloud image onto the
`kvm_hosts` group:

```bash
cd ~/lab/homelab/homelab/ansible
ansible-playbook -i inventory/hosts.yml playbooks/create-vm.yml -l n150-2 \
  -e "vm_name=drill-1 vm_ram_mb=2048 vm_vcpus=2 vm_disk_gb=20"
```

Host it on **n150-2**, not n150-1 (which carries the monitoring stack). 20 GB is ample —
the restore is ~250 MiB.

**Consider the isolated network.** `sandbox-vm-update.yml` builds a `sandbox-nat` network
described as *"internet via NAT, invisible to LAN"*. That is close to ideal here: the VM
can reach R2 but **cannot reach the H4, Vault, or anything else it might cheat with**,
which turns "do not reach outside the envelope" from discipline into a property of the
network. `create-vm.yml` defaults to `vm_bridge: br0`, so this needs an override, and
`sandbox-nat` may only exist while `sandbox-vm-update.yml` has run — **verify it exists
before relying on it** (`virsh net-list --all` on n150-2). Falling back to `br0` is fine;
the isolation is a bonus, not a requirement.

It does not complicate pass criterion 4: read the H4's `sha256sum` separately and compare
the two 64-character strings by eye.

Install restic from the distro inside the VM. Version does not matter for reading —
this drill never writes.

#### Before you start

1. **The envelope must exist and be current.** §1.2 is a prerequisite, not a parallel
   task — a drill run from credentials you read off the H4 proves nothing. Three rows in
   the currency table above are unticked; fill and print via
   `scripts/print-offline-envelope.sh` first.
2. **Do not run between 02:25 and 02:40 UTC.** `backup-offsite.timer` fires at 02:30.
   §1.9 is the lesson: a long restic operation holding a lock starved the nightly job for
   four nights.
3. **Never run these from the drill host:** `forget`, `prune`, `init`, `migrate`, `copy`,
   `unlock`. The envelope's R2 credentials are read-write, so a typo reaches the only
   offsite copy of the lab. CLAUDE.md forbids hand-running retention anywhere.

#### Procedure

```bash
# --- on n150-2, as yourself. Values from the OFFLINE envelope only. ---
sudo apt-get install -y restic
export AWS_ACCESS_KEY_ID='<envelope item 3: access key id>'
export AWS_SECRET_ACCESS_KEY='<envelope item 3: secret access key>'
export RESTIC_REPOSITORY='s3:https://<envelope item 3: account id>.r2.cloudflarestorage.com/homelab-nas'

date -u +%FT%TZ                                  # START — write this down

restic snapshots --tag nas --latest 1            # prompts for envelope item 2
restic ls latest /mnt/cold-8t/immich/backups | tail -5   # pick a real filename

restic restore latest --target /tmp/drill \
  --include /mnt/cold-8t/immich/backups/<chosen>.sql.gz

date -u +%FT%TZ                                  # END — write this down
```

#### Pass criteria — all five

```bash
# 1. Something was actually restored. This is the check the old procedure lacked.
find /tmp/drill -name '*.sql.gz' -size +1k -printf '%s\t%p\n'

# 2. The archive is internally valid — no reference to the H4 needed.
gunzip -t /tmp/drill/mnt/cold-8t/immich/backups/<chosen>.sql.gz && echo "gzip OK"

# 3. It is a Postgres dump, not a valid-but-wrong file.
zcat /tmp/drill/mnt/cold-8t/immich/backups/<chosen>.sql.gz | head -5

# 4. Byte-identical to the original (run the second line on the H4).
sha256sum /tmp/drill/mnt/cold-8t/immich/backups/<chosen>.sql.gz
#   h4: sha256sum /mnt/cold-8t/immich/backups/<chosen>.sql.gz

# 5. Nothing outside the envelope was needed.
```

Checks 1–3 stand alone; 4 is fidelity, and needs the H4 only because this is a drill
rather than a real loss. **If check 5 failed — if you reached for anything not in the
envelope — the envelope is wrong. Stop and add it.** That outcome is more valuable than
a pass.

#### Known failure modes

| Symptom | Likely cause |
|---|---|
| `Fatal: wrong password` | Envelope item 2 stale. Item 1 rotated 2026-08-07; confirm which password the row refers to |
| `SignatureDoesNotMatch` | Clock skew on the drill host, or item 3 mistranscribed |
| `x509: certificate signed by unknown authority` | Missing `ca-certificates` on a fresh host |
| Repo opens, zero snapshots | Wrong bucket — `homelab-nas` is NAS data, `homelab-backup` is cluster state |
| Restore "succeeds", `/tmp/drill` empty | The `/srv/nas` trap. Check 1 exists to catch this |

Cost: R2 charges **no egress**, so this costs time only. That was a deliberate reason for
choosing R2 — a restore drill must never be something you avoid because of the bill.

#### Teardown — part of the drill, not an afterthought

Record the results **first** — the VM holds the only copy of the timings.

```bash
# on n150-2
virsh destroy drill-1 && virsh undefine drill-1 --remove-all-storage
```

Do this even if the drill fails. The read-write R2 credentials and the plaintext Postgres
dump go with it.

#### When it passes

Fill in the results table below, then tick §1.1 in `BACKLOG.md`. Drill 2 and the
`cold-sec` re-init (§1.9) are both gated on this.

Record the duration honestly, including time spent working out what to type. *"It works"*
is worth much less than *"it takes 40 minutes, and 25 of those were finding the right
snapshot"* — the second tells you what 2am looks like.

### Drill 2 — cluster state, split into three

`homelab-backup` holds etcd snapshots, Vault raft snapshots, the k3s server token and
the Postgres dumps. `BACKUP-RESTORE.md` lists three untested restores and they are
independent, so they are three drills rather than one. Cheapest first.

**Do these manually. Do not fix `vault-restore.yml` first** — see 2b.

Each one proves a specific envelope item. After 2c, every item has been used at least
once, which is the only honest definition of "the envelope works":

| Drill | Proves |
|:--|:--|
| 1 — offsite data restore | items 2, 3 — R2 restic password, R2 account ID + API keys. **PASSED 2026-08-16** |
| 2a — Postgres dump loads | item 1 — local restic password |
| 2b — Vault raft snapshot | **item 5 — the unseal shares** |
| 2c — etcd onto scratch | item 4 — k3s server token |

Item 6 (Ansible vault password) is exercised by any playbook run against encrypted
`group_vars`, so it needs no drill of its own.

---

#### Drill 2a — a Postgres dump actually loads

**Why this is first.** Drill 1 proved `immich-2026-08-15.sql.gz` was intact, gzip-valid
and byte-identical to the original. It did **not** prove the dump *restores*. A valid
gzip of a truncated `pg_dump` passes every check that drill ran. The lldap job already
learned this the hard way — `gitops/workloads/lldap/backup-cronjob.yaml:69-78` asserts on
size and greps for `CREATE TABLE` because **empty `pg_dump` output was found on
2026-07-25**. A dump that exists is not a dump that works.

Read from the **local** repo this time, so item 1 gets exercised rather than item 2:

```bash
export RESTIC_REPOSITORY=/mnt/cold-8t/restic
export RESTIC_PASSWORD='<envelope item 1>'      # not from Vault — that is the point
restic snapshots --tag nas --latest 1
restic restore <snapshot> --target /tmp/drill2a \
  --include /mnt/cold-8t/immich/backups/<file>.sql.gz
```

Then load it into a throwaway Postgres and count rows. Nothing here touches the live
database:

**Use the Immich Postgres image, not stock `postgres`.** The database is **Postgres 14**
with **vectorchord** and **pgvecto.rs**
(`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, per
`gitops/workloads/immich/postgres.yaml:23`). A stock image fails on `CREATE EXTENSION`,
and a newer major version will not accept a 14 dump cleanly. Matching the image is also
what the drill is meant to prove: that the dump is restorable **onto the server it came
from**, not onto some hypothetical one.

```bash
IMG=ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
docker run --rm -d --name drill2a -p 55432:5432 \
  -e POSTGRES_USER=immich -e POSTGRES_DB=immich -e POSTGRES_PASSWORD=drill "$IMG"
sleep 20

zcat /tmp/drill2a/mnt/cold-8t/immich/backups/<file>.sql.gz \
  | PGPASSWORD=drill psql -h 127.0.0.1 -p 55432 -U immich -d immich -v ON_ERROR_STOP=1

PGPASSWORD=drill psql -h 127.0.0.1 -p 55432 -U immich -d immich -c \
  "select schemaname||'.'||relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 15;"
docker rm -f drill2a
```

`POSTGRES_USER`/`POSTGRES_DB` must be `immich`: the dump is taken with
`pg_dump -U immich -d immich --clean --if-exists`
(`db-backup-cronjob.yaml:65`), so it expects that role and database to exist. `--clean`
means the load opens with `DROP ... IF EXISTS`, which emits notices against a fresh
database — notices are not errors and `ON_ERROR_STOP=1` will not trip on them.

Pass criteria:

1. `restic` opened the local repo with envelope item 1 alone — **not** a password read
   from Vault
2. `psql` completed with `ON_ERROR_STOP=1` and exited 0
3. `pg_stat_user_tables` lists Immich's tables
4. Row counts are plausible for an empty-but-initialised library (§1.10) — the point is
   that tables and constraints exist, not that there is photo data

---

#### Drill 2b — Vault raft snapshot into a scratch Vault

Restores `vault-snap-20260816-181204.snap` (the post-rekey one) into a throwaway Vault
using the **new** shares. First real test of envelope item 5.

**Do this before touching `vault-restore.yml`.** §4.6 records that playbook as broken,
but it is worse than mis-pathed: it **wipes the data directory and unpacks a tarball**
(`vault-backup-20260627.tar.gz`, in a directory nothing maintains), while your live
backups are raft snapshots restored through the API. The method does not match the
artefact. Rewriting it from the review note would replace one unverified procedure with
another. **Run it by hand, record the real sequence, then write the playbook from that.**

Throwaway VM, same pattern as Drill 1 (`create-vm.yml`, NAT network, destroyed after):

```bash
# in the VM
sudo apt-get install -y vault          # HashiCorp apt repo
# minimal config: raft storage, listener on 127.0.0.1, tls_disable
sudo systemctl start vault
export VAULT_ADDR=http://127.0.0.1:8200
vault operator init -key-shares=1 -key-threshold=1   # throwaway keys, discarded
vault operator unseal <throwaway key>

vault operator raft snapshot restore -force /tmp/vault-snap-20260816-181204.snap
```

After the restore the scratch Vault carries the **snapshot's** barrier, so it seals and
must be unsealed with the shares that were live when the snapshot was taken — envelope
item 5 for a post-rekey snapshot, item 5b for anything older.

Pass criteria:

1. `raft snapshot restore` completes
2. The scratch Vault unseals with **three of the five envelope shares**
3. `vault kv get secret/lab/restic` returns a value — data survived, not just structure
4. Record the elapsed time and the exact commands

Then destroy the VM. It briefly held every secret in the lab.

**Note `-force`.** Restoring a snapshot whose root key differs from the target cluster's
requires it. Confirm the current flag against Vault 2.x docs before running — this lab
crossed a major version on 2026-08-16 and flags have already moved once.

---

#### Drill 2c — etcd snapshot onto scratch

Hardest, and the only drill needing envelope item 4. Do it last.

Follow **[`BACKUP-RESTORE.md` §3.2](BACKUP-RESTORE.md#32-restore-cluster-state-etcd--3-server-ha)**,
which is verified against current k3s docs. Do **not** use any older etcd procedure:
`RUNBOOK.md:216-226` records that the one which used to live there invoked a
`k3s etcd-snapshot restore` subcommand that does not exist, pointed at a directory that
was never the real one, and gave single-node steps for a 3-server embedded-etcd cluster.

Snapshots are at `/mnt/cold-8t/k3s-etcd-snapshots/` (30 retained). Restoring onto new
hardware also needs the **k3s server token** — k3s derives the datastore encryption key
from it, so without item 4 the snapshot is unusable no matter how intact it is.

Pass criteria:

1. A single-node k3s comes up from the snapshot on a throwaway VM
2. `kubectl get nodes,ns` shows the restored objects
3. Restoring with the token **absent or wrong** fails — worth proving once, because it is
   the reason item 4 is in the envelope at all
4. Elapsed time recorded

A 3-server restore additionally requires wiping and rejoining the other two servers.
The drill only needs to prove the snapshot plus token yields a working datastore.

### Results

Record every drill here, including failures — a failed drill that gets fixed is
worth more than a passed one nobody remembers.

| Date | Drill | Restored | Duration | Outcome | Notes |
|------|-------|----------|----------|---------|-------|
| 2026-08-16 | 1 — offsite data restore | `immich-2026-08-15.sql.gz`, 16,662,251 B, from snapshot `23056e8d` in R2 `homelab-nas` | **9m23s** end to end (17:09:25Z→17:18:48Z); the `restic restore` itself was 3s | **PASS** — all five criteria | Details below |
| 2026-08-17 | 2a — a Postgres dump actually loads | `immich-2026-08-17.sql.gz`, 16,662,246 B, from snapshot `a6c04a33` in the **local** repo `4154928a` | **3m45s** (20:06:45Z→20:10:30Z), most of it pulling the image | **PASS** — load and envelope item 1 | Details below |

**Drill 2a, 2026-08-17 — the dump loads, and item 1 is current.**

Loaded into a throwaway `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`
container on the H4, via `docker exec -i … psql` so nothing was installed on the NAS core.

    psql exit code           0, under -v ON_ERROR_STOP=1
    extensions restored      vchord 0.4.3, vector 0.8.1, cube, earthdistance,
                             pg_trgm, unaccent, uuid-ossp, plpgsql
    rows                     geodata_places 224,210 · naturalearth_countries 4,274
                             kysely_migrations 68 · session 6 · user 1

The extensions are the result that matters. A stock `postgres` image would have failed on
`CREATE EXTENSION vchord`, so these dumps are restorable **only onto an equivalently
extended server** — worth knowing before a rebuild, not during one.

**This corrects §1.10 in `BACKLOG.md`.** That entry characterises the dumps as "nightly
dumps *of an empty photo library*". The photo library is empty; the database is not.
`geodata_places` alone carries 224,210 rows of reverse-geocoding data, and the 16 MB is
mostly that. The dumps have real content and it restores.

**Item 1 verified.** Envelope item 1 opens repository `4154928a`, so the recorded value is
current with respect to the 2026-08-07 rotation.

It did not look that way at first, and the detour is the more useful lesson. The initial
attempt returned `wrong password or no key found` while `--password-file
/etc/restic/password` worked, which pointed straight at the unticked *"restic repository
password rotated 2026-08-07"* row in the currency table above — a tidy, plausible story
that was wrong. **`read -rs` echoes nothing, and one fumbled character produces an error
message identical to a genuinely stale credential.**

Before concluding the envelope is stale, discriminate — two commands, no secret displayed:

```bash
sudo sh -c "tr -d '\n' < /etc/restic/password | sha256sum"
printf '%s' "$RESTIC_PASSWORD" | sha256sum
```

Same hash means your copy is right and your fingers were not. Different means the copy is
stale and the envelope needs reprinting. Cheap, and it settles in seconds what otherwise
becomes an afternoon of suspecting the wrong thing.

**Item 1 alone is still insufficient**, which the drill did establish. `/mnt/cold-8t/restic`
is root-only, so reading the local repo needs the credential **and** a privileged shell on
the H4. Drill 1 never hit this because R2 is reached over the network with no local
permissions involved. The envelope does not say so, and should.

**Drill 1, 2026-08-16 — the first restore ever performed in this lab.**

Setup: throwaway Ubuntu 24.04 VM (`drill-1`, 2 vCPU / 2 GB) on n150-2, libvirt `default`
NAT network, restic from the distro. No lab config, no `/etc/restic`, no credentials
beyond the envelope.

Criteria:

    size       16,662,251 bytes           not an empty restore
    gunzip -t  OK                         archive intact
    header     "PostgreSQL database dump" correct content, not valid-but-wrong
    sha256     e03bea7d…3d4c              identical to the H4 original
    envelope   items 2 and 3 only         nothing reached for outside it

`repository d7ac04b8 opened` matches the chunker verification recorded in `BACKLOG.md`
§1.3, confirming the right bucket — `homelab-nas`, not `homelab-backup`.

**What this proves:** envelope items 2 and 3 are correct and sufficient to read the
offsite repo from a machine with nothing else on it. R2 credentials, R2 restic password,
repo URL — all good.

**What it does not prove:** items 1, 4, 5 and 6 were never used. The local restic
password, k3s server token, Vault unseal shares and Ansible vault password remain
untested — that is Drill 2. Nor does the timing extrapolate: 3 seconds restored 15.9 MiB,
and the repo's real content is ~250 MiB of dumps. Once Immich is populated (~1.5 TB
planned) this number means nothing.

**Nine minutes, three seconds of it restoring.** The rest was opening a repo for the
first time, listing snapshots, and choosing a file. That is the honest 2am number.

**Two faults found on the way, both now fixed:**

- The procedure restored `--include /srv/nas/<a known file>`. `/srv/nas` is empty
  (`BACKLOG.md` §1.10), so it would have restored zero bytes, exited 0, and been written
  into this table as a pass. Corrected before the drill ran; the size assertion above
  exists because of it.
- `create-vm.yml` hardcoded `--network bridge=br0`. This LAN serves DHCP to reserved MACs
  only, so the VM booted, applied its cloud-init identity, got no lease, never installed
  `qemu-guest-agent`, and the play reported success while printing an empty IP. Now
  defaults to the NAT network, with preflights and an IP lookup that can fail.

**Honest note on isolation:** libvirt's `default` network masquerades outbound to the LAN
as well as the internet, so the VM *could* have reached the H4. "Use only the envelope"
held by discipline, not by enforcement. A restricted-forward network would make it
structural.
