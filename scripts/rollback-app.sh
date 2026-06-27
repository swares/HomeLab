#!/usr/bin/env bash
# rollback-app.sh — revert the last commit on main and push.
#
# ArgoCD's selfHeal will detect the revert and reconcile the cluster back to
# the previous state within ~60s.  This script is called by the CI rollback job
# when validate-rollout.sh exits non-zero.
#
# Required env (set by CI):
#   CI_COMMIT_SHA     the commit that failed (so we know what to revert)
#   GIT_PUSH_TOKEN    GitLab token with write_repository scope
#   CI_SERVER_HOST    e.g. gitlab.lab.home.arpa
#   CI_PROJECT_PATH   e.g. homelab/homelab

set -euo pipefail

echo "=== Auto-rollback triggered ==="
echo "Reverting commit: ${CI_COMMIT_SHA:-HEAD}"
echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Safety check — refuse to run outside CI unless forced
if [ -z "${CI:-}" ] && [ -z "${FORCE_ROLLBACK:-}" ]; then
  echo "ERROR: This script is intended to run inside CI."
  echo "       Set FORCE_ROLLBACK=1 to run manually."
  exit 1
fi

# Ensure we're on main and have the latest state
git fetch origin main
git checkout main
git reset --hard origin/main

# Revert the failing commit (no-edit = use default commit message)
git revert "${CI_COMMIT_SHA:-HEAD}" --no-edit

# Push — ArgoCD watches main and will reconcile automatically
git push origin main

echo ""
echo "Revert pushed.  ArgoCD will reconcile within ~60s."
echo "Monitor: https://${ARGOCD_SERVER:-argocd.apps.lab.home.arpa}/applications"
