# INCIDENT — H4 boot deadlock, 2026-08-23 to 2026-08-26

**Status: RESOLVED AND CONFIRMED 2026-08-26 19:45 UTC.** No data lost. Root cause found,
fixed in `ansible/playbooks/storage.yml`, and **proven by a clean unattended reboot**.

---

## What happened

The H4 was rebooted to pick up two changes that only take effect at boot (netplan
resolvers, loop-device unit ordering). It did not come back. It responded to ICMP but
every TCP port was closed — kernel and networking up, no userspace.

It sat that way for three days. The cluster was unaffected: etcd quorum held on the two
N150s and kube-vip moved the control-plane VIP. The NAS was down, and everything pinned to
`odroid-nas` with it.

## Root cause

**`/srv/nas` deadlocked `local-fs.target`.** In `/etc/fstab` it read:

    /dev/vg_microshift/lv_nas /srv/nas xfs defaults,noatime 0 0

That LV does not exist until `microshift-lvm-loop.service` attaches the loop device and
runs `vgchange -ay`. That service is `WantedBy=multi-user.target` — which comes **after**
`local-fs.target`. So:

    local-fs.target waits for /srv/nas
      -> /srv/nas waits for /dev/vg_microshift/lv_nas
         -> that LV needs microshift-lvm-loop.service
            -> which runs at multi-user.target, after local-fs.target

A cycle. The device never appeared, the 90-second timeout expired, the mount failed,
`local-fs.target` failed, and boot dropped to recovery — before `sshd`.

**This was latent, not new.** The H4 had 62 days of uptime; nothing had exercised a boot.
A reboot is simply when this class of fault gets discovered, which is the argument for
rebooting deliberately and occasionally rather than only under pressure.

## What was NOT the cause

Recorded because time was spent on them:

- **Not mdadm assembly.** Both arrays came up clean: `md1 [2/2] [UU]`, `md0 [2/2] [UU]`.
  The initial hypothesis was that moving the cold tiers to `UUID=` (§1.4) without pinning
  `ARRAY` lines in `mdadm.conf` broke boot-time assembly. It did not. Assembly was never
  the problem, and the `mdadm.conf` question can stay closed.
- **Not the netplan change.** Resolvers survived correctly: `.148 .116 .184` on `enp2s0`,
  none on `enp1s0`, `grep -c nameserver /run/systemd/resolve/resolv.conf` = 3. §4.12's
  fix is now proven across a reboot.
- **Not a dead console.** Recovery mode WAS visible on the monitor. The earlier blank
  screen was most likely a display attached after boot had already failed. **Envelope item
  7 (console login) is viable on this host** — the working assumption that it might not be
  was wrong.
- **Not hardware.** POST, eMMC boot and all disks were fine throughout.

## Contributing factor

`nofail` was absent from **every** fstab entry. Adding it to the cold tiers during recovery
got boot past their device timeouts, but `/srv/nas` still blocked. Neither old nor new
entries had it, so this was not introduced by the §1.4 UUID change — that change is
unrelated to the deadlock.

## Fixes applied

**`/srv/nas`** — `defaults,noatime,nofail,x-systemd.requires=microshift-lvm-loop.service`

`x-systemd.requires=` generates both `Requires=` and `After=` on that unit, so the mount
*waits for* the loop device rather than racing it. That breaks the cycle properly.
`nofail` is the backstop: if it fails anyway, the box still boots. **A NAS you cannot log
into is worse than a NAS with an unmounted share** — you need the box up to fix the share.

**Cold tiers** — `defaults,noatime,nofail,x-systemd.device-timeout=10s`

These are backup tiers; an unavailable mirror should never cost you the machine.
`backup-nas.service` carries `RequiresMountsFor=`, so backups still fail loudly rather
than silently writing a restic repo onto the eMMC root. `nofail` makes boot survivable
without making backup failure quiet.

Both are in `ansible/playbooks/storage.yml` with the reasoning inline, so a future run
cannot revert them and nobody "simplifies" them away.

**`immich-postgres`** — memory limit 512Mi → 2Gi (`gitops/workloads/immich/postgres.yaml`)

Secondary failure found during recovery. The pod OOMKilled (exit 137) seven times:
Postgres reached "ready to accept connections", then died during WAL replay of the unclean
shutdown. 512Mi sufficed for steady-state idling and not for recovery — which is exactly
when the database needs to come back. **The database itself was fine**: `redo done`, no
corruption.

## Final state

    /srv/nas         /dev/mapper/vg_microshift-lv_nas
    /mnt/cold-8t     /dev/md1
    /mnt/cold-sec    /dev/md0
    /mnt/nvme0n1p2   /dev/nvme0n1p2
    vg_microshift    1.95t, lv_nas 1.46t active
    kubectl get nodes -> all 5 Ready

## Confirming reboot — 2026-08-26 19:45 UTC

Clean. SSH answered unattended; no console intervention needed.

    microshift-lvm-loop.service   active (exited) since 19:45:38
      19:45:35  Starting Attach MicroShift LVM sparse image (/dev/loop100)
      19:45:38  1 logical volume(s) in volume group "vg_microshift" now active
      19:45:38  Finished

    /srv/nas        /dev/mapper/vg_microshift-lv_nas
    /mnt/cold-8t    /dev/md1
    /mnt/cold-sec   /dev/md0
    /mnt/nvme0n1p2  /dev/nvme0n1p2

    systemctl --failed -> only snap.lxd.activate.service (unrelated snap cruft)

**`active (exited)` is the whole result.** On 2026-08-23 that unit read `inactive (dead)`
with no journal entries at all — never attempted, because the mount it feeds had already
failed `local-fs.target`. Three seconds in the right order was all it ever needed.

`systemctl show srv-nas.mount` was checked *before* rebooting and returned both
`Requires=microshift-lvm-loop.service` and `After=microshift-lvm-loop.service` — confirming
systemd had parsed `x-systemd.requires=` rather than merely that fstab contained the text.
Config correct and generated-unit correct are two different claims.

## Remaining

- [x] `storage.yml` merged and run — fstab fix is under Ansible, not hand-applied.
- [x] Confirming reboot passed.
- [x] `backup-etcd` / `backup-verify` failed state cleared by the reboot; no `reset-failed`
      needed. Their next scheduled runs are the real test.
- [ ] `monitoring-prometheus-node-exporter-fmxwl` has been crashlooping for **18 days** —
      unrelated to this incident and predating it. Worth its own look; it is the H4's
      node-exporter, so its absence is a monitoring blind spot on the most important host.
- [ ] Consider whether other units depend on `microshift-lvm-loop.service` implicitly and
      would benefit from the same explicit `x-systemd.requires=`.

## Lessons

**Reboot deliberately and periodically.** A 62-day-old boot path is an untested boot path.
This deadlock could have surfaced during an unplanned power cut instead, with less patience
available.

**The two envelope items added on 2026-08-21 were both untested and one was wrong.** Item 7
assumed a console that was believed absent and turned out to work. Item 8 (SSH key) assumed
a network that reaches `sshd` — here the network was up and `sshd` was not, so it would not
have helped. Neither was the recovery path; the console was. Worth reflecting in
`docs/BREAK-GLASS.md`.

**Malformed commands read as evidence.** `findmnt /a /b /c /d` returns nothing — it takes
one target, or a source/target pair. Empty output was read as "nothing is mounted" four
times before the syntax was questioned. All four were mounted the whole time. Same failure
class as everything in `CLAUDE.md` → *Check the artifact the consumer reads*: a check that
cannot succeed reports the same silence as a real negative.
