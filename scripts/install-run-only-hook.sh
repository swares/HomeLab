#!/bin/bash
# Install a pre-commit hook marking a checkout RUN-ONLY.
#
# WHY
#
# CLAUDE.md opens with it: there are two checkouts, the Windows one is
# authoritative, and the H4's (`~/lab/homelab/homelab`) is run-only — Ansible,
# kubectl, restic, the drills. Edits in one are invisible to git in the other.
#
# That split has cost real time. On 2026-08-17 an hour went to doc changes written
# in the Windows checkout while `git add`/`git status` ran on the H4, which
# reported "nothing added to commit" — accurately, about a different set of files.
# It also produced two envelope scripts differing only by hyphen versus underscore,
# one of which sat unreferenced on the H4's local `main` for two days.
#
# WHAT THIS DOES AND DOES NOT PREVENT
#
# Prevents: commits from this checkout. That is the half that leaves work stranded
# on a machine nobody opens PRs from.
#
# Does NOT prevent: `git reset --hard`, `git checkout -- <file>`, or any other
# command that discards a dirty working tree. Both incidents on 2026-09-19/20 were
# of that kind — uncommitted edits destroyed by a reset run in the wrong place —
# and no hook intercepts them. Git provides no pre-reset hook. Nothing short of a
# read-only mount would, and that would stop Ansible writing its own artifacts.
#
# So: this closes a real historical failure, not the most recent one. Worth being
# explicit about that rather than installing it and feeling covered.
#
# USAGE
#
#   ./scripts/install-run-only-hook.sh                 # install here
#   ./scripts/install-run-only-hook.sh --uninstall     # remove
#
# Bypass for a genuine one-off, which should be rare enough to feel wrong:
#
#   git commit --no-verify

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "FATAL: not inside a git repository." >&2
  exit 1
}

# --git-path resolves correctly with worktrees and a non-default hooksPath,
# where a hardcoded .git/hooks would silently install somewhere git never looks.
hook_dir=$(git rev-parse --git-path hooks)
hook="${hook_dir}/pre-commit"

if [ "${1:-}" = "--uninstall" ]; then
  if [ -e "$hook" ] && grep -q 'RUN-ONLY checkout guard' "$hook" 2>/dev/null; then
    rm -f "$hook"
    echo "Removed the run-only guard from $hook"
  else
    echo "No run-only guard found at $hook — nothing to do."
  fi
  exit 0
fi

# Refuse to clobber an unrelated hook rather than silently replacing it.
if [ -e "$hook" ] && ! grep -q 'RUN-ONLY checkout guard' "$hook" 2>/dev/null; then
  echo "FATAL: $hook already exists and is not this guard." >&2
  echo "       Inspect it and merge by hand; refusing to overwrite." >&2
  exit 1
fi

mkdir -p "$hook_dir"
cat > "$hook" <<'HOOK'
#!/bin/bash
# RUN-ONLY checkout guard — installed by scripts/install-run-only-hook.sh
#
# This checkout is for running things, not committing them. Commit from the
# Windows checkout, which is authoritative. See CLAUDE.md, "There are two
# checkouts — commit from one of them".
#
# Deliberate override:  git commit --no-verify
cat >&2 <<'MSG'

  ┌──────────────────────────────────────────────────────────────────────┐
  │  COMMIT REFUSED — this is the RUN-ONLY checkout.                     │
  └──────────────────────────────────────────────────────────────────────┘

  Commit from the Windows checkout. That one is authoritative; this one is
  for Ansible, kubectl, restic and the drills, and is kept pinned with:

      git fetch origin && git reset --hard origin/main

  A commit made here will not be in any PR, and a `reset --hard` on the next
  run will delete it without warning. That has happened: an envelope script
  sat on this box's local main for two days, unreferenced.

  If you genuinely mean it:   git commit --no-verify

MSG
exit 1
HOOK

chmod +x "$hook"

echo "Installed the run-only guard at $hook"
echo
echo "Verify it refuses, rather than trusting that it is there —"
echo "an untested guard is the thing this repo keeps finding:"
echo
echo "    touch /tmp/guard-test && git add -N /tmp/guard-test 2>/dev/null"
echo "    git commit --allow-empty -m 'guard test'   # must exit 1"
echo
echo "Repo: $repo_root"
