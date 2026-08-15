#!/bin/bash
#
# Print the break-glass envelope: docs/BREAK-GLASS.md plus a table of the actual
# credentials, rendered to PDF and sent to the default printer.
#
# THIS SCRIPT HANDLES SECRETS. Design rules, all of which have a reason:
#
#   - Nothing is echoed. An earlier version printed every value from cloud.env to
#     stdout as a debug aid, which put AWS_SECRET_ACCESS_KEY and
#     MINIO_ROOT_PASSWORD into the terminal, the scrollback and any session log.
#   - Everything renders under TMPDIR on /dev/shm (tmpfs), so no intermediate
#     touches persistent storage. xelatex writes several MB of temp files; without
#     this they land in /tmp on the eMMC, where rm and shred cannot reliably erase
#     them because of wear levelling.
#   - The CUPS spool is purged AFTER the queue drains. On 2026-08-15 twenty
#     rendered copies sat in /var/spool/cups for fifteen hours. Purging before the
#     job prints would instead cancel it — clean spool, no paper.
#   - Manual steps are printed at the end because the script cannot shred paper or
#     power-cycle a printer, and those are the copies that need no root to read.
#
# Usage:  cd scripts && ./print-offline-envelope.sh [-d printer] [--dry-run]
#
#   --dry-run   render and report size, print nothing, purge nothing. Use this
#               when editing the layout so you are not producing paper drafts.

set -euo pipefail

PRINTER=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d) PRINTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOC="$SCRIPT_DIR/../docs/BREAK-GLASS.md"
[ -r "$DOC" ] || { echo "FATAL: cannot read $DOC" >&2; exit 1; }

