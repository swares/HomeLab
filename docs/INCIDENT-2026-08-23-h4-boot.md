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

## Aftermath — what the recovery surfaced, 2026-08-26

The box came back; the cluster did not, immediately. Three things followed, in the order
they were found.

### ESO — a ClusterSecretStore with an unqualified `serviceAccountRef`

Ten Argo Applications were `Degraded` and all sixteen ExternalSecrets read
`SecretSyncedError`:

    cannot request Kubernetes service account token for service account
    "external-secrets": serviceaccounts "external-secrets" not found

The Kubernetes-auth switch (§5, step 3 of 3) wrote `serviceAccountRef` without a
`namespace`. A **ClusterSecretStore has no namespace of its own**, so the reference is
resolved against *each ExternalSecret's* namespace — ESO went looking for an
`external-secrets` ServiceAccount in `immich`, `monitoring`, `semaphore`, `lldap` and the
rest, and failed all sixteen.

**The store itself reported `Ready: True` throughout.** Store validation does not exercise
the ServiceAccount lookup, so the health signal nearest the fault was the one signal that
stayed green. Fixed by adding `namespace: external-secrets`; the reasoning is now inline in
`gitops/workloads/immich/external-secret.yaml` where the next person will hit it.

This was also declared "verified" on 2026-08-23 on the strength of an advancing
`refreshTime`. That batch was a reconcile, not a successful authentication. `READY` was the
column to read.

### Backup CronJobs — three nights missed in two namespaces

`immich-db-backup` and `lldap-backup` had failed every night since 08-23. Argo surfaced it
only as `Degraded`, and it took an hour to decode because the failing resource was a
**Job** — a kind neither of us thought to look at, after Deployments, Ingresses, PVCs and
the ClusterSecretStore had each been checked and cleared.

Neither job was broken. immich's is pinned `nodeSelector: kubernetes.io/hostname=odroid-nas`
and lldap's mounts `192.168.1.160:/mnt/cold-8t/restic` over NFS — both write to the H4, and
the H4 was down. Manual runs off both CronJobs succeeded immediately after recovery (immich:
16.7 MB, 61 tables; lldap: snapshot `b53108ec`), which is what proved the jobs healthy rather
than merely unblocked. The failed Jobs were then cleared and both apps returned to `Healthy`.

`Events: <none>` on all six failed Jobs. Whatever they said about *why* had already aged out
of the one-hour event TTL — the retention problem `docs/LEDGER-DESIGN.md` exists to solve,
appearing in the first real incident after the design was written.

### Alerting was working the whole time — an hour spent proving otherwise

The investigation then went looking for why three critical rules
(`LabBackupJobFailed`, `LabCronJobStale`, `LabArgoCDAppDegraded`) had not paged. They had.
All three fired correctly and are in the Alertmanager log by name. ntfy delivered to the
phone. The m5stack adapter was `1/1 Running` the entire time.

Three wrong conclusions were drawn on the way, each from an artifact that could not have
shown otherwise:

- **"The ntfy route never loaded"** — because no log line said `receiver=ntfy`. Alertmanager
  logs `Notify success` *only when a notification took more than one attempt*. A healthy
  receiver that succeeds first time writes nothing. The m5stack lines dominated the log
  precisely because m5stack was retrying. Absence of evidence, again read as evidence.
- **"The m5stack adapter is gone"** — `No resources found` came from a wrong label selector,
  not a missing workload.
- **"The rules don't exist, write them"** — all three were already in
  `gitops/workloads/monitoring/lab-alerts.yaml`, two of them for weeks. Writing them again
  would have produced a duplicate PR that closed nothing.

The retry storm was burst saturation: roughly twenty alert groups resolving at once against
a single small webhook server, filling its listen backlog. Every group eventually delivered.

**The premise was never checked.** The whole line of investigation rested on assuming that
"found via the Argo UI" meant "no alert arrived." One question — *did you get notified?* —
would have ended it before it started. Ask the human what they observed before instrumenting
a search for why they observed nothing.


- [x] Confirming reboot passed.
- [x] `backup-etcd` / `backup-verify` failed state cleared by the reboot; no `reset-failed`
      needed. Their next scheduled runs are the real test.
- [x] ESO `serviceAccountRef` namespace fixed; all 16 ExternalSecrets `SecretSynced`/`True`.
- [x] Backup CronJobs proven healthy by manual runs; failed Jobs cleared; `immich` and
      `lldap` back to `Healthy`.
- [ ] `backup-vault.service` on rpi5 is `failed` — it tried to rsync a raft snapshot to
      `192.168.1.160:22` at 06:33 UTC, thirteen hours before `sshd` came back. Outage
      fallout, not an rpi5 fault. **Confirm the next scheduled run clears it** rather than
      assuming; this is the second time this unit has failed for days (see the 2026-08-04
      note in `lab-alerts.yaml`).
- [ ] `monitoring-prometheus-node-exporter-fmxwl` has been crashlooping for **18 days** —
      unrelated to this incident and predating it. Worth its own look; it is the H4's
      node-exporter, so its absence is a monitoring blind spot on the most important host.
- [ ] Consider whether other units depend on `microshift-lvm-loop.service` implicitly and
      would benefit from the same explicit `x-systemd.requires=`.
- [ ] BACKLOG §1.12 — the unexplained 15-day lldap backup gap found while reading restic
      snapshots during this recovery.
- [ ] BACKLOG §3.14 — Prometheus evicts inside its nominal 30d retention, which is why that
      gap can no longer be investigated.

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

**Silence has at least two causes, and the log format decides which.** The `findmnt` lesson
above repeated itself twice more during recovery, in a form worth naming separately: an
Alertmanager receiver that succeeds first time logs nothing, and a `kubectl` selector that
matches nothing prints the same `No resources found` as a deleted workload. In both cases
empty output was read as "broken" when it meant "fine" or "wrong question." Before treating
absence as a finding, establish that the check *would* have produced output had the thing
been true — a control query against a case known to work costs one command.

**Run the control before publishing the conclusion.** The 15-day lldap gap was about to be
attributed to a known blind spot in `LabCronJobStale`, on the strength of an empty
Prometheus query mid-gap. The control — querying `up` at the same timestamp — came back
empty too: Prometheus had evicted the whole window under `retentionSize: 15GB`, well inside
its nominal `30d`. The query proved nothing about the metric, and without the control it
would have gone into this document as fact. It also produced a real finding that nobody was
looking for (§3.14).

**Ask what the human saw before investigating why they saw nothing.** An hour went into
finding the fault in an alerting pipeline that had no fault, because "you found this in the
Argo UI" was silently expanded into "no alert reached you." It had. The cheapest diagnostic
in the lab is a question.
