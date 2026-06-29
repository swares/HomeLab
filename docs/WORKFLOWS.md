# Admin Workflows

Typical patterns for day-to-day management, adding capabilities, recovery, and secrets.

---

## Day-to-day: updates

Renovate opens PRs automatically when new container image tags or Helm chart versions are
detected. Review the diff, check the [Renovate dashboard](https://developer.mend.io/github/swares/HomeLab),
and merge. ArgoCD picks it up within minutes and rolls the workload.

For host-level packages (k3s, Pi-hole, Vault), the `update-non-apt.yml` playbook handles it:

    cd ansible
    ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
      --vault-password-file .vault_pass --check   # dry run first
    ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
      --vault-password-file .vault_pass

Run the health check before and after any significant change:

    bash scripts/lab-check.sh

**Secrets friction:** anything touching `authelia-secrets` or other manually-created k8s
secrets requires an out-of-band step — they are not in git. Update them with
`kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`, then run
`sync-secrets-to-vault.yml` to keep Vault current.

---

## Adding new capabilities

### In-cluster workload

1. Branch off `main`.
2. Create `gitops/workloads/<name>/` with Deployment, Service, Ingress, PVC as needed.
3. Add `gitops/apps/<name>.yaml` — an ArgoCD Application pointing at the workload dir.
4. If the workload needs a secret, create it manually on the H4 and store values in Vault:

        kubectl create secret generic <name>-secrets -n <namespace> \
          --from-literal=key=value
        vault kv put secret/lab/<name> key=value

5. Open a PR → merge → ArgoCD syncs → done.

**TLS** is automatic: add `cert-manager.io/cluster-issuer: lab-ca` to the Ingress and
cert-manager signs a cert from the lab root CA.

**In-cluster DNS** for `*.apps.lab.home.arpa` is handled automatically by the
`coredns-custom` ConfigMap — no manual DNS entries needed for new Ingresses.

**OIDC SSO** (for apps that support it): add a client block to Authelia's ConfigMap in
`gitops/workloads/authelia/configmap.yaml`, generate a hashed secret, and update the
`authelia-secrets` k8s Secret. See the Authelia workload for the pattern.

### Host-level addition (new VM, new Ansible role)

    cd ansible
    ansible-playbook -i inventory/hosts.yml playbooks/<new-playbook>.yml \
      --vault-password-file .vault_pass --check
    ansible-playbook -i inventory/hosts.yml playbooks/<new-playbook>.yml \
      --vault-password-file .vault_pass

---

## Secrets management

### Store of record

**HashiCorp Vault** (`http://192.168.1.128:8200`) is the authoritative secrets store.
All lab credentials live under `secret/lab/*`:

| Path | Contents |
|------|----------|
| `secret/lab/hosts` | `swares_password` (plaintext) |
| `secret/lab/immich` | `DB_PASSWORD` |
| `secret/lab/grafana` | `admin_password` |
| `secret/lab/authelia` | all Authelia secrets |
| `secret/lab/lldap` | `admin_password`, `jwt_secret` |
| `secret/lab/restic` | `password` |
| `secret/lab/argocd` | `admin_password` |
| `secret/lab/argocd-deploy-key` | `private_key`, `public_key` |
| `secret/lab/lab-ca` | `cert`, `key` |
| `secret/lab/eso` | ESO Vault token |

### Three-direction sync loop

    Runtime sources ──► HashiCorp Vault ──► Ansible Vault (bootstrap hash)
    (k8s secrets,           ▲                     │
     host files,            │                     ▼
     lldap config)   ESO pulls to k8s      rotate-passwords.yml
                      Secrets at runtime         fallback

**Runtime → HashiCorp Vault** (run after any credential rotation):

    export VAULT_ADDR=http://192.168.1.128:8200
    VAULT_TOKEN=$(vault print token) \
      ansible-playbook -i inventory/hosts.yml playbooks/sync-secrets-to-vault.yml \
      --vault-password-file .vault_pass

**HashiCorp Vault → Ansible Vault** (keeps bootstrap hash current):

    export VAULT_ADDR=http://192.168.1.128:8200
    vault login
    bash scripts/sync-vault-to-ansible-vault.sh
    git add ansible/inventory/group_vars/all/secrets.yml
    git commit -m 'chore: rotate lab_user_password_hash'

**HashiCorp Vault → k8s Secrets** — automatic via ESO; no manual step needed.

### Bootstrap credentials (must be safeguarded outside Vault)

These must exist **before** Vault can be used and cannot be stored inside it:

| Credential | Where stored | Why |
|------------|-------------|-----|
| Vault unseal keys (3-of-5) | Offline, physically secure | Required to unseal Vault after restart |
| Vault root token | Offline, alongside unseal keys | Required to generate new tokens |
| Ansible Vault password (`.vault_pass`) | On H4, gitignored | Gates all Ansible Vault encrypted secrets |

If the unseal keys are lost and Vault data is corrupted, all credentials must be manually reset.

### Password rotation procedure

    # 1. Update the plaintext in Vault
    vault kv patch secret/lab/hosts swares_password=<new-password>

    # 2. Sync to Ansible Vault bootstrap hash
    bash scripts/sync-vault-to-ansible-vault.sh

    # 3. Rotate on all hosts
    VAULT_TOKEN=$(vault print token) \
      ansible-playbook -i inventory/hosts.yml playbooks/rotate-passwords.yml \
      --vault-password-file .vault_pass

    # 4. Commit updated hash
    git add ansible/inventory/group_vars/all/secrets.yml
    git commit -m 'chore: rotate lab_user_password_hash'

---

## Rollback and recovery

### Cluster workload gone wrong

`git revert` the offending commit and push — ArgoCD reconciles back within minutes.

For immediate relief before the revert merges:

    kubectl rollout undo deployment/<name> -n <namespace>

ArgoCD will re-apply git state on next sync, so the revert **must** land in git promptly.

### Vault recovery

Vault is on rpi5 (`192.168.1.128`); raft data is at `/opt/vault/data`.

**If sealed after restart** — unseal with 3 keys:

    export VAULT_ADDR=http://192.168.1.128:8200
    vault operator unseal  # x3

**If root token lost** — generate new one (requires 3 unseal keys).
Vault 2.x requires a config change to allow unauthenticated generate-root:

    # On rpi5:
    sudo bash -c 'echo "enable_unauthenticated_access = [\"generate-root\"]" >> /etc/vault.d/vault.hcl'
    sudo kill -s HUP $(pidof vault)

    vault operator generate-root -init          # note OTP and nonce
    vault operator generate-root -nonce=<nonce> # x3 with unseal keys
    vault operator generate-root -decode=<encoded> -otp=<otp>

    # Remove the config line and reload
    sudo sed -i '/enable_unauthenticated_access/d' /etc/vault.d/vault.hcl
    sudo kill -s HUP $(pidof vault)

**If ESO token expired/revoked:**

    vault policy write eso - << 'POLICY'
    path "secret/data/lab/*" { capabilities = ["read"] }
    path "secret/metadata/lab/*" { capabilities = ["read", "list"] }
    POLICY
    vault token create -display-name=eso -period=87600h -policy=eso
    kubectl create secret generic vault-token -n external-secrets \
      --from-literal=token=<new-token> \
      --dry-run=client -o yaml | kubectl apply -f -
    vault kv put secret/lab/eso token=<new-token>

### Full cluster loss (H4 dies)

k3s state is in etcd, snapshotted to `/mnt/cold-8t/etcd/` weekly.

    # On a fresh H4 with k3s reinstalled:
    systemctl stop k3s
    k3s etcd-snapshot restore /mnt/cold-8t/etcd/<snapshot>
    systemctl start k3s
    # ArgoCD re-syncs all workloads from git automatically

Immich data survives independently: Postgres nightly dumps on `/mnt/cold-8t/immich/`
and the photo library lives on the cold tier directly.

### NAS data loss

    export VAULT_ADDR=http://192.168.1.128:8200
    RESTIC_PASSWORD=$(vault kv get -field=password secret/lab/restic)
    restic -r <repo> restore latest --target /mnt/cold-8t

**Never run `restic forget` or `restic prune` manually** — retention is managed by timers only.

### RAID degraded (one disk lost)

    cat /proc/mdstat
    mdadm --detail /dev/md1
    mdadm /dev/md1 --add /dev/sdX   # rejoin new disk; rebuild starts automatically
    watch cat /proc/mdstat           # monitor rebuild

Do not make storage changes until both mirrors show `[UU]`.

---

## Key risk: single failure domain

The H4 carries the cluster, NAS, and local backups in one box. Mitigations:

- **Offsite restic copy** (`backup-offsite.timer`) — nightly; only true off-box data copy.
- **Git** — off-box copy of all cluster configuration.
- **Two cold-tier mirrors** — survive a single disk failure each.
- **Vault on rpi5** — secrets survive an H4 failure.
- **Ansible Vault hash in git** — bootstrap credential survives everything.

Before any hot-tier storage change, confirm the last backup succeeded:

    systemctl status backup-nas.timer
    journalctl -u backup-nas.service --no-pager | tail -20
