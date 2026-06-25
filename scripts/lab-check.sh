#!/bin/bash
# lab-check.sh — full lab health check
# Run from the H4 as the ansible user (needs kubectl access).
# Exit code: 0 = all green, 1 = one or more issues found.

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;34m'; RST='\033[0m'
ok()   { echo -e "  ${GRN}✓${RST} $*"; }
warn() { echo -e "  ${YLW}⚠${RST} $*"; WARNINGS=$((WARNINGS+1)); }
fail() { echo -e "  ${RED}✗${RST} $*"; ERRORS=$((ERRORS+1)); }
section() { echo -e "\n${BLU}▶ $*${RST}"; }

ERRORS=0; WARNINGS=0

# ── DNS servers ───────────────────────────────────────────────────────────────
DNS_PRIMARY=192.168.1.148
DNS_SECONDARY=192.168.1.184
INGRESS_VIP=192.168.1.160
LAB_DOMAIN=lab.home.arpa

# ── Ingress endpoints to probe ────────────────────────────────────────────────
declare -A INGRESSES=(
  [argocd]="https://argocd.apps.${LAB_DOMAIN}"
  [immich]="https://immich.apps.${LAB_DOMAIN}"
  [ai-gateway]="https://ai.apps.${LAB_DOMAIN}/v1/models"
)

# ── Hosts to ping ─────────────────────────────────────────────────────────────
declare -A HOSTS=(
  [h4-core]=192.168.1.160
  [octopi/dns-1]=192.168.1.148
  [rpi5/vault]=192.168.1.128
  [opi-zero2w-1/dns-2]=192.168.1.184
  [opi-zero2w-2]=192.168.1.188
  [opi-zero2w-4]=192.168.1.99
  [opi5pro-1/inference]=192.168.1.168
  [opi5pro-2]=192.168.1.172
  [n150-1]=192.168.1.10
  [n150-2]=192.168.1.171
  [xu3-1]=192.168.1.64
)

echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
echo -e "${BLU}  Lab Health Check — $(date '+%Y-%m-%d %H:%M:%S %Z')${RST}"
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

# ─────────────────────────────────────────────────────────────────────────────
section "Host reachability"
for name in "${!HOSTS[@]}"; do
  ip="${HOSTS[$name]}"
  if ping -c1 -W2 "$ip" &>/dev/null; then
    ok "$name ($ip)"
  else
    fail "$name ($ip) — unreachable"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "DNS resolution"
for dns in $DNS_PRIMARY $DNS_SECONDARY; do
  label="dns@${dns}"
  resolved=$(dig +short "argocd.apps.${LAB_DOMAIN}" @"$dns" 2>/dev/null | head -1)
  if [[ "$resolved" == "$INGRESS_VIP" ]]; then
    ok "$label → argocd.apps.${LAB_DOMAIN} = $resolved"
  elif [[ -z "$resolved" ]]; then
    fail "$label — no answer for argocd.apps.${LAB_DOMAIN}"
  else
    warn "$label — resolved to $resolved (expected $INGRESS_VIP)"
  fi

  internet=$(dig +short google.com @"$dns" 2>/dev/null | head -1)
  if [[ -n "$internet" ]]; then
    ok "$label → internet forwarding works"
  else
    fail "$label — internet forwarding broken"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "k3s cluster"
while IFS= read -r line; do
  node=$(echo "$line" | awk '{print $1}')
  status=$(echo "$line" | awk '{print $2}')
  role=$(echo "$line" | awk '{print $3}')
  ver=$(echo "$line" | awk '{print $5}')
  if [[ "$status" == "Ready" ]]; then
    ok "$node ($role) — $ver"
  else
    fail "$node — $status"
  fi
done < <(kubectl get nodes --no-headers 2>/dev/null)

# ─────────────────────────────────────────────────────────────────────────────
section "ArgoCD applications"
while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  sync=$(echo "$line" | awk '{print $2}')
  health=$(echo "$line" | awk '{print $3}')
  if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
    ok "$name (Synced/Healthy)"
  elif [[ "$sync" == "Synced" && "$health" == "Progressing" ]]; then
    warn "$name (Synced/Progressing) — still rolling out"
  elif [[ "$health" == "Degraded" ]]; then
    fail "$name ($sync/$health)"
  else
    warn "$name ($sync/$health)"
  fi
done < <(kubectl get applications -n argocd --no-headers 2>/dev/null)

# ─────────────────────────────────────────────────────────────────────────────
section "Pod health (non-Running/Completed)"
bad_pods=$(kubectl get pods -A --no-headers 2>/dev/null | \
  grep -v -E '\s(Running|Completed|Succeeded)\s' || true)
if [[ -z "$bad_pods" ]]; then
  ok "All pods Running or Completed"
else
  while IFS= read -r line; do
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $4}')
    restarts=$(echo "$line" | awk '{print $5}')
    fail "[$ns] $pod — $status (restarts: $restarts)"
  done <<< "$bad_pods"
fi

# High restart count warning
kubectl get pods -A --no-headers 2>/dev/null | awk '{
  restarts=$5+0
  if (restarts >= 5) print $1, $2, $5
}' | while read ns pod restarts; do
  warn "[$ns] $pod has $restarts restarts"
done

# ─────────────────────────────────────────────────────────────────────────────
section "TLS certificates"
while IFS= read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  ready=$(echo "$line" | awk '{print $3}')
  if [[ "$ready" == "True" ]]; then
    ok "$ns/$name"
  else
    fail "$ns/$name — not ready"
  fi
done < <(kubectl get certificate -A --no-headers 2>/dev/null)

