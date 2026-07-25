# Backups, Restores, and Validation

The authoritative reference for what is backed up, how to get it back, and how to
prove any of it works. Supersedes the backup and restore sections of
[RUNBOOK.md](RUNBOOK.md).

> **Guiding principle, learned the hard way.** In July 2026 a review found three
> separate mechanisms in this lab reporting success while doing nothing: an etcd
> backup that snapshotted a file deleted a month earlier, an offsite timer that
> rendered to `exit 0`, and a cloud retention policy that never deleted anything.
> All three passed every check that existed. **A backup you have not restored is a
> hypothesis, not a backup.** Everything below is built to fail loudly rather than
> succeed quietly.

---

## 1. What is backed up

| Stream | When | Source | Destination | Retention |
|---|---|---|---|---|
| `backup-etcd` | daily 00:30 | k3s' own etcd snapshots from `/var/lib/rancher/k3s/server/db/snapshots/` | `/mnt/cold-8t/k3s-etcd-snapshots/` | 30 files (~15 days) |
| `backup-nas` | daily 01:30 | `/srv/nas`, `/mnt/cold-8t/VMs`, `/mnt/cold-8t/immich` | restic → `/mnt/cold-8t/restic` | 7d / 4w / 6m |
| `backup-nas` (copy step) | daily 01:30 | the primary restic repo | restic → `/mnt/cold-sec/restic` | 14d / 8w / 12m |
| `backup-vault` | daily 02:30 | Vault raft snapshot (on rpi5) | `/mnt/cold-8t/vault-snapshots/` | 30 days |
| `lldap-backup` (k8s CronJob) | daily 02:30 | lldap `users.db` | restic → `/mnt/cold-8t/restic` via NFS | via `backup-nas` policy |
| Immich DB dump (k8s CronJob) | daily 01:30 | `pg_dump` | `/mnt/cold-8t/immich/backups/` | captured by `backup-nas` |
| `backup-cloud` | daily 03:00 | etcd snapshots, Vault snapshots, lldap DB, Postgres dumps (Authelia/Immich/Semaphore), OpenTofu state, **k3s server token** | restic → Cloudflare R2 `homelab-backup` | 7d / 4w / 3m |
| `backup-verify` | weekly Sun 04:00 | *verification only, read-only* | — | — |

`backup-offsite.timer` also exists but is a **no-op** — `restic_offsite_repo`
defaults to empty and the unit logs `skipping` and exits 0. `backup-cloud` → R2 is
the real offsite. Delete one of the two; see REVIEW-2026-07-24.md H20.

### The three tiers

- **HOT** — NVMe. k3s' own etcd snapshots (12h cadence, 5 retained ≈ 2.5 days) and
  live data. Same failure domain as the cluster; not a backup.
- **COLD** — two mdadm RAID 1 mirrors on the H4. `/mnt/cold-8t` is the
  copy-of-record; `/mnt/cold-sec` is a deeper-history restic copy. Survives disk
  failure, **not** loss of the H4.
- **OFFSITE** — Cloudflare R2, encrypted by restic. The only tier that survives
  losing the box, the building, or both.

---

## 2. Things that will ruin your day if you don't know them

### The k3s server token is required to restore etcd

