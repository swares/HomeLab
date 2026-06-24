# Runbook

Operational procedures for the H4 core. Commands assume you're the `ansible` user with the
kubeconfig at `~/.kube/config` and run playbooks from `ansible/`.

## Initial install

### 1. Partition map (done at OS install, by hand)

Ansible deliberately does **not** repartition the live root disk. Lay this out when you
install the host OS on the NVMe:

| Partition | Size | Mount | Notes |
|-----------|------|-------|-------|
Put the **OS on the 256 GB eMMC** so the entire NVMe serves the cluster + NAS:

| Device | Partition | Size | Mount | Notes |
|--------|-----------|------|-------|-------|
| eMMC | `mmcblk0p1/2/3` | 256 GB | `/boot/efi`, `/boot`, `/` | Host OS + `/var/lib/microshift` (etcd) |
| NVMe | `nvme0n1p1` | ~1.5 TB | `lv_nas` | live NAS data |
| NVMe | `nvme0n1p4` | rest (~2.5 TB) | — | **Left free** for the LVMS VG (`microshift_pv_device`) |

The two cold mirrors (8 TB `md1` → `/mnt/cold-8t`, ~5.45 TB secondary → `/mnt/cold-sec`) are mounted next.

### 2. Cold tiers (two mdadm RAID 1 mirrors)

