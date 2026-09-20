#!/usr/bin/env bash
# ledger-emit.sh — append one entry to the lab ledger.
#
# The ledger is an append-only JSONL file of timestamped FACTS: things that
# happened, not things someone believes. See docs/LEDGER-DESIGN.md §4 for the
# envelope and §5 for why ledger entries and narrative are kept apart.
#
# WHY A FILE AND NOT A DATABASE
#
# §8 of the design deferred the engine choice on purpose, and this keeps that
# door open. JSONL on disk has three properties a database would have to earn:
# it cannot silently stop working, it is greppable with jq today, and it replays
# into any engine later. The volume is kilobytes a day — the whole point of the
# ledger is that it records changes, not telemetry (§3.3).
#
# WHY IT LIVES ON THE HOT TIER
#
# /var/lib/lab-ledger is on the H4's NVMe and is included in backup-nas, so it
# reaches both cold mirrors and the offsite repo through the existing chain. It
# is deliberately NOT written to /srv/nas (NAS data is off-limits per CLAUDE.md)
# and not to a new restic repo on the cold tier (which CLAUDE.md is strict about
# and which would add a repo to the rotation for no benefit).
#
# Usage:
#   ledger-emit.sh --source restic --actor backup-nas --subject lldap \
#       --action snapshot --outcome success \
#       --ref b53108ec --ref lldap-k8s \
#       --detail '{"bytes":17482,"paths":["/dump/lldap.sql"]}' \
#       [--timestamp 2026-08-27T02:30:05Z]
#
# Timestamps: pass --timestamp with the time the EVENT happened, not the time it
# was collected. A restic snapshot from three days ago belongs at its own time.
# Defaults to now, which is only correct for events observed as they occur.
set -euo pipefail

LEDGER_DIR="${LEDGER_DIR:-/var/lib/lab-ledger}"

ts=""; source=""; actor=""; subject=""; action=""; outcome="unknown"
detail="{}"; refs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --timestamp) ts="$2"; shift 2 ;;
    --source)    source="$2"; shift 2 ;;
    --actor)     actor="$2"; shift 2 ;;
    --subject)   subject="$2"; shift 2 ;;
    --action)    action="$2"; shift 2 ;;
    --outcome)   outcome="$2"; shift 2 ;;
    --detail)    detail="$2"; shift 2 ;;
    --ref)       refs+=("$2"); shift 2 ;;
    *) echo "ledger-emit: unknown argument: $1" >&2; exit 2 ;;
  esac
done

for required in source subject action; do
  if [ -z "${!required}" ]; then
    echo "ledger-emit: --$required is required" >&2
    exit 2
  fi
done

[ -n "$ts" ] || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# jq builds the line so escaping is correct for anything that lands in `detail`
# or a hostname. Hand-rolled JSON here would break on the first log message with
# a quote in it, and would do so silently — the failure mode this repo keeps
# writing up.
if ! command -v jq >/dev/null 2>&1; then
  echo "ledger-emit: jq is required" >&2
  exit 3
fi

# Validate the caller's detail blob before it reaches the ledger. An entry is
# supposed to be true by construction (§5); a malformed one poisons every later
# query and there is no schema check downstream to catch it.
if ! printf '%s' "$detail" | jq -e . >/dev/null 2>&1; then
  echo "ledger-emit: --detail is not valid JSON: $detail" >&2
  exit 4
fi

mkdir -p "$LEDGER_DIR"
month_file="$LEDGER_DIR/$(date -u -d "$ts" +%Y-%m 2>/dev/null || date -u +%Y-%m).jsonl"

# refs[] is the join key across sources (§4). Exact tokens, never embeddings:
# 192.168.1.160 and 192.168.1.201 are neighbours in vector space and that
# confusion is what caused the wildcard outage.
refs_json="$(printf '%s\n' "${refs[@]+"${refs[@]}"}" | jq -R . | jq -s 'map(select(length>0))')"

jq -cn \
  --arg ts "$ts" \
  --arg source "$source" \
  --arg actor "$actor" \
  --arg subject "$subject" \
  --arg action "$action" \
  --arg outcome "$outcome" \
  --argjson detail "$detail" \
  --argjson refs "$refs_json" \
  '{"@timestamp":$ts, source:$source, actor:$actor, subject:$subject,
    action:$action, outcome:$outcome, refs:$refs, detail:$detail}' \
  >> "$month_file"
