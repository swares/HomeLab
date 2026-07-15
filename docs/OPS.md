# Operations Playbook — Common Tasks

Step-by-step procedures for routine lab operations. All kubectl commands run from
H4 (`ssh swares@192.168.1.160`) or any host with a valid kubeconfig.

Jump to:
- [Cluster health check](#cluster-health-check)
- [Register self-hosted GitHub Actions runner](#register-self-hosted-github-actions-runner)
- [k3s upgrade](#k3s-upgrade)
- [OS package updates](#os-package-updates)
- [VM OS updates (sandbox pipeline)](#vm-os-updates-sandbox-pipeline)
- [Add a new workload](#add-a-new-workload)
- [Update a secret in Vault](#update-a-secret-in-vault)
- [Force an ArgoCD sync](#force-an-argocd-sync)
- [Debug a stuck pod](#debug-a-stuck-pod)
- [Vault unseal](#vault-unseal)
- [Bootstrap a new Linux node as k3s agent](#bootstrap-a-new-linux-node-as-k3s-agent)
- [Bootstrap a new Windows node](#bootstrap-a-new-windows-node)
- [Rotate Ansible Vault secrets](#rotate-ansible-vault-secrets)
- [Check backups](#check-backups)
- [Pi-hole update](#pi-hole-update)
- [Drain and reboot H4 (maintenance window)](#drain-and-reboot-h4-maintenance-window)

---

## Cluster health check

```bash
# Node status
kubectl get nodes -o wide

# All pods (flag anything not Running/Completed)
kubectl get pods -A | grep -Ev 'Running|Completed'

# ArgoCD app health
kubectl get applications -n argocd

# External secrets synced
kubectl get externalsecret -A

# Backup timers
systemctl status backup-nas.timer backup-etcd.timer

# Quick ping all hosts
bash ~/lab/homelab/homelab/scripts/lab-check.sh
```

---

## k3s upgrade

Renovate opens a PR bumping `k3s_version` in
`ansible/inventory/group_vars/all/k3s.yml` when a new release is tagged.
Never auto-merges — a drain cycle is required.

The cluster is **3-node HA** (odroid-nas + n150-1 + n150-2 as servers; opi5pro-1/2 as
agents). kube-vip VIP is `192.168.1.200`. Upgrade server nodes one at a time — etcd
quorum (2-of-3) stays intact while one node drains.

### 1. Review and merge the PR

Check the k3s release notes at `https://github.com/rancher/k3s/releases`, then merge
the Renovate PR on GitHub.

### 2. Verify the version in group_vars

```bash
grep k3s_version ~/lab/homelab/homelab/ansible/inventory/group_vars/all/k3s.yml
# e.g. k3s_version: "v1.36.2+k3s1"
```

### 3. Upgrade server nodes (one at a time)

```bash
cd ~/lab/homelab/homelab/ansible

# Upgrade odroid-nas (server)
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags k3s --limit h4-core --vault-password-file .vault_pass

# Verify before continuing
kubectl get nodes   # odroid-nas at new version, n150-1/n150-2 still old — that's fine

# Upgrade n150-1 (server)
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags k3s --limit n150-1 --vault-password-file .vault_pass

kubectl get nodes

# Upgrade n150-2 (server)
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags k3s --limit n150-2 --vault-password-file .vault_pass

kubectl get nodes   # all 3 servers at new version
```

### 4. Upgrade agents (opi5pro-1, opi5pro-2)

```bash
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags k3s --limit opi5pro-1 --vault-password-file .vault_pass

ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags k3s --limit opi5pro-2 --vault-password-file .vault_pass

kubectl get nodes   # all 5 nodes at new version
```

### If the installer fails with `Error: --server is required`

The env file was not written correctly. Fix directly on the agent node:

```bash
sudo tee /etc/systemd/system/k3s-agent.service.env <<EOF
K3S_URL=https://192.168.1.200:6443
K3S_TOKEN=<token-from-h4>
EOF
sudo systemctl daemon-reload && sudo systemctl restart k3s-agent
```

Note: agent nodes point at the kube-vip VIP (`192.168.1.200`), not a specific server.

---

## OS package updates

### All bare-metal Linux hosts

```bash
cd ~/lab/homelab/homelab/ansible
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --vault-password-file .vault_pass
```

### Specific tier

```bash
# opi5pro nodes only (drain/uncordon cycle)
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --tags k3s_agents --vault-password-file .vault_pass

# H4 only (flags reboot if needed — no auto-reboot)
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --tags k3s_server --vault-password-file .vault_pass

# Standalone hosts (rpi5, octopi, zero2w-2, xu3-1)
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --tags standalone --vault-password-file .vault_pass
```

If H4 is flagged as needing a reboot, see
[Drain and reboot H4](#drain-and-reboot-h4-maintenance-window).

---

## VM OS updates (sandbox pipeline)

KVM VMs (e.g. `gitlab-1`) are updated via a clone-test-promote pipeline that validates
updates in an isolated sandbox before touching production.

### Validate only (safe to run anytime)

```bash
cd ~/lab/homelab/homelab/ansible
ansible-playbook -i inventory/hosts.yml playbooks/sandbox-vm-update.yml \
  -e target_vm=gitlab-1 \
  --vault-password-file .vault_pass --ask-become-pass
```

What it does:
1. Suspends `gitlab-1` briefly, copies disk to standalone sandbox image, resumes
2. Patches sandbox netplan to DHCP, boots `gitlab-1-sandbox` on isolated NAT network
3. Runs `apt dist-upgrade` + reboot in sandbox
4. Checks HTTP health endpoint
5. Destroys sandbox VM and disk — production untouched

### Validate + promote (apply to production)

```bash
ansible-playbook -i inventory/hosts.yml playbooks/sandbox-vm-update.yml \
  -e "target_vm=gitlab-1 promote_on_pass=true" \
  --vault-password-file .vault_pass --ask-become-pass
```

If all checks pass, the pipeline compacts the updated sandbox disk, shuts `gitlab-1` down
briefly, swaps the disk, and restarts. Old disk saved as `gitlab-1-pre-YYYY-MM-DD.qcow2`.

### Add a new VM to the pipeline

Add inventory vars to the `standalone_vms` group in `ansible/inventory/hosts.yml`:
```yaml
standalone_vms:
  hosts:
    my-vm:
      kvm_host: n150-1
      libvirt_vm_name: my-vm
      health_check_url: http://192.168.1.XX:PORT
```

---

## Add a new workload

All cluster changes go through git — never `kubectl apply` directly.

### 1. Create the manifests

Create `gitops/workloads/<name>/` with Deployment, Service, Ingress, and Namespace manifests.
Copy an existing app yaml from `gitops/apps/` for the ArgoCD Application.

```bash
mkdir -p gitops/workloads/<name>
# Create deployment.yaml, service.yaml, ingress.yaml, namespace.yaml
```

Ingress template:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <name>
  namespace: <name>
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  rules:
    - host: <name>.apps.lab.home.arpa
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <name>
                port:
                  number: 80
```

StorageClass for PVCs is `local-path` (k3s built-in). Confirm with:
```bash
kubectl get sc
```

### 2. Create the ArgoCD Application

```bash
# Copy any existing app yaml from gitops/apps/ and edit: name, namespace, path
cp gitops/apps/lldap.yaml gitops/apps/<name>.yaml
# Edit: name, namespace, path (gitops/workloads/<name>)
```

### 3. Open a PR and merge

```bash
git checkout -b add-<name>
git add gitops/workloads/<name> gitops/apps/<name>.yaml
git commit -m "feat: add <name> workload"
git push origin add-<name>
# Open PR on GitHub → merge
```

ArgoCD reconciles within ~30 seconds of merge.

### 4. Verify

```bash
kubectl get pods -n <name>
argocd app get <name>    # or check the UI at https://argocd.apps.lab.home.arpa
```

---

## Update a secret in Vault

### Write the new value

```bash
export VAULT_ADDR=http://192.168.1.128:8200
# For a NEW secret path:
vault kv put secret/lab/<name> key=value key2=value2
# For an EXISTING path (use patch to avoid destroying other keys):
vault kv patch secret/lab/<name> key=value
```

### Force ExternalSecret to re-sync immediately

```bash
# Annotate to trigger a refresh (ArgoCD will revert the annotation — that's fine,
# the secret value was already pulled before the revert)
kubectl annotate externalsecret <name> -n <namespace> \
  force-sync=$(date +%s) --overwrite
```

Or wait up to 1 hour for the automatic refresh interval.

### Verify the secret updated

```bash
kubectl get secret <name> -n <namespace> -o jsonpath='{.data.<key>}' | base64 -d
```

---

## Force an ArgoCD sync

```bash
# Via CLI
argocd app sync <app-name>

# Via kubectl annotation (no argocd CLI needed)
kubectl annotate application <app-name> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Hard reset (discards any in-progress operation)
argocd app terminate-op <app-name>
argocd app sync <app-name> --force
```

Get the ArgoCD admin password:
```bash
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Debug a stuck pod

```bash
# See why the pod isn't running
kubectl describe pod <pod-name> -n <namespace>

# Common causes and checks:
#   ImagePullBackOff  → check image tag exists; check registry credentials
#   Pending           → check nodeSelector matches a real node label
#   CrashLoopBackOff  → check logs
#   OOMKilled         → increase resources.limits.memory

# Logs (current)
kubectl logs <pod-name> -n <namespace>

# Logs (previous crash)
kubectl logs <pod-name> -n <namespace> --previous

# Exec into a running pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Check node labels (important for nodeSelector issues)
kubectl get nodes --show-labels
# k3s node name is odroid-nas, not h4-core

# Delete a stuck pod (Deployment will recreate it)
kubectl delete pod <pod-name> -n <namespace>
```

---

## Vault unseal

Vault may start sealed after a reboot or service restart. Check:

```bash
export VAULT_ADDR=http://192.168.1.128:8200
vault status
```

If sealed (`Sealed: true`):

```bash
# SSH to rpi5
ssh swares@192.168.1.128
export VAULT_ADDR=http://127.0.0.1:8200

# Unseal (repeat for each key share required — default threshold is 3)
vault operator unseal
```

After unsealing, verify External Secrets synced:
```bash
kubectl get externalsecret -A
# STATUS should be SecretSynced, not SecretSyncError
```

---

## Bootstrap a new Linux node as k3s agent

### Prerequisites

- Ubuntu 22.04 (or compatible) installed
- SSH access as `swares`
- IP assigned and in DNS

### 1. Add to inventory

```yaml
# ansible/inventory/hosts.yml — under k3s_agents or standalone
<hostname>:
  ansible_host: 192.168.1.XXX
```

Also add to `standalone` group if it's not a k3s node.

### 2. Run bootstrap playbook

```bash
cd ~/lab/homelab/homelab/ansible
ansible-playbook -i inventory/hosts.yml playbooks/bootstrap.yml \
  --limit <hostname> --vault-password-file .vault_pass
```

### 3. Join as k3s agent

Get the token from H4:
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

On the new node:
```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=<current-version> \
  K3S_URL=https://192.168.1.200:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent
```

Verify from H4:
```bash
kubectl get nodes
```

### 4. Add DNS record

Add `<hostname> → 192.168.1.XXX` to Pi-hole's local DNS
(`http://192.168.1.148/admin` → Local DNS Records).

---

## Bootstrap a new Windows node

### 1. On the Windows machine, run as Administrator in PowerShell

```powershell
# Download and run the WinRM setup script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/swares/HomeLab/main/scripts/enable-winrm.ps1" -OutFile enable-winrm.ps1
.\enable-winrm.ps1

# Create the local ansible account
$pw = ConvertTo-SecureString "StrongPassword" -AsPlainText -Force
New-LocalUser -Name ansible -Password $pw -PasswordNeverExpires
Add-LocalGroupMember -Group Administrators -Member ansible

# Enable Basic auth (required for WinRM with local accounts)
Set-Item WSMan:\localhost\Service\Auth\Basic $true
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System `
  -Name LocalAccountTokenFilterPolicy -Value 1

# Disable sleep (for headless nodes)
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
```

### 2. Add to inventory

```yaml
# ansible/inventory/hosts.yml — under x86_nodes
<hostname>:
  ansible_host: 192.168.1.XXX
```

### 3. Run bootstrap playbook

```bash
ansible-playbook -i inventory/hosts.yml playbooks/windows-bootstrap.yml \
  --limit <hostname> --vault-password-file .vault_pass
```

### 4. Verify

```bash
ansible -i inventory/hosts.yml <hostname> \
  -m ansible.windows.win_ping --vault-password-file .vault_pass
```

---

## Rotate Ansible Vault secrets

### Add or update an encrypted value

```bash
cd ~/lab/homelab/homelab/ansible

# Encrypt a new value
printf 'the-new-secret' | ansible-vault encrypt_string \
  --vault-id default@.vault_pass \
  --stdin-name my_variable_name
```

Paste the output into the appropriate `group_vars/all/secrets.yml` or
`group_vars/<group>/secrets.yml`.

### Re-key the vault (change the vault password)

```bash
ansible-vault rekey --vault-password-file .vault_pass \
  inventory/group_vars/all/secrets.yml
```

### View an encrypted value

```bash
ansible -i inventory/hosts.yml localhost \
  -m debug -a "var=my_variable_name" \
  --vault-password-file .vault_pass
```

---

## Check backups

### restic snapshots

```bash
# On H4
export RESTIC_REPOSITORY=/mnt/cold-8t/restic
export RESTIC_PASSWORD_FILE=/etc/restic/password

restic snapshots          # list all snapshots
restic check              # verify repo integrity
```

### Backup timer status

```bash
systemctl status backup-nas.timer
systemctl status backup-etcd.timer

# When did it last run?
journalctl -u backup-nas.service --since "7 days ago" | tail -30
```

### Confirm last backup succeeded before any storage operation

```bash
restic snapshots --last
# Check the timestamp — should be within 24h for nas, within 7d for etcd
```

---

## Pi-hole update

Updates the Pi-hole application itself (not the OS). Secondary DNS first to preserve
resolution throughout.

```bash
cd ~/lab/homelab/homelab/ansible
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --tags pihole --vault-password-file .vault_pass
```

Verify after:
```bash
ansible -i inventory/hosts.yml dns -m command \
  -a "pihole version" --vault-password-file .vault_pass
```

---

## Register self-hosted GitHub Actions runner

Required so the weekly scheduled Ansible jobs (apt-upgrade, check-vault, update-pihole,
lab-health-check) can reach LAN hosts at `192.168.1.x`.

### 1. Get a registration token from GitHub

Go to: `https://github.com/swares/HomeLab/settings/actions/runners/new`
Select: Linux / x64. Copy the token shown (valid for 1 hour).

### 2. Run the Ansible playbook

```bash
cd ~/lab/homelab/homelab/ansible
ansible-playbook -i inventory/hosts.yml playbooks/github-runner.yml \
  -e runner_token=<token-from-github> --vault-password-file .vault_pass
```

### 3. Verify

Runner should appear at:
`https://github.com/swares/HomeLab/settings/actions/runners`

Status should be **Idle** (green). Trigger the scheduled workflow manually to confirm:
`https://github.com/swares/HomeLab/actions/workflows/scheduled-updates.yml`
→ Run workflow.

### Re-register after H4 reboot

The runner service starts automatically on boot (`svc.sh install` sets up systemd).
If it shows Offline, check:
```bash
sudo systemctl status "actions.runner.*"
sudo systemctl start "actions.runner.*"
```

---

## Drain and reboot H4 (maintenance window)

H4 is the k3s server and the NAS. A reboot briefly drops NAS services (smbd/nfs)
and requires that no workloads have H4 as their only scheduling option.

**Preferred — automated drain/reboot/uncordon via Ansible:**

```bash
cd ansible
# Dry-run first:
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --tags reboot_h4 --check --vault-password-file .vault_pass

# Real run (only proceeds if /var/run/reboot-required exists):
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --tags reboot_h4 --vault-password-file .vault_pass

# Force a reboot even without the flag:
ansible-playbook -i inventory/hosts.yml playbooks/update-hosts.yml \
  --tags reboot_h4 -e force_reboot=true --vault-password-file .vault_pass
```

The play: drains `odroid-nas` (ignoring DaemonSets, deleting emptyDir data, 120s
timeout) → reboots → waits up to 300s for the node to rejoin as Ready → uncordons.

**Manual procedure (fallback):**

### 1. Confirm backups are current

```bash
restic snapshots --last   # see Check backups above
```

### 2. Drain H4 from the cluster

```bash
kubectl drain odroid-nas \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=120s
```

### 3. Reboot

```bash
sudo reboot
```

### 4. Wait for SSH to come back, then uncordon

```bash
# From another host, or wait and re-SSH
kubectl uncordon odroid-nas
kubectl get nodes   # odroid-nas should be Ready and schedulable
```

### 5. Check NAS services came back

```bash
systemctl status smbd nfs-server
```

### 6. Verify cluster is healthy

```bash
kubectl get pods -A | grep -Ev 'Running|Completed'
kubectl get applications -n argocd
```
