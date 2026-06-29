# Runbook

Operational procedures for the H4 core. Commands run from the repo root unless noted.
See [WORKFLOWS.md](WORKFLOWS.md) for common day-to-day patterns and secrets management.

## Initial install (lab from scratch)

### 1. Partition map (done at OS install)

Ansible does **not** repartition the live root disk. Layout:

| Device | Role | Mount |
|--------|------|-------|
| eMMC 256 GB | Host OS + etcd | `/` |
| NVMe 4 TB | Live NAS (`lv_nas`) + k8s PVs (`local-path`) | `/srv/nas`, `/mnt/nvme0n1p2` |
| md1 8 TB (RAID 1) | Primary cold tier | `/mnt/cold-8t` |
| md0 ~5.45 TB (RAID 1) | Secondary cold copy | `/mnt/cold-sec` |

### 2. DNS records

Add to Pi-hole / dnsmasq on octopi (192.168.1.148):

| Record | Type | Value |
|--------|------|-------|
| `api.lab.home.arpa` | A | `192.168.1.160` |
| `*.apps.lab.home.arpa` | A | `192.168.1.160` |

CoreDNS handles `*.apps.lab.home.arpa` resolution from inside the cluster automatically
via the `coredns-custom` ConfigMap — no extra steps needed for new Ingresses.

### 3. Bootstrap secrets (before running playbooks)

```bash
# Ansible Vault password
echo '<password>' > ansible/.vault_pass && chmod 600 ansible/.vault_pass

# Restic password
sudo bash -c 'echo "<password>" > /etc/restic/password && chmod 700 /etc/restic/password'
```

### 4. Run the stages

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/storage.yml --vault-password-file .vault_pass
ansible-playbook -i inventory/hosts.yml playbooks/k3s-h4.yml  --vault-password-file .vault_pass
ansible-playbook -i inventory/hosts.yml playbooks/backup.yml  --vault-password-file .vault_pass
ansible-playbook -i inventory/hosts.yml playbooks/argocd.yml  --vault-password-file .vault_pass
```

### 5. After Vault is up — sync secrets

```bash
export VAULT_ADDR=http://192.168.1.128:8200
vault login
VAULT_TOKEN=$(vault print token) \
  ansible-playbook -i inventory/hosts.yml playbooks/sync-secrets-to-vault.yml \
  --vault-password-file .vault_pass
```

---

## Verify a healthy cluster

```bash
kubectl get nodes                      # node Ready
kubectl get pods -A                    # all Running/Completed
kubectl get sc                         # local-path present
kubectl get ingress -A                 # Ingresses resolve to *.apps.lab.home.arpa
kubectl get applications -n argocd    # all Synced/Healthy
systemctl status backup-nas.timer backup-etcd.timer
```

---

## Deploy a workload

1. Copy `gitops/workloads/sample-app/` to `gitops/workloads/<name>/` and edit manifests.
2. Add `gitops/apps/<name>.yaml` (copy `sample-app.yaml`, change `name`/`path`/`namespace`).
3. Add `cert-manager.io/cluster-issuer: lab-ca` annotation to the Ingress for TLS.
4. Open PR → merge → ArgoCD syncs.

---

## Vault operations

### Unseal after restart

```bash
export VAULT_ADDR=http://192.168.1.128:8200
vault operator unseal  # x3 with offline keys
vault status
```

### Root token lost (Vault 2.x)

```bash
# Temporarily allow unauthenticated generate-root
sudo bash -c 'echo "enable_unauthenticated_access = [\"generate-root\"]" >> /etc/vault.d/vault.hcl'
sudo kill -s HUP $(pidof vault)

vault operator generate-root -init          # note OTP and nonce
vault operator generate-root -nonce=<nonce> # x3 with unseal keys
vault operator generate-root -decode=<encoded> -otp=<otp>

# Remove the config line and reload
sudo sed -i '/enable_unauthenticated_access/d' /etc/vault.d/vault.hcl
sudo kill -s HUP $(pidof vault)
```

### ESO token expired

```bash
vault policy write eso - << 'POLICY'
path "secret/data/lab/*" { capabilities = ["read"] }
path "secret/metadata/lab/*" { capabilities = ["read", "list"] }
POLICY
vault token create -display-name=eso -period=87600h -policy=eso
kubectl create secret generic vault-token -n external-secrets \
  --from-literal=token=<new-token> --dry-run=client -o yaml | kubectl apply -f -
vault kv put secret/lab/eso token=<new-token>
```

---

## Storage operations

### Check array health

```bash
cat /proc/mdstat
mdadm --detail /dev/md1    # primary 8TB
mdadm --detail /dev/md0    # secondary ~5.45TB
```

### RAID degraded — replace disk

```bash
mdadm --detail /dev/md1                  # identify failed member
mdadm /dev/md1 --add /dev/sdX           # add replacement; rebuild starts
watch cat /proc/mdstat                   # monitor — wait for [UU]
```

Do not make storage changes until both mirrors show `[UU]`.

### Check restic backups

```bash
export VAULT_ADDR=http://192.168.1.128:8200
export RESTIC_PASSWORD=$(vault kv get -field=password secret/lab/restic)
export RESTIC_REPOSITORY=/mnt/cold-8t/restic

restic snapshots                         # list snapshots
restic check                             # verify integrity
journalctl -u backup-nas.service --no-pager | tail -30
```

**Never run `restic forget` or `restic prune` manually** — retention is handled by timers only.

### Restore NAS data from restic

```bash
export RESTIC_PASSWORD=$(vault kv get -field=password secret/lab/restic)
export RESTIC_REPOSITORY=/mnt/cold-8t/restic
restic restore latest --target /mnt/cold-8t
```

---

## k3s operations

### Restart k3s

```bash
sudo systemctl restart k3s
kubectl get nodes    # wait for Ready
```

### etcd snapshot restore

```bash
sudo systemctl stop k3s
sudo k3s etcd-snapshot restore /mnt/cold-8t/etcd/<snapshot-name>
sudo systemctl start k3s
```

### Force ArgoCD resync

```bash
kubectl annotate application <app> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Restart a deployment after ConfigMap change

```bash
kubectl rollout restart deployment/<name> -n <namespace>
kubectl rollout status deployment/<name> -n <namespace>
```

---

## DNS records reference

| Record | Type | Value | Notes |
|--------|------|-------|-------|
| `api.lab.home.arpa` | A | `192.168.1.160` | k3s API server |
| `*.apps.lab.home.arpa` | A | `192.168.1.160` | All Ingresses |
| `authelia.apps.lab.home.arpa` | — | (wildcard) | OIDC provider |
| `immich.apps.lab.home.arpa` | — | (wildcard) | Photo library |
| `argocd.apps.lab.home.arpa` | — | (wildcard) | GitOps UI |
| `grafana.apps.lab.home.arpa` | — | (wildcard) | Metrics UI |

---

## Disaster recovery — priority order

1. **Verify cold tier integrity** — `cat /proc/mdstat`; if degraded, replace disk first.
2. **Restore Vault** — unseal on rpi5; all other secrets flow from here.
3. **Restore k3s** — etcd snapshot restore; ArgoCD re-syncs workloads from git.
4. **Restore Immich Postgres** — from nightly dump on `/mnt/cold-8t/immich/`.
5. **Restore NAS data** — restic restore from `/mnt/cold-8t/restic` or offsite.
