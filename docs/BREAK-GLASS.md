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

Bounded, read-only, and proves the whole chain: envelope → R2 → plaintext.

On a non-H4 host with restic installed and internet access:

```bash
# From the envelope: items 2 and 3.
export AWS_ACCESS_KEY_ID='<envelope item 3>'
export AWS_SECRET_ACCESS_KEY='<envelope item 3>'
export RESTIC_REPOSITORY='s3:https://<account-id>.r2.cloudflarestorage.com/homelab-nas'

restic snapshots --tag nas --latest 1        # prompts for envelope item 2
restic restore latest --target /tmp/drill --include /srv/nas/<a known file>
```

Then verify the restored file against the original, and record how long the whole
thing took.

Cost note: R2 has **no egress fees**, so this costs nothing but time. That was a
deliberate reason for choosing R2 over cheaper storage — a restore drill must never
be something you avoid because of the bill.

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