Both cold tiers are mdadm RAID 1 mirrors (pre-created — the playbook never runs `mdadm --create`).
`storage.yml` mounts the **8 TB primary** (`md1`) at `/mnt/cold-8t` and the **~5.45 TB secondary**
at `/mnt/cold-sec` (XFS, formatted only if empty), installs **smartd + mdadm monitoring** so a
climbing CRC count or a dropped member alerts you, and the backup timers keep the primary restic
repo on the 8 TB and a `restic copy` on the secondary. Each mirror survives one disk failure in place.
Nothing destructive runs against a populated array. See
[Cold tier options](#cold-tier-options) for alternatives.

### 3. DNS records

On your chosen DNS host, add these records (wildcard via dnsmasq):

| Record | Type | Value |
|--------|------|-------|
| `api.lab.home.arpa` | A | `192.168.1.160` |
| `*.apps.lab.home.arpa` | A | `192.168.1.160` |

The updated map leaves **DNS unassigned** (the old Pi-hole Zero now runs Grafana). Pick a
stable always-on host — a Zero 2 W, an Orange Pi 5 Pro, or `dnsmasq` on the H4 — and add the
records there (dnsmasq wildcard: `address=/apps.lab.home.arpa/192.168.1.160`). Missing or
wrong DNS is the most common reason MicroShift "installs but nothing works."

### 4. Secrets

- `ansible/files/pull-secret.json` — free pull secret from
  <https://console.redhat.com/openshift/install/pull-secret>
- `/etc/restic/password` on the host (mode 0700) — restic repo password
- `ansible/.vault_pass` — Ansible Vault password (gitignored)

### 5. Run the stages

```bash
make check        # dry run
make storage
make microshift
make backup
make argocd
```

## Verify a healthy cluster

```bash
oc get nodes                      # node Ready
oc get pods -A                    # control plane + router + lvms running
oc get sc                         # confirm the LVMS StorageClass name
oc get route -A                   # Routes resolve to *.apps.lab.home.arpa
systemctl status backup-nas.timer backup-etcd.timer
```

## Deploy a workload

1. Copy `gitops/workloads/sample-app/` to `gitops/workloads/<name>/` and edit the
   manifests (image, host, PVC size).
2. Add `gitops/apps/<name>.yaml` (copy `sample-app.yaml`, change `name`/`path`/`namespace`).
3. Open a PR; on merge, Argo deploys it. Watch with `argocd app get <name>` or the UI.

Never `oc apply` a workload directly — it'll drift and Argo will fight you. Change git.

## Backups

| Stream | When | What | Downtime |
|--------|------|------|----------|
| `backup-nas` | daily 01:30 | restic of `/srv/nas` → `/mnt/cold-8t` (md1), then `restic copy` → `/mnt/cold-sec` + offsite | none |
| `backup-etcd` | Sun 03:00 | `microshift backup` → 8 TB | brief (service stop/start) |

Check: `restic snapshots` (set `RESTIC_REPOSITORY`/`RESTIC_PASSWORD_FILE`), and
`ls /mnt/raid/microshift-backups`. Retention is handled inside the timer — **do not** run
`restic forget`/`prune` by hand (it's denied in the permission config for this reason).

## Recovery scenarios

**UDMA CRC errors (SMART 199) — triage BEFORE replacing a disk.** `UDMA_CRC_Error_Count` is a
**link-layer** fault (cable / connector / SATA power / controller), not the platters. Two disks
erroring identically => a shared cause, not two bad drives. Don't RMA first.

```bash
smartctl -a /dev/sdX | grep -E "UDMA_CRC|Reallocated_Sector|Current_Pending|Offline_Uncorrectable"
# 199 climbing  => active link problem.  5/197/198 all 0 => media is FINE (link-only).
```
Fix order: (1) reseat/replace SATA **data** cables (latching; don't bundle — crosstalk);
(2) check SATA **power** (the H4 powers drives off-board — a marginal/overloaded splitter is a
classic cause with two spinning 8 TB drives); (3) move disks to **different SATA ports**;
(4) update the **H4 BIOS**; (5) re-test under a full array read and watch 199. If 199 stops
climbing after a cable+power+port swap, the disks were never the problem. If it climbs only on
the H4 across cables/ports, suspect the board's SATA controller (documented H4 failure mode).

**RAID 1 member dropped (often CRC-induced link resets).** The array is degraded, not lost — the
platter data is intact. After fixing the link:
```bash
cat /proc/mdstat                      # see which member fell out
mdadm --detail /dev/md1               # confirm state (md1 = 8TB primary)
mdadm /dev/md1 --re-add /dev/sdX1     # re-add; it resyncs (watch /proc/mdstat)
```
Only if SMART 5/197/198 are non-zero (real media damage) do you replace the disk:
`mdadm --manage /dev/md1 --fail /dev/sdX1 --remove /dev/sdX1`, fit the new disk, partition to
match, `--add`, let it rebuild.

**Burn-in a re-attached / replaced cold mirror (do this before trusting it as primary).** A
re-attached array will *assemble* fine; the real question is whether the SATA link stays clean
**under sustained load** — CRC is a link-layer symptom that only shows up while pushing data. So
generate hours of I/O and watch the counter, don't just glance at SMART once.

1. **Baseline 199 on both members** (write the numbers down):
   ```bash
   cat /proc/mdstat                       # identify the array's members (md1 = sdb sdd)
   for d in sda sdb; do smartctl -a /dev/$d |      grep -E "UDMA_CRC|Reallocated_Sector|Current_Pending|Offline_Uncorrectable"; done
   ```
2. **Confirm it assembled clean / resync finished:** `mdadm --detail /dev/md1` → State clean,
   both *active sync*, Failed Devices 0. If degraded, `mdadm /dev/md1 --re-add /dev/sdX` and wait.
3. **Decisive test — full read scrub while watching the link** (reads every block on both disks;
   ~hours for 8 TB):
   ```bash
   journalctl -k -f | grep -i 'ata\|sata\|hard resetting\|SError\|failed command'   # terminal 1
   echo check > /sys/block/md1/md/sync_action                                          # terminal 2
   watch -n5 cat /proc/mdstat
   # when done:
   cat /sys/block/md1/md/mismatch_cnt                       # want 0
   for d in sda sdb; do smartctl -a /dev/$d | grep UDMA_CRC; done   # compare to baseline
   ```
4. **Optional write stress** (scrub is read-only; non-destructive to existing files):
   ```bash
   fio --name=burn --directory=/mnt/cold-8t --size=20G --rw=randrw \
       --bs=1M --numjobs=4 --time_based --runtime=1800 --group_reporting
   ```
5. **Confirm monitoring is armed:** `systemctl status mdmonitor smartd` (both active).

**PASS = all three:** 199 did **not** climb on either disk · **no** `ata`/`hard resetting link`/
`SError` lines during the run · `mismatch_cnt = 0`. Then it's safe to promote back to the restic
**primary**. If 199 climbs under load it's still marginal (try another port/power rail; if it
climbs *only on the H4* across every cable/port, that's the board). If `mismatch_cnt > 0`, run
`echo repair > /sys/block/md1/md/sync_action` then re-`check` — but start with `check` (read-only)
so you *see* a mismatch before mdadm overwrites one copy with the other. **Until it passes all
three, keep backups landing on the secondary, not the array under test — don't promote on faith.**

**Lost a disk in a cold mirror.** The mirror stays online degraded — no data loss, no restore.
Fix per the mdadm re-add/rebuild steps above. (The old "independent disks + restic copy" recovery
below applies only if you ever run the tiers un-mirrored.) Replace the failed
disk, recreate the XFS filesystem on it (`make storage`), then re-seed it from the survivor:
```bash
restic -r /mnt/cold-8t/restic copy --repo2 /mnt/cold-sec/restic   # (or reverse, toward the new disk)
```

**Lost the NVMe (whole hot tier).** This is recoverable because state + config are
off-tier:
1. Replace the drive, reinstall the host OS with the partition map above.
2. `make storage` (the cold disks still have your data).
3. Restore MicroShift state from the latest `/mnt/raid/microshift-backups/<ts>` with
   `microshift restore`, then `make microshift`.
4. Restore NAS data from the 8 TB: `restic -r /mnt/cold-8t/restic restore latest --target /srv/nas`.
5. `make argocd` — Argo rebuilds all workloads from git.

**Lost the whole box.** You need the offsite copy (see below). Without it, cluster config
survives in git but NAS *data* does not.

## Cold tiers (current model)

Two real mdadm RAID 1 mirrors — no more guessing about mismatched disks:

- **Primary — 8 TB (`md1`, 2×8 TB) → `/mnt/cold-8t`.** restic repo + etcd snapshots + the Immich
  library. Passed re-attach burn-in. This is the trusted tier.
- **Secondary — ~5.45 TB (2×6 TB) → `/mnt/cold-sec`.** `restic copy` of the *critical-but-small*
  set (DB dumps, configs, irreplaceable originals) + archive.

Because the ~5.45 TB secondary can't locally hold the whole multi-TB library, the **bulk library's
redundant copy is the offsite restic** (3-2-1, below) + md1's own mirror; the secondary covers the
small critical set. This is the deliberate split for an asymmetric pair.

### Migrate the ex-Synology secondary to a clean mirror
The secondary disks came off an old Synology (ext4 LVM `vg1000` concatenating two mirrors). To
move to a clean layout once the photos are safely on md1:
```bash
# 1. reclaim the disposable space (old Windows backups), then copy photos to the primary:
rsync -aHAX --info=progress2 /mnt/cold-sec-old/<photos>/ /mnt/cold-8t/immich/library/
# 2. import + VERIFY in Immich before deleting the only copy.
# 3. unmount + wipe the old vg1000 stack, then build one clean RAID 1 across the two 6 TB disks:
umount /mnt/cold-sec-old; vgremove vg1000; mdadm --stop /dev/md2 /dev/md3
wipefs -a /dev/sda /dev/sdc
mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sda /dev/sdc
mkfs.xfs /dev/md0 && mdadm --detail --scan >> /etc/mdadm/mdadm.conf
# 4. mount at /mnt/cold-sec; `make storage` then manages it (cold_secondary_device=/dev/md0).
```
(Harmless leftover: clear the Synology `old PV header` warnings with `vgck --updatemetadata vg1000`
*before* you remove it, or just ignore them — they vanish with the wipe.)

## Roadmap: offsite (3-2-1)
## Roadmap: offsite (3-2-1)

Two on-box copies protect against a disk failure, not a box/room failure. The next durability step is
one copy off the box — restic can replicate the same (already-encrypted) repo to a second
machine or to S3/Backblaze B2. Add a `backup-offsite.timer` mirroring the restic repo when
you're ready.
