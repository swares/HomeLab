# Troubleshooting — Common Issues & Fixes

Operational runbook for issues that have come up more than once. Add new entries here.

---

## k3s Agent Upgrade Fails: `Error: --server is required`

**Symptom**
```
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.2+k3s1 sh -s - agent
level=fatal msg="Error: --server is required"
```

**Cause**  
The k3s installer for agent nodes requires `K3S_URL` and `K3S_TOKEN` at install time.
Running just `sh -s - agent` without them writes a broken service unit.

**Fix — run on the agent node**
```bash
# 1. Get the node token from H4 first
ssh swares@192.168.1.160 sudo cat /var/lib/rancher/k3s/server/node-token

# 2. On the agent node, run the installer with all required vars
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.36.2+k3s1 \
  K3S_URL=https://192.168.1.160:6443 \
  K3S_TOKEN=<token-from-step-1> \
  sh -s - agent

# 3. Verify
sudo systemctl status k3s-agent
kubectl get nodes   # from H4 — new node should show Ready
```

**If the service was partially installed** (broken env file):
```bash
# Check/repair the env file directly
cat /etc/systemd/system/k3s-agent.service.env

sudo tee /etc/systemd/system/k3s-agent.service.env <<EOF
K3S_URL=https://192.168.1.160:6443
K3S_TOKEN=<token>
EOF

sudo systemctl daemon-reload && sudo systemctl restart k3s-agent
```

**Affected nodes:** opi5pro-1 (`192.168.1.168`), opi5pro-2 (`192.168.1.172`)

---

## flannel-fdb Service Exits 255

**Symptom**  
`systemctl status flannel-fdb` shows exit-code 255; FDB entries missing after reboot.

**Cause**  
`bridge fdb add` fails with an error if the entry already exists (not idempotent).
Also: service may race against flannel.1 interface creation on boot.

**Fix** — use `bridge fdb replace` (idempotent) with a pre-start wait loop:
```ini
# /etc/systemd/system/flannel-fdb.service
[Service]
ExecStartPre=/bin/bash -c 'until ip link show flannel.1 &>/dev/null; do sleep 1; done'
ExecStart=/bin/bash -c 'bridge fdb replace <mac> dev flannel.1 dst <peer-ip> self permanent'
```

---

## WinRM "Path Does Not Exist" (NTLM WSMan Path Error)

**Symptom**  
Ansible WinRM connection fails with a path-not-found error when `ansible_winrm_transport: ntlm` is set explicitly.

**Cause**  
The explicit NTLM transport line conflicts with Negotiate. Negotiate handles NTLM automatically.

**Fix**  
Remove `ansible_winrm_transport: ntlm` from inventory/group_vars. Negotiate is the correct transport for local Windows accounts.

---

## WinRM Credentials Rejected (Microsoft Account)

**Symptom**  
WinRM authentication fails even though credentials are correct — Windows account is a Microsoft account (live.com email).

**Cause**  
NTLM/Negotiate does not work with Microsoft online accounts over WinRM. Only local accounts work.

**Fix**  
Create a dedicated local `ansible` account on each Windows node:
```powershell
$pw = ConvertTo-SecureString "StrongPassword" -AsPlainText -Force
New-LocalUser -Name ansible -Password $pw -PasswordNeverExpires
Add-LocalGroupMember -Group Administrators -Member ansible
```
Store the password in Ansible Vault (`windows_ansible_password` in `ansible/inventory/group_vars/all/secrets.yml`).

---

## `New-LocalUser` Fails: `-PasswordNeverExpires $true` Error

**Symptom**  
```
A parameter cannot be found that matches parameter name 'PasswordNeverExpires'.
```

**Cause**  
`-PasswordNeverExpires` is a switch parameter — it takes no value.

**Fix**
```powershell
# Wrong
New-LocalUser -Name ansible -Password $pw -PasswordNeverExpires $true

# Correct
New-LocalUser -Name ansible -Password $pw -PasswordNeverExpires
```

---

## Ansible Vault: Password with `!` Fails in Shell

**Symptom**  
Ansible fails with wrong password or shell expansion errors when the vault password or variable contains `!`.

**Cause**  
Bash history expansion interprets `!` in double-quoted strings.

**Fix**  
Use a vars file instead of passing the value inline:
```bash
cat > /tmp/winvars.yml <<'EOF'
my_var: "p@ss!word"
EOF
ansible-playbook playbook.yml -e @/tmp/winvars.yml
rm /tmp/winvars.yml
```

---