# Check cert expiry (warn if <30 days)
kubectl get secrets -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.type' 2>/dev/null | \
  grep 'kubernetes.io/tls' | while read ns name type; do
  expiry=$(kubectl get secret "$name" -n "$ns" \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | \
    base64 -d 2>/dev/null | \
    openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [[ -n "$expiry" ]]; then
    days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null) - $(date +%s) ) / 86400 ))
    if [[ $days -lt 0 ]]; then
      fail "$ns/$name — EXPIRED"
    elif [[ $days -lt 30 ]]; then
      warn "$ns/$name — expires in ${days}d"
    else
      ok "$ns/$name — expires in ${days}d"
    fi
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "Ingress HTTP/S endpoints"
for name in "${!INGRESSES[@]}"; do
  url="${INGRESSES[$name]}"
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|301|302|307|401)$ ]]; then
    ok "$name → $url ($code)"
  elif [[ "$code" == "000" ]]; then
    fail "$name → $url — no response (timeout/connection refused)"
  else
    warn "$name → $url — HTTP $code"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "Backup timers"
for timer in backup-nas.timer backup-etcd.timer; do
  state=$(systemctl is-active "$timer" 2>/dev/null)
  next=$(systemctl show "$timer" --property=NextElapseUSecRealtime 2>/dev/null | \
    awk -F= '{print $2}')
  if [[ "$state" == "active" ]]; then
    ok "$timer active"
  else
    fail "$timer — $state"
  fi
done

# Last backup run check (warn if NAS backup hasn't run in >26h)
last_nas=$(systemctl show backup-nas.service --property=ExecMainStartTimestamp 2>/dev/null | \
  awk -F= '{print $2}')
if [[ -n "$last_nas" && "$last_nas" != "0" ]]; then
  last_ts=$(date -d "$last_nas" +%s 2>/dev/null || echo 0)
  age=$(( ($(date +%s) - last_ts) / 3600 ))
  if [[ $age -gt 26 ]]; then
    warn "backup-nas last ran ${age}h ago (expected ≤25h)"
  else
    ok "backup-nas last ran ${age}h ago"
  fi
else
  warn "backup-nas has not run yet since last boot"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Storage"
# Hot tier (NVMe mount)
nvme_use=$(df /mnt/nvme0n1p2 --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo 0)
if [[ -n "$nvme_use" ]]; then
  if [[ $nvme_use -ge 90 ]]; then
    fail "NVMe /mnt/nvme0n1p2 — ${nvme_use}% used"
  elif [[ $nvme_use -ge 80 ]]; then
    warn "NVMe /mnt/nvme0n1p2 — ${nvme_use}% used"
  else
    ok "NVMe /mnt/nvme0n1p2 — ${nvme_use}% used"
  fi
fi

# Cold tiers
for mount in /mnt/cold-8t /mnt/cold-sec; do
  if mountpoint -q "$mount" 2>/dev/null; then
    use=$(df "$mount" --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo 0)
    if [[ $use -ge 90 ]]; then
      fail "$mount — ${use}% used"
    elif [[ $use -ge 80 ]]; then
      warn "$mount — ${use}% used"
    else
      ok "$mount — ${use}% used"
    fi
  else
    fail "$mount — not mounted"
  fi
done

# eMMC (OS disk)
emmc_use=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo 0)
if [[ $emmc_use -ge 85 ]]; then
  warn "eMMC (OS) — ${emmc_use}% used"
else
  ok "eMMC (OS) — ${emmc_use}% used"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Vault"
VAULT_ADDR_REMOTE="http://192.168.1.128:8200"
vault_status=$(curl -sk --max-time 5 "${VAULT_ADDR_REMOTE}/v1/sys/health" 2>/dev/null)
if [[ -z "$vault_status" ]]; then
  fail "Vault (192.168.1.128) — unreachable"
else
  initialized=$(echo "$vault_status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('initialized','?'))" 2>/dev/null)
  sealed=$(echo "$vault_status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sealed','?'))" 2>/dev/null)
  if [[ "$sealed" == "False" ]]; then
    ok "Vault initialized=$initialized sealed=$sealed"
  elif [[ "$sealed" == "True" ]]; then
    fail "Vault is SEALED — run: ssh swares@192.168.1.128 vault operator unseal"
  else
    warn "Vault status unknown: $vault_status"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Ollama inference (opi5pro-1)"
ollama_svc=$(kubectl get svc ollama -n ai-gateway -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [[ -z "$ollama_svc" ]]; then
  fail "Ollama service not found in ai-gateway"
else
  ollama_resp=$(curl -s --max-time 5 "http://${ollama_svc}:11434/api/tags" 2>/dev/null)
  if [[ -z "$ollama_resp" ]]; then
    fail "Ollama — no response from ${ollama_svc}:11434"
  else
    models=$(echo "$ollama_resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
names = [m['name'] for m in d.get('models', [])]
print(', '.join(names) if names else 'no models loaded')
" 2>/dev/null || echo "parse error")
    ok "Ollama reachable — models: $models"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Loop device (LVM backing)"
if losetup /dev/loop100 &>/dev/null; then
  ok "/dev/loop100 attached"
else
  fail "/dev/loop100 not attached — k8s PVs may be broken"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
  echo -e "${GRN}  ✓ All checks passed${RST}"
elif [[ $ERRORS -eq 0 ]]; then
  echo -e "${YLW}  ⚠ ${WARNINGS} warning(s), no errors${RST}"
else
  echo -e "${RED}  ✗ ${ERRORS} error(s), ${WARNINGS} warning(s)${RST}"
fi
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

[[ $ERRORS -eq 0 ]]
