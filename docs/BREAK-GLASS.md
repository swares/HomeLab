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
| 5 | Vault unseal shares (any 3 of 5 — threshold is 3) | `/etc/vault.d/unseal-keys` on the **RPi5** (`192.168.1.128`), `root:root 0400`, one key per line. `vault.yml:81` provisions **3** keys there, not 5 | Vault stays sealed; every ExternalSecret stays empty |
| 6 | Ansible vault password | `ansible/.vault_pass` | encrypted group_vars are unreadable, so no playbook that touches them runs |

**Not a secret, but write it down anyway** — you will not have the repo:

| What | Value |
|------|-------|
| Offsite NAS repo | `s3:https://<R2-ACCOUNT-ID>.r2.cloudflarestorage.com/homelab-nas` |
| Offsite cluster-state repo | `s3:https://<R2-ACCOUNT-ID>.r2.cloudflarestorage.com/homelab-backup` |
| Git remote | `git@github.com:swares/HomeLab.git` |
| Vault address | `http://192.168.1.128:8200` |

### A note on item 5

`vault-unseal.service` on the RPi5 reads three shares from
`/etc/vault.d/unseal-keys` at boot, which is why Vault comes back unsealed after a
restart without anyone typing anything. Convenient, and it means:

- **Root on the RPi5 is equivalent to full Vault access.** The keys sit beside the
  data they unseal. `docs/SECURITY.md:25` describes these shares as "Offline,
  physically secure" — that is not true of this copy and should be corrected.
- **Establish where shares 4 and 5 are before filling this in.** If only the three
  on the RPi5 exist, then the envelope is not a convenience copy — it is the only
  redundant copy of a credential that cannot be regenerated. Losing both leaves
  Vault permanently sealed.
- **Check no stray copies exist elsewhere.** Three shares at rest on a KVM
  hypervisor or a workstation widens the blast radius well beyond the design:

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

Checkboxes are `[  ]` rather than ☐ deliberately — U+2610 is absent from Latin
Modern, so xelatex drops it and the column you are meant to tick prints blank.
Keep this table to ASCII.

| Date | What changed | Envelope updated? |
|------|--------------|-------------------|
| 2026-08-07 | restic repository password rotated (#1) | `[  ]` |
| 2026-08-07 | Vault root token revoked — item 5 no longer includes one | `[  ]` |
| 2026-08-07 | offsite repo `homelab-nas` created, reusing the R2 restic password (#2) | `[  ]` |

## The drill

An untested restore is a belief, not a backup. As of 2026-08-11 **no restore has
ever been performed in this lab**.

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

### Drill 2 — cluster state (do after drill 1 passes)

`homelab-backup` holds etcd snapshots, Vault raft snapshots, the k3s server token
and the Postgres dumps. Restoring those is the harder half and has its own known
gap: `ansible/playbooks/vault-restore.yml` does not work as written
(`docs/REVIEW-2026-07-24.md` H21).

Do not attempt drill 2 until drill 1 has succeeded and the envelope has proven
complete.

### Results

Record every drill here, including failures — a failed drill that gets fixed is
worth more than a passed one nobody remembers.

| Date | Drill | Restored | Duration | Outcome | Notes |
|------|-------|----------|----------|---------|-------|
| — | — | — | — | *no restore has ever been tested* | see `BACKLOG.md` §1.1 |
