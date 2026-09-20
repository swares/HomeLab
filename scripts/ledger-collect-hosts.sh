#!/usr/bin/env bash
# ledger-collect-hosts.sh — record reboots and package upgrades across the fleet.
#
# WHY THIS SOURCE EXISTS
#
# On 2026-08-26 n150-2 — an etcd voter — stopped synchronising time for 18 hours.
# The whole causal chain was four journal lines:
#
#     06:10:49  apt-daily-upgrade.service starts (unattended-upgrades)
#     06:11:37  systemd re-executes, pulled in by a package upgrade
#     06:11:38  Stopping systemd-networkd.service
#     06:11:38  chronyd: "Source <all 17> offline"
#
# Without them the fault is unexplainable — and they were 18 hours from expiring
# on a host whose journal was volatile at the time. "What upgraded or rebooted
# just before this broke" is the most common correlation question in a lab that
# runs unattended-upgrades nightly on every host, and nothing recorded it.
#
# It also covers the other half: BACKLOG §1.13 notes this is reproducible
# fleet-wide, and n150-1 escaped by timing rather than configuration. A ledger of
# upgrade events makes "which hosts got systemd on which night" answerable
# instead of forensic.
#
# WHY IT RUNS FROM THE H4 OVER SSH
#
# The alternative — a collector on every host writing a local spool that the H4
# gathers — needs the network to work at collection time either way, and adds an
# agent to sixteen hosts to save one ssh loop. The H4 already holds SSH access to
# the whole fleet because Ansible runs from there.
#
# The limitation is honest and worth stating: a host that is DOWN contributes
# nothing, so this cannot capture the moment a board drops off the network. That
# case is covered by making the local journal durable instead (journald.yml), not
# by shipping — for a network-loss fault, shipping is structurally incapable.
set -euo pipefail

LEDGER_DIR="${LEDGER_DIR:-/var/lib/lab-ledger}"
STATE_FILE="${STATE_FILE:-$LEDGER_DIR/.state-hosts}"
EMIT="${EMIT:-/usr/local/sbin/ledger-emit.sh}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new}"

# host:address pairs. Canonical INVENTORY names, not whatever the host calls
# itself — §4 requires refs[] to carry the inventory name because real hostnames
# in this fleet use four naming conventions and match the inventory in two cases
# (BACKLOG §3.10). Duplicated entries (.116, .148, .184, .217 each appear twice
# in the inventory, BACKLOG §3.12) are listed ONCE here on purpose.
HOSTS="${LEDGER_HOSTS:-\
odroid-nas:192.168.1.160 \
n150-1:192.168.1.42 \
n150-2:192.168.1.21 \
opi5pro-1:192.168.1.168 \
opi5pro-2:192.168.1.172 \
rpi5:192.168.1.128 \
rpi4b:192.168.1.116 \
octopi-dns:192.168.1.148 \
opi-zero2w-1:192.168.1.184 \
opi-zero2w-2:192.168.1.188 \
opi-zero2w-3:192.168.1.217 \
opi-zero2w-4:192.168.1.99 \
gitlab-1:192.168.1.50 \
xu3-1:192.168.1.64}"

mkdir -p "$LEDGER_DIR"
touch "$STATE_FILE"

emitted=0
unreachable=0

for entry in $HOSTS; do
  name="${entry%%:*}"
  addr="${entry#*:}"

  # One ssh per host carrying both probes, to keep this to a single round trip.
  # boot_id changes exactly once per boot and is the cheapest reboot detector
  # available; uptime would need arithmetic and drifts with clock corrections —
  # which this lab has demonstrably had.
  probe="$(ssh $SSH_OPTS "$addr" '
      echo "BOOTID $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
      echo "BOOTAT $(date -u -d "@$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
      # dpkg.log lines look like: 2026-08-26 06:11:32 upgrade systemd:amd64 249.11-0 249.11-1
      # Only `upgrade` and `install` matter; `status` lines are per-step noise.
      grep -hE " (upgrade|install) " /var/log/dpkg.log 2>/dev/null | tail -200 || true
    ' 2>/dev/null)" || {
      echo "ledger-collect-hosts: $name ($addr) unreachable" >&2
      unreachable=$((unreachable + 1))
      continue
    }

  boot_id="$(printf '%s\n' "$probe" | awk '/^BOOTID /{print $2; exit}')"
  boot_at="$(printf '%s\n' "$probe" | awk '/^BOOTAT /{print $2; exit}')"

  if [ -n "$boot_id" ] && ! grep -qxF "boot:$name:$boot_id" "$STATE_FILE"; then
    "$EMIT" \
      --timestamp "${boot_at:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
      --source host --actor kernel --subject "$name" \
      --action boot --outcome success \
      --ref "$name" --ref "$addr" \
      --detail "$(jq -cn --arg id "$boot_id" '{boot_id:$id}')"
    echo "boot:$name:$boot_id" >> "$STATE_FILE"
    emitted=$((emitted + 1))
  fi

  # Package upgrades. The dedup key is host+timestamp+package+version, so a
  # re-read of the same dpkg.log emits nothing twice, and log rotation losing
  # old lines simply means older events are not backfilled — never duplicated.
  while read -r d t verb pkg oldv newv; do
    [ -n "${pkg:-}" ] || continue
    key="pkg:$name:$d $t:$pkg:${newv:-}"
    grep -qxF "$key" "$STATE_FILE" && continue
    "$EMIT" \
      --timestamp "$(date -u -d "$d $t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "${d}T${t}Z")" \
      --source package --actor "${verb}" --subject "$name" \
      --action "$verb" --outcome success \
      --ref "$name" --ref "${pkg%%:*}" \
      --detail "$(jq -cn --arg p "$pkg" --arg o "${oldv:-}" --arg n "${newv:-}" \
                    '{package:$p, from:$o, to:$n}')"
    echo "$key" >> "$STATE_FILE"
    emitted=$((emitted + 1))
  done < <(printf '%s\n' "$probe" | grep -E " (upgrade|install) " || true)
done

# Print both numbers. "emitted 0" alone is ambiguous — it means either nothing
# changed (correct, and the usual case) or every host was unreachable (a fault).
# Reporting the unreachable count is what makes the zero readable, which is the
# lesson this lab keeps relearning.
echo "ledger-collect-hosts: emitted $emitted entries, $unreachable hosts unreachable"
