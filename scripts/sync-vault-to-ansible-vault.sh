#!/usr/bin/env bash
# sync-vault-to-ansible-vault.sh
# Reads swares password from HashiCorp Vault, hashes it, updates Ansible Vault secrets.yml.
#
# Run after any password rotation:
#   export VAULT_ADDR=http://192.168.1.128:8200
#   vault login
#   bash scripts/sync-vault-to-ansible-vault.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/ansible"
SECRETS_FILE="$ANSIBLE_DIR/inventory/group_vars/all/secrets.yml"
VAULT_PASS_FILE="$ANSIBLE_DIR/.vault_pass"
VAULT_ADDR="${VAULT_ADDR:-http://192.168.1.128:8200}"

# ── preflight ──────────────────────────────────────────────────────────────────
if ! vault token lookup &>/dev/null; then
  echo "ERROR: not logged in to Vault. Run: vault login" >&2
  exit 1
fi

if [[ ! -f "$VAULT_PASS_FILE" ]]; then
  echo "ERROR: $VAULT_PASS_FILE not found." >&2
  exit 1
fi

if ! python3 -c "import passlib" 2>/dev/null; then
  echo "Installing passlib..."
  pip3 install passlib -q || apt-get install -y python3-passlib -q
fi

# ── fetch and hash ─────────────────────────────────────────────────────────────
echo "Fetching swares_password from Vault..."
PASSWORD=$(vault kv get -field=swares_password secret/lab/hosts)

echo "Hashing password..."
HASH=$(python3 -c "
from passlib.hash import sha512_crypt
import sys
print(sha512_crypt.using(rounds=5000).hash(sys.argv[1]))
" "$PASSWORD")

# ── encrypt with ansible-vault ─────────────────────────────────────────────────
echo "Encrypting hash with Ansible Vault..."
ENCRYPTED=$(printf '%s' "$HASH" | ansible-vault encrypt_string \
  --vault-password-file "$VAULT_PASS_FILE" \
  --encrypt-vault-id default \
  --stdin-name lab_user_password_hash 2>/dev/null)

# ── update secrets.yml ─────────────────────────────────────────────────────────
echo "Updating $SECRETS_FILE..."
python3 -c "
import re, sys

secrets_file = sys.argv[1]
encrypted = sys.argv[2]

with open(secrets_file, 'r') as f:
    content = f.read()

pattern = r'lab_user_password_hash:.*?(?=\n[^\s]|\Z)'
if re.search(pattern, content, flags=re.DOTALL):
    content = re.sub(pattern, encrypted, content, flags=re.DOTALL)
else:
    content = content.rstrip('\n') + '\n\n' + encrypted + '\n'

with open(secrets_file, 'w') as f:
    f.write(content)

print('Updated: ' + secrets_file)
" "$SECRETS_FILE" "$ENCRYPTED"

# ── verify ─────────────────────────────────────────────────────────────────────
echo "Verifying..."
ansible localhost -m debug -a "var=lab_user_password_hash" \
  -e "@$SECRETS_FILE" \
  --vault-password-file "$VAULT_PASS_FILE" 2>/dev/null \
  | grep -q "lab_user_password_hash" \
  && echo "✓ lab_user_password_hash verified in secrets.yml" \
  || echo "⚠ verification failed — check secrets.yml manually"

echo ""
echo "Done. Commit the updated secrets.yml:"
echo "  git add ansible/inventory/group_vars/all/secrets.yml"
echo "  git commit -m 'chore: rotate lab_user_password_hash'"
