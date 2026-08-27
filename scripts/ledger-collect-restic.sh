#!/usr/bin/env bash
# ledger-collect-restic.sh — record every restic snapshot as a ledger entry.
#
# WHY THIS SOURCE EXISTS, AND WHY IT IS FIRST
#
# On 2026-08-27 a fifteen-day gap in lldap's backups (2026-08-04 → 08-19) was
# discovered by reading `restic snapshots` output. Nothing else could have found
# it: the Kubernetes events had expired within the hour, Prometheus had evicted
# the window under retentionSize (BACKLOG §3.14), and the Jobs had rotated out
# of failedJobsHistoryLimit. Three snapshot timestamps were the entire surviving
# record of a two-week outage of the identity database's only backup.
#
# docs/LEDGER-DESIGN.md §3.2 originally listed "backup outcomes" as a journal
# parsing task. That is a different and weaker source: journals expire, and a
# backup that never ran writes no journal line at all. The snapshot list is the
# artifact that only a successful backup can produce — the §5 test.
#
# BACKFILL IS FREE, AND THAT IS THE POINT
#
# Unlike every other ledger source, this one starts complete: restic already
# holds the full history, so the first run imports months of real events rather
# than beginning at zero. Absence in this stream is meaningful from day one.
#
# READ-ONLY BY CONSTRUCTION. This script runs `restic snapshots` and nothing
# else. It must never call forget, prune, or backup — retention is owned by the
# backup timers alone (CLAUDE.md), and a collector that can delete the thing it
# observes is a liability.
set -euo pipefail

LEDGER_DIR="${LEDGER_DIR:-/var/lib/lab-ledger}"
STATE_FILE="${STATE_FILE:-$LEDGER_DIR/.state-restic}"
EMIT="${EMIT:-/usr/local/sbin/ledger-emit.sh}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/restic/password}"

# Repositories to inventory. Each is "name:path". The offsite (R2) repo is
# deliberately excluded: it is a copy of the primary, so its snapshots duplicate
# entries already recorded, and reaching it costs an API round trip per run.
REPOS="${LEDGER_RESTIC_REPOS:-primary:/mnt/cold-8t/restic secondary:/mnt/cold-sec/restic}"

mkdir -p "$LEDGER_DIR"
touch "$STATE_FILE"

emitted=0
for entry in $REPOS; do
  repo_name="${entry%%:*}"
  repo_path="${entry#*:}"

  # A missing repo is not an error worth failing the timer over — cold-sec can
  # be unmounted (nofail, per the 2026-08-23 incident) without that meaning the
  # ledger should stop collecting from the primary.
  if [ ! -f "$repo_path/config" ]; then
    echo "ledger-collect-restic: no repository at $repo_path, skipping" >&2
    continue
  fi

  # --no-lock: this is a read, and taking a lock would contend with the backup
  # timers. Lock contention already cost four consecutive nights of backups in
  # August (BACKLOG §1.9); a collector must not be able to repeat that.
  snapshots="$(RESTIC_PASSWORD_FILE="$PASSWORD_FILE" \
    restic -r "$repo_path" snapshots --json --no-lock 2>/dev/null || echo '[]')"

  while IFS=$'\t' read -r id time host tags paths; do
    [ -n "$id" ] || continue

    # Dedup key includes the repo: the same snapshot id exists in the primary
    # and its copy, and both are worth recording — "the copy happened" is its
    # own fact, and its absence is how a broken replication would show.
    key="$repo_name:$id"
    grep -qxF "$key" "$STATE_FILE" && continue

    "$EMIT" \
      --timestamp "$time" \
      --source restic \
      --actor "$repo_name" \
      --subject "${tags:-untagged}" \
      --action snapshot \
      --outcome success \
      --ref "$id" \
      --ref "$host" \
      ${tags:+--ref "$tags"} \
      --detail "$(jq -cn --arg repo "$repo_path" --arg paths "$paths" \
                    '{repo:$repo, paths:($paths|split(","))}')"

    echo "$key" >> "$STATE_FILE"
    emitted=$((emitted + 1))
  done < <(printf '%s' "$snapshots" | jq -r '
      .[] | [
        .short_id,
        .time,
        (.hostname // ""),
        ((.tags // []) | join(",")),
        ((.paths // []) | join(","))
      ] | @tsv')
done

# A number only the work can produce. "0 new" on a second run is correct and
# expected; "0 new" on the FIRST run means the repos were unreadable and the
# ledger silently collected nothing — which is why this prints the count rather
# than exiting quietly.
echo "ledger-collect-restic: emitted $emitted new snapshot entries"
