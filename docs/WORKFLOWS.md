# Admin Workflows

Typical patterns for day-to-day management, adding capabilities, and recovery.

## Day-to-day: updates

Renovate opens PRs automatically when new container image tags or Helm chart versions are
detected. Review the diff, check the [Renovate dashboard](https://developer.mend.io/github/swares/HomeLab),
and merge. ArgoCD picks it up within minutes and rolls the workload.

For host-level packages (k3s, Pi-hole, Vault), the `update-non-apt.yml` playbook handles it:

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --vault-password-file .vault_pass --check   # dry run first
ansible-playbook -i inventory/hosts.yml playbooks/update-non-apt.yml \
  --vault-password-file .vault_pass           # then apply
```

Run the health check before and after any significant change:

```bash
bash scripts/lab-health-check.sh
```

**Secrets friction:** anything touching `authelia-secrets` or other manually-created k8s
secrets requires an out-of-band step — they are not in git. Update them with
`kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`.

---

## Adding new capabilities

### In-cluster workload

1. Branch off `main`.
2. Create `gitops/workloads/<name>/` with Deployment, Service, Ingress, PVC as needed.
3. Add `gitops/apps/<name>.yaml` — an ArgoCD Application pointing at the workload dir.
4. If the workload needs a secret, create it manually on the H4 and store the values in Vault:
```bash
   kubectl create secret generic <name>-secrets -n <namespace> \
     --from-literal=key=value
   vault kv put secret/lab/<name> key=value
```
5. Open a PR → merge → ArgoCD syncs → done.

**TLS** is automatic: add `cert-manager.io/cluster-issuer: lab-ca` to the Ingress and
cert-manager signs a cert from the lab root CA.

**In-cluster DNS** for `*.apps.lab.home.arpa` is handled automatically by the
`coredns-custom` ConfigMap — no manual DNS entries needed for new Ingresses.

**OIDC SSO** (for apps that support it): add a client block to Authelia's ConfigMap in
`gitops/workloads/authelia/configmap.yaml`, generate a hashed secret, and update the
`authelia-secrets` k8s Secret with the plaintext value. See the Authelia workload README
for the exact steps.

### Host-level addition (new VM, new Ansible role)

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/<new-playbook>.yml \
  --vault-password-file .vault_pass --check
ansible-playbook -i inventory/hosts.yml playbooks/<new-playbook>.yml \
  --vault-password-file .vault_pass
```

New VMs on n150-1/n150-2 are provisioned with `virt-install` + cloud-init, then handed
to Ansible. Add them to `ansible/inventory/hosts.yml` before running playbooks.

---

## Rollback and recovery

### Cluster workload gone wrong

`git revert` the offending commit and push — ArgoCD reconciles back within minutes.

For immediate relief before the revert merges:
```bash
kubectl rollout undo deployment/<name> -n <namespace>
```
ArgoCD will re-apply git state on next sync, so the revert **must** land in git promptly
or the imperative undo gets overwritten.

### Secrets corrupted or lost

Restore from Vault (`secret/lab/*`). If Vault itself needs recovery:

1. The raft data directory is `/opt/vault/data` on rpi5.
2. Restore it to a fresh Vault install, start the service, and unseal with the offline keys.
3. All stored secrets are in raft — no separate backup needed beyond the data directory.

Vault unseal keys and root token are stored offline. Keep them there.

### Full cluster loss (H4 dies)

k3s state is in etcd, snapshotted to `/mnt/cold-8t/etcd/` weekly.

```bash
# On a fresh H4 with k3s reinstalled:
systemctl stop k3s
k3s etcd-snapshot restore /mnt/cold-8t/etcd/<snapshot>
systemctl start k3s
# ArgoCD re-syncs all workloads from git automatically
```

Immich data survives independently: Postgres nightly dumps land on `/mnt/cold-8t/immich/`
and the photo library lives on the cold tier directly. Restore Postgres from the dump after
k3s is back.

### NAS data loss

The cold tier is the copy-of-record. Two mdadm RAID 1 mirrors plus nightly restic to
offsite. Restore with:

```bash
export VAULT_ADDR=http://192.168.1.128:8200
vault kv get -field=restic_password secret/lab/restic  # get credentials
restic -r <repo> restore latest --target /mnt/cold-8t
```

**Never run `restic forget` or `restic prune` manually** — retention is managed exclusively
by the `backup-nas` and `backup-etcd` timers.

### RAID degraded (one disk lost)

```bash
cat /proc/mdstat                          # confirm which array and which disk
mdadm --detail /dev/md1                   # identify the failed member
# replace disk, then:
mdadm /dev/md1 --add /dev/sdX            # rejoin new disk; rebuild starts automatically
watch cat /proc/mdstat                    # monitor rebuild
```

Do not make storage changes until the rebuild completes and both mirrors show `[UU]`.

---

## Key risk: single failure domain

The H4 carries the cluster, NAS, and local backups in one box. Mitigations:

- **Offsite restic copy** (`backup-offsite.timer`) — nightly; the only true off-box data copy.
- **Git** — off-box copy of all cluster configuration; ArgoCD can rebuild from scratch.
- **Two cold-tier mirrors** — survive a single disk failure each.
- **Vault on rpi5** — secrets survive an H4 failure.

Before any hot-tier storage change, confirm the last backup succeeded:
```bash
systemctl status backup-nas.timer
journalctl -u backup-nas.service --no-pager | tail -20
```
