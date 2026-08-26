# OPEN INCIDENT — H4 does not complete boot after reboot (2026-08-23)

**Status: unresolved. Recovery not yet attempted.** Pick up from *What to do next*.

---

## Current state

| | |
|---|---|
| **H4 (`odroid-nas`, 192.168.1.160)** | Powered, kernel up, **networking up**, no userspace |
| **Cluster** | Healthy. etcd quorum holds on n150-1 + n150-2 (2 of 3) |
| **Control-plane VIP `.200`** | Answering — kube-vip moved it to an N150, which is correct |
| **NAS (smbd/NFS)** | **DOWN** |
| **Workloads pinned to `odroid-nas`** | Down: registry, ai-gateway/LiteLLM, m5stack adapters, immich db-backup |
| **Data** | Nothing lost. Nothing has been written to or deleted from any disk |

## Evidence

    ping 192.168.1.160        -> replies, TTL=64, MAC 00-1e-06-45-99-e5 (enp2s0)
    Test-NetConnection :22    -> TcpTestSucceeded : False
    Test-NetConnection :6443  -> TcpTestSucceeded : False
    Test-NetConnection :445   -> TcpTestSucceeded : False
    ping 192.168.1.200        -> replies (VIP relocated to an N150)

**Console gives no output at all** — two monitors and two cables tried, nothing from
power-on. This box has been headless its entire life, so it is quite possible video output
was never functional or the UEFI redirects console to serial. **Do not spend more time on
the monitor.** The H4 has a UART header if a serial console is ever needed.

## Diagnosis

`systemd-networkd` starts early; `sshd` comes with `multi-user.target`. Ping working while
every TCP port is closed means **boot stalled after networking and before userspace** —
the signature of a hung or failed mount blocking `local-fs.target`.

**Most likely cause, and it is mine.** On 2026-08-21 the cold tiers were moved from
`/dev/mdX` to `UUID=` in `/etc/fstab` (BACKLOG §1.4). A `UUID=` entry needs the array
assembled *and* the `/dev/disk/by-uuid/` symlink present before `local-fs.target`
completes. I declined to pin `ARRAY` lines in `mdadm.conf` at the time, reasoning that
"nothing depends on the numbering any more" — but the thing that matters at boot is
**assembly**, not naming, and that reasoning did not address it. `CLAUDE.md` also records
the 8 TB mirror as possibly degraded from the UDMA-CRC issue, and degraded arrays are
exactly where auto-assembly gets fragile.

Neither the old nor the new fstab entries carried `nofail`, so this could have happened
before the change too — the UUID move plausibly exposed it rather than created it.

## What to do next

**1. Boot a USB live image** (Ubuntu live or similar). This also settles whether the
hardware POSTs — if the live image gives video, the machine is fine and this is purely a
boot problem.

**2. Look before changing anything:**

    lsblk                          # identify the eMMC root partition
    cat /proc/mdstat               # DO THE ARRAYS ASSEMBLE? This is the key question
    sudo mkdir -p /mnt/root
    sudo mount /dev/mmcblk0p2 /mnt/root      # adjust per lsblk
    cat /mnt/root/etc/fstab

- Arrays assemble cleanly in the live environment → boot-time ordering, `nofail` fixes it.
- Arrays do **not** assemble → a real storage fault the reboot surfaced. Stop and diagnose
  that before booting the H4 again. Do not `mkfs`, do not `--create`, do not `wipefs`
  (CLAUDE.md). The cold tiers are the copy-of-record.

**3. Make the cold mounts non-blocking:**

    sudo sed -i 's|\(UUID=.* /mnt/cold-8t .*defaults,noatime\)|\1,nofail,x-systemd.device-timeout=10s|' /mnt/root/etc/fstab
    sudo sed -i 's|\(UUID=.* /mnt/cold-sec .*defaults,noatime\)|\1,nofail,x-systemd.device-timeout=10s|' /mnt/root/etc/fstab
    cat /mnt/root/etc/fstab        # VERIFY before rebooting

`nofail` is correct regardless of the cause. **A NAS that will not boot because a backup
mirror is unavailable has its priorities inverted** — you want the box up so you can
diagnose the array, not held hostage by it.

**4. Unmount, reboot, and confirm from Windows:**

    Test-NetConnection 192.168.1.160 -Port 22

**5. If it is still stuck** and the arrays do assemble in the live environment, the fault
is elsewhere in boot. Read the previous boot's journal from the live image:

    sudo journalctl --root=/mnt/root -b -1 -p err --no-pager | tail -60
    sudo journalctl --root=/mnt/root -b -1 --no-pager | grep -iE 'mount|dependency|timed out|emergency'

## Follow-ups once recovered

- [ ] Put `nofail,x-systemd.device-timeout=10s` into `ansible/playbooks/storage.yml` so the
      fix is permanent rather than hand-applied. Hand-fixing it in the live environment and
      leaving the playbook unchanged means the next run reverts it.
- [ ] **Reopen the `mdadm.conf` ARRAY-line question closed in §1.4.** Pinning assembly is
      what makes `UUID=` mounts dependable at boot; the reason given for skipping it was
      about naming and did not address assembly.
- [ ] Verify the loop-device unit ordering actually took effect — that fix was the other
      reason for this reboot and has still never been tested:
      `systemctl status microshift-lvm-loop.service` and `vgs`.
- [ ] Confirm the netplan resolver change survived the reboot: `resolvectl dns` shows three
      servers, no `.152`, and `grep -c nameserver /run/systemd/resolve/resolv.conf` is 3.
- [ ] **Envelope gap found by this incident.** Item 7 (console login) assumes a usable
      console; the H4 appears to have none. Item 8 (break-glass SSH key) assumes a network
      that reaches `sshd`; here the network was up and `sshd` was not. **Neither envelope
      item would have helped with the single most important host in the lab.** A serial
      console procedure, or a documented USB-live-boot recovery, is the missing piece.
      Add to `docs/BREAK-GLASS.md` once resolved.
- [ ] Add `Before=` / `After=` review for `backup-*.timer` units — if the H4 was down over a
      backup window, check `LabBackupUnitFailed` fired and catch up any missed run.