# ---- tmpfs workspace, shredded on every exit path --------------------------
WORKDIR=$(mktemp -d /dev/shm/envelope.XXXXXX)
chmod 700 "$WORKDIR"
cleanup_workdir() {
  find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup_workdir EXIT INT TERM
export TMPDIR="$WORKDIR"     # pandoc and xelatex inherit this

# ---- Configuration, derived not hardcoded ----------------------------------
# Everything here is read from the running system or from git. A hardcoded value
# in this script is a value that will be wrong the day it changes — and the
# envelope is precisely the document you cannot afford to have wrong. The one
# exception is the fallback table below, which exists so a missing file gives a
# clear failure rather than an empty row.

# Ansible defines these paths; read them from the playbooks so a change there
# propagates here. Falls back to the current value if the grep misses, and the
# read_secret check below will fail loudly if the path is wrong either way.
ansible_var() {   # ansible_var <var-name> <fallback> <playbook-or-vars-file>
  local v
  v=$(grep -oP "^\s*$1:\s*\K[^\s#]+" "$3" 2>/dev/null | head -1 | tr -d "\"'")
  echo "${v:-$2}"
}

PB="$SCRIPT_DIR/../ansible/playbooks"
GV="$SCRIPT_DIR/../ansible/inventory/group_vars"

RESTIC_PW_FILE=$(ansible_var restic_password_file      /etc/restic/password        "$PB/backup.yml")
CLOUD_PW_FILE=$(ansible_var  cloud_password_file       /etc/restic/cloud-password  "$PB/backup-cloud.yml")
CLOUD_ENV_FILE=$(ansible_var cloud_env_file            /etc/restic/cloud.env       "$PB/backup.yml")
OFFSITE_ENV_FILE=$(ansible_var offsite_env_file        /etc/restic/offsite.env     "$PB/backup.yml")
UNSEAL_FILE=$(ansible_var    vault_unseal_keys_file    /etc/vault.d/unseal-keys    "$GV/vault/vault.yml")
K3S_TOKEN_FILE=/var/lib/rancher/k3s/server/node-token   # fixed by k3s, not by us
ANSIBLE_VAULT_FILE="$SCRIPT_DIR/../ansible/.vault_pass"

# Vault address: /etc/environment on this host, set by ansible/playbooks/vault-client.yml.
VAULT_ADDR=$(grep -oP '^VAULT_ADDR=\K\S+' /etc/environment 2>/dev/null || true)
VAULT_ADDR=${VAULT_ADDR:-http://192.168.1.128:8200}
VAULT_HOST=$(sed -E 's#^https?://##; s#:.*$##' <<<"$VAULT_ADDR")

# Git remote: ask git, do not transcribe it.
GIT_REMOTE=$(git -C "$SCRIPT_DIR/.." remote get-url origin 2>/dev/null || echo "UNKNOWN")

declare -A CRED

# ---- Gather -----------------------------------------------------------------
# Deliberately no output. If a source is missing, fail loudly rather than
# printing an envelope with a blank row nobody notices until it matters.
read_secret() {   # read_secret <key> <file>
  local key=$1 file=$2
  sudo test -r "$file" || { echo "FATAL: cannot read $file" >&2; exit 1; }
  CRED[$key]=$(sudo cat "$file")
}

read_secret RESTIC_PASSWORD        "$RESTIC_PW_FILE"
read_secret RESTIC_CLOUD_PASSWORD  "$CLOUD_PW_FILE"
read_secret RANCHER_K3S_TOKEN      "$K3S_TOKEN_FILE"
read_secret ANSIBLE_VAULT_PASS     "$ANSIBLE_VAULT_FILE"

# Both R2 repository URLs come straight from the env files the backup jobs use,
# so the account ID is never transcribed into this script. If the bucket or
# account changes, this follows automatically.
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" =~ ^# ]] && continue
  CRED["RC_ENV_$key"]="$value"
done < <(sudo cat "$CLOUD_ENV_FILE")

while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" =~ ^# ]] && continue
  CRED["OS_ENV_$key"]="$value"
done < <(sudo cat "$OFFSITE_ENV_FILE")

CLOUD_REPO=${CRED[RC_ENV_RESTIC_REPOSITORY]:-UNKNOWN}
OFFSITE_REPO=${CRED[OS_ENV_RESTIC_REPOSITORY_OFFSITE]:-UNKNOWN}
# Account ID is a substring of either URL — extract rather than hardcode.
R2_ID=$(sed -E 's#^s3:https://([^.]+)\..*#\1#' <<<"$CLOUD_REPO")

readarray -t UNSEAL < <(ssh "$VAULT_HOST" "sudo cat $UNSEAL_FILE")
[ "${#UNSEAL[@]}" -ge 3 ] || { echo "FATAL: expected >=3 unseal keys, got ${#UNSEAL[@]}" >&2; exit 1; }

# The k3s token is ~100 chars and overflows the page; split it across two rows.
tok=${CRED[RANCHER_K3S_TOKEN]}
half=$(( ${#tok} / 2 ))
TOK1="${tok:0:half}"
TOK2="${tok:half}"

# ---- Render -----------------------------------------------------------------
{
  cat "$DOC"
  cat <<EOF

\\newpage

# Credentials — as of $(date -u '+%Y-%m-%d %H:%M UTC')

Column widths in a pandoc pipe table come from the dash counts below, so the
separator row is deliberately lopsided — keep it that way or the right column
runs off the page.

| #  | What                     | Without it |
|:---|:-------------------------|:-------------------------------------------------------------------------------------|
| 1  | restic password          | both local repos are undecryptable ciphertext |
| 2  | R2 restic password       | **both** R2 repos are undecryptable — they share one password |
| 3  | R2 account ID + API keys | you cannot reach the R2 buckets at all |
| 4  | k3s server token         | etcd snapshots are unrestorable on new hardware; k3s derives the datastore key from it |
| 5  | Vault unseal shares      | Vault stays sealed, so every ExternalSecret stays empty |
| 6  | Ansible vault password   | encrypted group_vars are unreadable, so those playbooks will not run |

| What | Value |
| ---- | ----- |
| restic password (#1) | \`${CRED[RESTIC_PASSWORD]}\` |
| R2 restic password (#2) | \`${CRED[RESTIC_CLOUD_PASSWORD]}\` |
| R2 account ID (#3) | \`${R2_ID}\` |
| AWS_ACCESS_KEY_ID (#3) | \`${CRED[RC_ENV_AWS_ACCESS_KEY_ID]:-MISSING}\` |
| AWS_SECRET_ACCESS_KEY (#3) | \`${CRED[RC_ENV_AWS_SECRET_ACCESS_KEY]:-MISSING}\` |
| k3s server token, part 1 of 2 (#4) | \`${TOK1}\` |
| k3s server token, part 2 of 2 (#4) | \`${TOK2}\` |
| Vault unseal share 1 (#5) | \`${UNSEAL[0]}\` |
| Vault unseal share 2 (#5) | \`${UNSEAL[1]}\` |
| Vault unseal share 3 (#5) | \`${UNSEAL[2]}\` |
| Ansible vault password (#6) | \`${CRED[ANSIBLE_VAULT_PASS]}\` |
| MinIO root user | \`${CRED[RC_ENV_MINIO_ROOT_USER]:-MISSING}\` |
| MinIO root password | \`${CRED[RC_ENV_MINIO_ROOT_PASSWORD]:-MISSING}\` |

## Not secret, but you will not have the repo

Deliberately a list, not a table. These are long unbroken URLs, and inline code
spans do not wrap in LaTeX — \`fvextra\`'s breaklines applies to code *blocks*, not
\`\\texttt\`. In a table they simply run off the right margin. As list items they
wrap like ordinary text.

- **Offsite NAS repo**
  \`${OFFSITE_REPO}\`
- **Offsite cluster-state repo**
  \`${CLOUD_REPO}\`
- **Git remote**
  \`${GIT_REMOTE}\`
- **Vault address**
  \`${VAULT_ADDR}\`
- **Vault unseal keys file**, on \`${VAULT_HOST}\`
  \`${UNSEAL_FILE}\`

The k3s token is split across two rows only to fit the page. Concatenate parts 1
and 2 with no separator and no whitespace.
EOF
} > "$WORKDIR/envelope.md"

# LaTeX preamble as a file, not as a -M/-V argument. `-M header-includes` sets
# *metadata*, which pandoc escapes — so \usepackage arrives as \textbackslash
# usepackage, lands before \begin{document}, and xelatex fails with
# "Missing \begin{document}". A header file passes through verbatim and needs no
# shell escaping, which is the whole class of bug avoided.
#
# seqsplit lets long unbroken secrets wrap; fvextra does the same inside code
# spans. Both matter here: unseal shares and the k3s token are single tokens
# wider than the page.
cat > "$WORKDIR/header.tex" <<'TEX'
\usepackage{seqsplit}
\usepackage{fvextra}
\DefineVerbatimEnvironment{Highlighting}{Verbatim}{breaklines=true,breakanywhere=true,commandchars=\\\{\}}
TEX

pandoc "$WORKDIR/envelope.md" -o "$WORKDIR/envelope.pdf" \
  --pdf-engine=xelatex \
  --include-in-header="$WORKDIR/header.tex" \
  -V fontsize=8pt \
  -V geometry:landscape \
  -V geometry:"top=2cm, bottom=2cm, left=1cm, right=1cm" \
  -f markdown

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run: rendered $(stat -c%s "$WORKDIR/envelope.pdf") bytes. Nothing printed."
  echo "Workspace shredded on exit."
  exit 0
fi

# ---- Print ------------------------------------------------------------------
if [ -n "$PRINTER" ]; then lp -d "$PRINTER" "$WORKDIR/envelope.pdf"
else                       lp "$WORKDIR/envelope.pdf"
fi

# ---- Purge the spool, but only once the job has actually gone ---------------
wait_for_queue() {
  local waited=0 timeout=300
  while lpstat -o 2>/dev/null | grep -q .; do
    if [ "$waited" -ge "$timeout" ]; then
      echo "WARN: queue still busy after ${timeout}s — NOT purging." >&2
      echo "      Check 'lpstat -p -o'. The spool still holds your credentials;" >&2
      echo "      purge by hand once it clears." >&2
      return 1
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
}

purge_cups() {
  # cupsd keeps job state in memory and rewrites job.cache on shutdown, so stop it
  # first or the entries come straight back.
  sudo systemctl stop cups cups-browsed 2>/dev/null || true
  sudo rm -f /var/spool/cups/d* /var/spool/cups/c*
  sudo rm -rf /var/spool/cups/tmp/*
  sudo rm -f /var/cache/cups/job.cache /var/cache/cups/*.data
  sudo truncate -s 0 /var/log/cups/access_log /var/log/cups/error_log 2>/dev/null || true
  sudo systemctl start cups
}

echo "Waiting for the print queue to drain..."
if wait_for_queue; then
  purge_cups
  echo "CUPS spool, job cache and logs purged."
fi

cat <<'MANUAL'

────────────────────────────────────────────────────────────────────────
 MANUAL STEPS — the script cannot do these
────────────────────────────────────────────────────────────────────────

 1. SHRED every draft. Cross-cut or burn; strip-cut can be reassembled.
    Each page is a complete dump of every credential in the lab, and it
    needs no root access to read.

 2. POWER-CYCLE THE PRINTER. The HL-5100DN buffers jobs in RAM. Pull the
    power, count to ten. Check its web UI for secure-print or reprint
    storage while you are there.

 3. STORE THE KEEPER COPY OFF THE PROPERTY. An envelope beside the H4
    solves the credential problem and not the fire.

 4. UPDATE THE CURRENCY TABLE in docs/BREAK-GLASS.md. A stale envelope is
    worse than none, because you will trust it.

 Note: rm and shred do not reliably erase flash storage — wear levelling
 may retain the blocks regardless. That is why this renders in /dev/shm
 and never writes the document to disk.

 Editing the layout? Use --dry-run so you are not making paper drafts.
────────────────────────────────────────────────────────────────────────
MANUAL
