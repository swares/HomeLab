#!/usr/bin/env bash
# validate-rollout.sh — wait for ArgoCD sync completion then health-probe every Route.
#
# Exit 0 = healthy.  Exit 1 = timeout or unhealthy — CI will trigger rollback.
#
# Required env:
#   ARGOCD_SERVER       e.g. argocd.apps.lab.home.arpa
#   ARGOCD_AUTH_TOKEN   ArgoCD API token
#   KUBECONFIG          path to kubeconfig (set by CI before_script)
#
# Optional env:
#   ROLLOUT_TIMEOUT     seconds to wait for ArgoCD sync   (default 300)
#   HEALTH_TIMEOUT      seconds per HTTP Route probe      (default 60)
#   ARGOCD_OPTS         extra argocd CLI flags

set -euo pipefail

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
REPORT="rollout-report.txt"
ARGOCD_OPTS="${ARGOCD_OPTS:---grpc-web}"

echo "=== Rollout Validation $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee "$REPORT"
echo "Commit: ${CI_COMMIT_SHA:-local}" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

# ── 1. Discover ArgoCD applications ──────────────────────────────────────────
echo "--- ArgoCD Applications ---" | tee -a "$REPORT"

APPS=$(argocd app list \
  --server "$ARGOCD_SERVER" \
  --auth-token "$ARGOCD_AUTH_TOKEN" \
  $ARGOCD_OPTS \
  --output name 2>/dev/null) || {
    echo "ERROR: Cannot reach ArgoCD at $ARGOCD_SERVER" | tee -a "$REPORT"
    exit 1
  }

echo "Apps: $(echo "$APPS" | tr '\n' ' ')" | tee -a "$REPORT"

# ── 2. Wait for every app to be Synced + Healthy ─────────────────────────────
echo "" | tee -a "$REPORT"
echo "--- Waiting for sync (timeout ${ROLLOUT_TIMEOUT}s) ---" | tee -a "$REPORT"

FAILED_APPS=()
for APP in $APPS; do
  echo -n "  $APP ... " | tee -a "$REPORT"
  if argocd app wait "$APP" \
       --server "$ARGOCD_SERVER" \
       --auth-token "$ARGOCD_AUTH_TOKEN" \
       $ARGOCD_OPTS \
       --sync \
       --health \
       --timeout "$ROLLOUT_TIMEOUT" 2>>"$REPORT"; then
    echo "OK" | tee -a "$REPORT"
  else
    echo "FAILED" | tee -a "$REPORT"
    FAILED_APPS+=("$APP")
  fi
done

if [ ${#FAILED_APPS[@]} -gt 0 ]; then
  echo "" | tee -a "$REPORT"
  echo "FAIL: Apps not healthy: ${FAILED_APPS[*]}" | tee -a "$REPORT"
  exit 1
fi

# ── 3. Confirm all pods are Running/Completed ─────────────────────────────────
echo "" | tee -a "$REPORT"
echo "--- Pod health ---" | tee -a "$REPORT"

NOT_READY=$(oc get pods --all-namespaces \
  --field-selector='status.phase!=Running,status.phase!=Succeeded' \
  --no-headers 2>/dev/null | grep -v "Completed\|Running" || true)

if [ -n "$NOT_READY" ]; then
  echo "WARN: Pods not in Running/Succeeded state:" | tee -a "$REPORT"
  echo "$NOT_READY" | tee -a "$REPORT"
  # Non-fatal warning — some init containers may still be settling
else
  echo "All pods Running or Succeeded." | tee -a "$REPORT"
fi

# ── 4. HTTP probe every Route ─────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "--- Route health probes ---" | tee -a "$REPORT"

ROUTES=$(oc get routes --all-namespaces \
  -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null || true)

if [ -z "$ROUTES" ]; then
  echo "No Routes found — skipping HTTP probes." | tee -a "$REPORT"
else
  FAILED_ROUTES=()
  while IFS= read -r HOST; do
    [ -z "$HOST" ] && continue
    URL="https://${HOST}"
    echo -n "  GET $URL ... " | tee -a "$REPORT"
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
      --max-time "$HEALTH_TIMEOUT" "$URL" || echo "000")
    if [[ "$HTTP_CODE" =~ ^[23] ]]; then
      echo "HTTP $HTTP_CODE OK" | tee -a "$REPORT"
    elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
      # Auth-gated endpoints are reachable — count as healthy
      echo "HTTP $HTTP_CODE (auth-gated, OK)" | tee -a "$REPORT"
    else
      echo "HTTP $HTTP_CODE FAIL" | tee -a "$REPORT"
      FAILED_ROUTES+=("$HOST")
    fi
  done <<< "$ROUTES"

  if [ ${#FAILED_ROUTES[@]} -gt 0 ]; then
    echo "" | tee -a "$REPORT"
    echo "FAIL: Unhealthy Routes: ${FAILED_ROUTES[*]}" | tee -a "$REPORT"
    exit 1
  fi
fi

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "=== PASS: All checks healthy $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$REPORT"
exit 0