## Ansible Vault: Duplicate Key Warning

**Symptom**  
```
[WARNING]: Skipping unexpected key (windows_ansible_password) ...
```
or duplicate key in encrypted file.

**Cause**  
`<<<` (here-string) adds a trailing newline, which can result in a duplicate empty line being encrypted.

**Fix**  
Use `printf` instead of `echo` or `<<<`:
```bash
printf 'the-password' | ansible-vault encrypt_string --vault-id default@.vault_pass \
  --stdin-name windows_ansible_password
```

---

## Jinja2 Variables Render Literally in Inventory Files

**Symptom**  
`ansible_password: "{{ windows_ansible_password }}"` appears as a literal string instead of being interpolated.

**Cause**  
Jinja2 templating is not processed in `inventory/hosts.yml` host/group variable blocks.

**Fix**  
Move the variable reference to `group_vars`:
```
ansible/inventory/group_vars/x86_nodes/vars.yml
  ansible_password: "{{ windows_ansible_password }}"
```
The vault-encrypted value lives in `group_vars/all/secrets.yml`.

---

## k3s nodeSelector `h4-core` Not Found / Pods Pending

**Symptom**  
Pods stuck in `Pending`; `describe pod` shows no nodes match `kubernetes.io/hostname: h4-core`.

**Cause**  
The k3s node name is `odroid-nas`, not `h4-core`.

**Fix**  
```bash
kubectl get nodes --show-labels   # confirm actual hostname label
```
Update all `nodeSelector` blocks:
```yaml
nodeSelector:
  kubernetes.io/hostname: odroid-nas
```

---

## ArgoCD UI Redirect Loop (HTTP → HTTPS → loop)

**Symptom**  
Browser loops infinitely between HTTP and HTTPS when accessing ArgoCD through Traefik.

**Cause**  
ArgoCD's built-in TLS redirect conflicts with Traefik terminating TLS upstream.

**Fix**  
Set `server.insecure: "true"` in `argocd-cmd-params-cm` via GitOps
(`gitops/workloads/argocd/params-cm.yaml`). Do **not** patch this imperatively —
ArgoCD selfHeal will revert it.

---

## ArgoCD selfHeal Reverts Imperative Patches

**Symptom**  
`kubectl patch` or `kubectl annotate` changes are reverted within ~30s.

**Cause**  
ArgoCD `selfHeal: true` continuously reconciles cluster state to git. Any imperative
change that isn't in git gets reverted.

**Fix**  
Always make changes through git → PR → merge. The only exception is one-time secrets
(`kubectl create secret`) which are not tracked by ArgoCD.

---

## GitHub Actions: Scripts Not Executable

**Symptom**  
```
Permission denied: scripts/validate-rollout.sh
```

**Cause**  
Git didn't track the executable bit, or the file was created without `+x`.

**Fix (option A — fix the bit in git):**
```bash
git update-index --chmod=+x scripts/validate-rollout.sh
git commit -m "fix: mark script executable"
git push
```

**Fix (option B — call via bash in the workflow):**
```yaml
- run: bash scripts/validate-rollout.sh
```

---

## GitHub Actions: `ARGOCD_SERVER: unbound variable`

**Symptom**  
Workflow step fails with `ARGOCD_SERVER: unbound variable`.

**Cause**  
The script uses `set -u` and the secret was not wired into the workflow `env:` block.

**Fix**  
Add to the job or step:
```yaml
env:
  ARGOCD_SERVER: ${{ secrets.ARGOCD_SERVER }}
  ARGOCD_AUTH_TOKEN: ${{ secrets.ARGOCD_AUTH_TOKEN }}
```

---

## ArgoCD API Token: `accounts.admin does not have apiKey capability`

**Symptom**  
`argocd account generate-token` returns a capability error.

**Fix**
```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge \
  -p '{"data":{"accounts.admin":"apiKey,login"}}'
```

---

## external-secrets: `no kind is registered for version external-secrets.io/v1beta1`

**Symptom**  
ExternalSecret or ClusterSecretStore resources show `unknown kind` errors after an ESO upgrade.

**Cause**  
external-secrets operator v0.10+ removed the `v1beta1` API; all resources must use `v1`.

**Fix**  
Update `apiVersion` in all ESO manifests:
```yaml
# Before
apiVersion: external-secrets.io/v1beta1

# After
apiVersion: external-secrets.io/v1
```

Files to update: `gitops/workloads/immich/external-secret.yaml`,
`gitops/workloads/monitoring/external-secret.yaml`.