k3s derives an AES-256 key from the server join token (PBKDF2) and uses it to
encrypt confidential data — CA private keys, bootstrap data — **inside the
datastore itself**. A snapshot without its token cannot be restored onto new
hardware. Per
[k3s docs](https://docs.k3s.io/datastore/backup-restore): *"If you do not use the
same token value when restoring, the snapshot will be unusable."*

Where it lives:

- `/var/lib/rancher/k3s/server/token` on **all three** server nodes (h4-core,
  n150-1, n150-2). Losing one box is therefore survivable.
- Inside the R2 backup as `k3s-server-token` (added 2026-07-25 — before that it
  was backed up nowhere, and every offsite etcd snapshot was decorative).
- It **should** also be in your offline envelope (below).

### Snapshot + token together is total compromise

Anyone holding both can extract every secret and the cluster CA private keys. They
are co-located in the R2 repo only because that repo is encrypted as a whole and
its password is not stored in R2. Treat the R2 restic password as a crown jewel.

### The break-glass envelope

Recovery from total loss needs credentials that are themselves stored inside the
thing you lost. Keep an **offline copy** — printed, or on an encrypted USB kept
off-site — of:

1. The restic password (`/etc/restic/password`)
2. The R2 restic password (`/etc/restic/cloud-password`) and the R2 API credentials
3. The k3s server token
4. The Vault unseal keys and root token
5. The Ansible vault password

Without #1 and #2 the backups are undecryptable ciphertext. Without #3 the etcd
snapshots are unrestorable. Without #4 every ExternalSecret stays empty.

### Vault is a circular dependency

`RUNBOOK.md` says to get the restic password from Vault. Vault runs on rpi5 and its
raft snapshots live on `/mnt/cold-8t` — on the H4. If the H4 is gone you need
restic to recover, and you need Vault to get the restic password. **Break the loop
with the offline envelope.** This is not yet solved in automation.

---

## 3. Restores

> Read the whole procedure before starting. Restores are the one operation with no
> undo.

### 3.1 Restore a file or directory from the NAS backup

Most common case, entirely safe — restic restores never touch the source.

```bash
# Find the snapshot
sudo restic -r /mnt/cold-8t/restic --password-file /etc/restic/password snapshots --tag nas

# Look inside one
sudo restic -r /mnt/cold-8t/restic --password-file /etc/restic/password ls <SNAPSHOT-ID> /srv/nas

# Restore to a scratch path — NEVER restore over live data on the first attempt
sudo restic -r /mnt/cold-8t/restic --password-file /etc/restic/password \
  restore <SNAPSHOT-ID> --target /mnt/cold-8t/restore-scratch --include /srv/nas/somedir

# Verify, then move into place by hand
```

If `/mnt/cold-8t` is unreadable, substitute `/mnt/cold-sec/restic` — same password,
deeper history.

### 3.2 Restore cluster state (etcd) — 3-server HA

**This supersedes the procedure previously in RUNBOOK.md, which was wrong**: it used
a non-existent `k3s etcd-snapshot restore` subcommand, pointed at the wrong
directory, and gave the single-node steps for a 3-server cluster.

Verified against [k3s docs](https://docs.k3s.io/cli/etcd-snapshot#restoring-snapshots).
Nodes below: **S1** = odroid-nas, **S2** = n150-1, **S3** = n150-2.

```bash
# 0. Pick a snapshot and confirm it is real (~30 MB, not 4 KB)
ls -lh /mnt/cold-8t/k3s-etcd-snapshots/

# 1. Stop k3s on ALL THREE servers
sudo systemctl stop k3s          # on S1, S2 and S3

# 2. On S1 ONLY — reset the cluster and restore
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/mnt/cold-8t/k3s-etcd-snapshots/<SNAPSHOT>

# Wait for: "Managed etcd cluster membership has been reset, restart without
# --cluster-reset flag now."  Then Ctrl-C.

# 3. On S1 — start normally
sudo systemctl start k3s
kubectl get nodes     # S1 Ready; S2/S3 NotReady — expected

# 4. On S2 and S3 — discard their old datastore
sudo rm -rf /var/lib/rancher/k3s/server/db/

# 5. On S2 and S3 — rejoin
sudo systemctl start k3s
kubectl get nodes     # all three Ready
```

k3s moves the existing database to `${data-dir}/server/db/etcd-old-$TIMESTAMP/`
rather than deleting it, and writes `/var/lib/rancher/k3s/server/db/reset-flag` to
prevent a second accidental reset. That file clears on normal start.

**Restoring onto new hardware** additionally requires the token:

```bash
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<PATH-TO-SNAPSHOT> \
  --token=<TOKEN-FROM-ENVELOPE-OR-R2>
```

Node objects are inside the snapshot, so after restoring to new machines you must
`kubectl delete node <old-name>` for hosts that no longer exist.

**Workloads need no restore.** Argo CD reconciles everything in `gitops/` from git
with `selfHeal`. Restoring etcd brings back cluster state; Argo brings back apps.
PVC *data* is a separate matter — that comes from restic.

### 3.3 Restore from R2 (total loss of the H4)

```bash
export RESTIC_REPOSITORY='s3:https://<ACCOUNT-ID>.r2.cloudflarestorage.com/homelab-backup'
export AWS_ACCESS_KEY_ID=<R2-KEY>          # from the envelope
export AWS_SECRET_ACCESS_KEY=<R2-SECRET>
export RESTIC_PASSWORD=<R2-RESTIC-PASSWORD>

restic snapshots --tag cloud
restic restore latest --target /recovery
```

`/recovery` then contains the etcd snapshots, `k3s-server-token`, Vault raft
snapshots, Postgres dumps, the lldap DB, and OpenTofu state. Rebuild order:

1. Base OS + storage — `ansible/playbooks/storage.yml` (run `--check` first)
2. k3s — `ansible/playbooks/k3s-h4.yml`, then restore etcd per §3.2 using the
   recovered token
3. Vault — restore the raft snapshot (§3.4), unseal with the envelope keys
4. Argo CD — `ansible/playbooks/argocd.yml`; workloads reconcile from git
5. Postgres/lldap — restore the dumps into the running pods
6. NAS data — restic restore from cold, or R2 if the cold disks are also gone

> **Untested.** No one has performed this end to end. Until someone does, treat the
> timings and the ordering as informed guesses. See §5.

### 3.4 Restore Vault

Live backups are raft snapshots in `/mnt/cold-8t/vault-snapshots/vault-snap-*.snap`
(30-day retention).

```bash
ls -lt /mnt/cold-8t/vault-snapshots/ | head
vault operator raft snapshot restore /path/to/vault-snap-<TS>.snap
# then unseal with the keys from the envelope
```

> `ansible/playbooks/vault-restore.yml` is **broken** — it hardcodes a dated tarball
> (`vault-backup-20260627.tar.gz`) in a directory nothing maintains, and uses a
> controller-side `src` for a file that lives on the H4. Do not use it until fixed.
> See REVIEW-2026-07-24.md H21.

### 3.5 Restore a Postgres database

Dumps land in the R2 backup and (for Immich) on cold.

```bash
gunzip -c /recovery/var/tmp/backup-cloud-stage/authelia.sql.gz \
  | kubectl exec -i -n authelia deploy/authelia-postgres -- \
      sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER $POSTGRES_DB'
```

Same shape for `semaphore.sql.gz` and `immich.sql.gz`.

---

## 4. Manual validation

### 4.1 The one-command check

`backup-verify` runs weekly and does everything in §4.2 automatically. Run it by
hand any time — it is strictly read-only and never writes to, forgets from, or
prunes any repository:

```bash
sudo systemctl start backup-verify.service
systemctl status backup-verify.service
```

Every line is either `ok:` or `FAIL:`, and a single failure makes the unit exit
non-zero, which suppresses the healthchecks.io ping and raises the alarm.

### 4.2 Checking by hand

**Are the timers alive?**

```bash
systemctl list-timers 'backup-*'
systemctl status backup-etcd backup-nas backup-cloud backup-verify
```

**Are the etcd snapshots real?** The original bug produced 4 KB files for a month.
Real snapshots are ~30 MB.

```bash
ls -lh /mnt/cold-8t/k3s-etcd-snapshots/
sudo k3s etcd-snapshot ls
```

**Is the cold copy byte-identical?**

```bash
sudo sha256sum \
  /var/lib/rancher/k3s/server/db/snapshots/<NEWEST> \
  /mnt/cold-8t/k3s-etcd-snapshots/<NEWEST>
```

**Do the restic repos have recent snapshots, and are they intact?**

```bash
for r in /mnt/cold-8t/restic /mnt/cold-sec/restic; do
  echo "== $r"
  sudo restic -r "$r" --password-file /etc/restic/password snapshots --tag nas | tail -3
  sudo restic -r "$r" --password-file /etc/restic/password check
done
```

cold-sec legitimately holds **more** snapshots than the primary — the primary is
pruned nightly to 7d/4w/6m while the copy keeps 14d/8w/12m. More on the copy is
correct; fewer is a bug.

**Is R2 healthy, and does it hold what actually matters?**

```bash
sudo bash -c 'set -a; . /etc/restic/cloud.env; set +a; restic snapshots --tag cloud | tail -5'
sudo bash -c 'set -a; . /etc/restic/cloud.env; set +a; restic check'

# The content assertions — a clean check proves the repo is well-formed,
# NOT that the right files are in it.
sudo bash -c 'set -a; . /etc/restic/cloud.env; set +a; \
  restic ls latest /mnt/cold-8t/k3s-etcd-snapshots'
sudo bash -c 'set -a; . /etc/restic/cloud.env; set +a; \
  restic ls latest /var/tmp/backup-cloud-stage | grep k3s-server-token'

# Free-tier headroom (10 GB)
sudo bash -c 'set -a; . /etc/restic/cloud.env; set +a; restic stats --mode raw-data'
```

**Deep integrity check** (re-reads stored data; catches bit-rot the structural check
misses; slow):

```bash
sudo restic -r /mnt/cold-8t/restic --password-file /etc/restic/password \
  check --read-data-subset=5%
```

### 4.3 Never do these by hand

Retention lives in the backup units and nowhere else. Running these manually can
destroy the copy-of-record:

- `restic forget` / `restic prune` on any repo
- `mkfs` / `wipefs` on `/dev/md0` or `/dev/md1`
- stopping `smbd`, `nfs-kernel-server`, or disabling any `backup-*` timer

### 4.4 The restore drill

Structural checks cannot tell you a restore works. Once a quarter:

1. Restore one file from the NAS backup to a scratch dir and diff it against live.
2. Restore one etcd snapshot into a throwaway VM and confirm `kubectl get nodes`.
3. Restore a Postgres dump into a scratch database and count rows.
4. Decrypt one R2 snapshot **using only the offline envelope** — no Vault, no H4.
   This is the only test that actually validates total-loss recovery.

Record the date, duration, and anything surprising in the log below.

| Date | What was tested | Result | Time taken | Notes |
|---|---|---|---|---|
| — | *no restore has ever been tested* | — | — | See §5 |

---

## 5. Known gaps

Honest list. Tracked in [REVIEW-2026-07-24.md](REVIEW-2026-07-24.md).

| Gap | Impact | Ref |
|---|---|---|
| **No restore has ever been performed** | The entire chain above is untested. This is the single largest risk in the lab. | C2 |
| Vault ↔ restic circular dependency | Total-loss recovery depends on the offline envelope existing and being current | H7 |
| `vault-restore.yml` is broken | No working automated Vault restore | H21 |
| `backup-offsite` is a no-op competing with `backup-cloud` | Two offsite mechanisms, one fake | H20 |
| restic 0.12.1 (2021) | Upgrading past 0.14 silently reverses the cold-sec copy direction unless the version guard in `backup-nas-copy.sh` catches it | M-new-2 |
| cold-8t is one box | Cold tier does not survive loss of the H4; only R2 does | C5 |
| No alert reaches a human | Alertmanager's only non-null receiver is an M5Stack display; healthchecks.io covers timers only | H25 |

---

## 6. File map

| Thing | Path |
|---|---|
| etcd copy script | `ansible/templates/backup-etcd.sh.j2` → `/usr/local/sbin/backup-etcd.sh` |
| NAS→cold-sec copy + retention | `ansible/templates/backup-nas-copy.sh.j2` → `/usr/local/sbin/backup-nas-copy.sh` |
| Verification | `ansible/templates/backup-verify.sh.j2` → `/usr/local/sbin/backup-verify.sh` |
| NAS backup unit | `ansible/templates/backup-nas.{service,timer}.j2` |
| Cloud backup | `ansible/playbooks/backup-cloud.yml` (script inline) → `/usr/local/bin/backup-cloud.sh` |
| Vault backup | `ansible/playbooks/backup-vault.yml` |
| Dead-man switches | `ansible/playbooks/healthchecks.yml` |
| Restic passwords | `/etc/restic/password`, `/etc/restic/cloud-password` (0600 root, never in git) |
