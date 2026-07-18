# Runbook

Operational procedures for the H4 core. Commands run from the repo root unless noted.
See [WORKFLOWS.md](WORKFLOWS.md) for common day-to-day patterns and secrets management.

## Initial install (lab from scratch)

### 1. Partition map (done at OS install)

Ansible does **not** repartition the live root disk. Layout:

| Device | Role | Mount |
|--------|------|-------|
| eMMC 256 GB | Host OS + etcd | `/` |
| NVMe 4 TB | Live NAS (`lv_nas`) + k8s PVs | `/srv/nas`, `/mnt/nvme0n1p2` |
| md1 8 TB (RAID 1) | Primary cold tier | `/mnt/cold-8t` |
| md0 ~5.45 TB (RAID 1) | Secondary cold copy | `/mnt/cold-sec` |

### 2. DNS records

Add to Pi-hole / dnsmasq on octopi (`192.168.1.148`):

| Record | Type | Value |
|--------|------|-------|
| `api.lab.home.arpa` | A | `192.168.1.200` | k3s API server (kube-vip VIP) |
| `*.apps.lab.home.arpa` | A | `192.168.1.160` |

CoreDNS handles `*.apps.lab.home.arpa` inside the cluster automatically via the
`coredns-custom` ConfigMap — no extra steps for new Ingresses.

### 3. Bootstrap secrets (before running playbooks)

    # Ansible Vault password
    echo '<password>' > ansible/.vault_pass && chmod 600 ansible/.vault_pass

    # Restic password
    sudo bash -c 'echo "<password>" > /etc/restic/password && chmod 700 /etc/restic/password'

### 4. Run the stages

    cd ansible
    ansible-playbook -i inventory/hosts.yml playbooks/storage.yml --vault-password-file .vault_pass
    ansible-playbook -i inventory/hosts.yml playbooks/k3s-h4.yml  --vault-password-file .vault_pass
    ansible-playbook -i inventory/hosts.yml playbooks/backup.yml  --vault-password-file .vault_pass
    ansible-playbook -i inventory/hosts.yml playbooks/argocd.yml  --vault-password-file .vault_pass

### 5. After Vault is up — sync secrets

    export VAULT_ADDR=http://192.168.1.128:8200
    vault login
    VAULT_TOKEN=$(vault print token) \
      ansible-playbook -i inventory/hosts.yml playbooks/sync-secrets-to-vault.yml \
      --vault-password-file .vault_pass

### 6. Populate ESO-managed secrets in Vault (before ArgoCD syncs workloads)

ExternalSecrets Operator pulls these paths. Populate them before the relevant ArgoCD app
syncs or the pods will stay pending on secret creation.

    export VAULT_ADDR=http://192.168.1.128:8200

    # Authelia — OIDC + session secrets (sync-secrets-to-vault.yml handles this)
    # vault kv put secret/lab/authelia \
    #   JWT_SECRET=<jwt> SESSION_SECRET=<session> \
    #   STORAGE_ENCRYPTION_KEY=<key> OIDC_HMAC_SECRET=<hmac>

    # lldap — admin password
    # vault kv put secret/lab/lldap LLDAP_LDAP_USER_PASS=<password>

    # m5stack adapter — API key + LiteLLM auth
    vault kv patch secret/lab/m5stack \
      api-key=<WEBHOOK_INJECT_API_KEY> \
      M5_USER=<user> M5_PASS=<pass>

    # Zot registry — htpasswd line (bcrypt)
    htpasswd_line=$(htpasswd -nbB admin '<password>')
    vault kv put secret/lab/registry htpasswd="$htpasswd_line"

    # Grafana admin
    # vault kv put secret/lab/grafana admin-password=<password>

After populating, ESO will sync within its refreshInterval (default 1h). Force immediate
refresh per secret with:

    kubectl annotate externalsecret <name> -n <namespace> \
      force-sync=$(date +%s) --overwrite

---

## Verify a healthy cluster

    kubectl get nodes                      # node Ready
    kubectl get pods -A                    # all Running/Completed
    kubectl get sc                         # local-path present
    kubectl get ingress -A                 # Ingresses listed
    kubectl get applications -n argocd    # all Synced/Healthy
    systemctl status backup-nas.timer backup-etcd.timer
    ssh swares@192.168.1.128 systemctl status backup-vault.timer   # rpi5
    # Note: lldap is now a k3s Deployment (ldap-1 VM decommissioned 2026-07-04).
    # The backup-lldap.timer on ldap-1 no longer exists. Back up lldap's SQLite PVC
    # via a k8s CronJob if needed — the PV is on local-path NVMe on whichever node
    # the lldap pod lands on.

---

## Deploy a workload

1. Create `gitops/workloads/<name>/` with Deployment, Service, Ingress, and Namespace manifests.
2. Add `gitops/apps/<name>.yaml` ArgoCD Application (copy any existing app yaml, change `name`/`path`/`namespace`).
3. Add `cert-manager.io/cluster-issuer: lab-ca` to the Ingress for automatic TLS.
4. Open PR → merge → ArgoCD syncs.

Never `kubectl apply` directly against main — it drifts and ArgoCD reverts it.

---

## Backups

| Stream | When | What | Downtime |
|--------|------|------|----------|
| `backup-nas` | daily 01:30 | restic of `/srv/nas` + `/mnt/cold-8t/VMs` + `/mnt/cold-8t/immich` → cold-8t, then `restic copy` → cold-sec + offsite | none |
| `backup-etcd` | daily | k3s SQLite state → `/mnt/cold-8t/k3s-etcd-snapshots/`, 7 copies retained | none |
| `backup-vault` | daily 02:30 | Vault raft snapshot → `/mnt/cold-8t/vault-snapshots/`, 30-day retention | none |
| `backup-lldap` | — | **ldap-1 VM decommissioned 2026-07-04.** lldap now runs as a k3s Deployment in the `lldap` namespace; SQLite data is on a `local-path` PVC. To back it up, add a k8s CronJob that copies the SQLite file from the PVC mount. | — |
| Immich DB dump | daily 01:30 | `pg_dump` via k8s CronJob → `/mnt/cold-8t/immich/backups/` (captured by restic above) | none |

Check:

    export VAULT_ADDR=http://192.168.1.128:8200
    export RESTIC_PASSWORD=$(vault kv get -field=password secret/lab/restic)
    export RESTIC_REPOSITORY=/mnt/cold-8t/restic
    restic snapshots
    journalctl -u backup-nas.service --no-pager | tail -30

**Never run `restic forget` or `restic prune` manually** — retention is managed by timers only.

---

## Vault operations

### Unseal after restart

    export VAULT_ADDR=http://192.168.1.128:8200
    vault operator unseal  # x3 with offline keys
    vault status

### Root token lost (Vault 2.x)

Vault 2.x requires unauthenticated access to be explicitly enabled for generate-root:

    # On rpi5:
    sudo bash -c 'echo "enable_unauthenticated_access = [\"generate-root\"]" >> /etc/vault.d/vault.hcl'
    sudo kill -s HUP $(pidof vault)

    vault operator generate-root -init          # note OTP and nonce
    vault operator generate-root -nonce=<nonce> # x3 with unseal keys
    vault operator generate-root -decode=<encoded> -otp=<otp>

    # Remove the config line and reload
    sudo sed -i '/enable_unauthenticated_access/d' /etc/vault.d/vault.hcl
    sudo kill -s HUP $(pidof vault)

### ESO token expired

    vault policy write eso - << 'POLICY'
    path "secret/data/lab/*" { capabilities = ["read"] }
    path "secret/metadata/lab/*" { capabilities = ["read", "list"] }
    POLICY
    vault token create -display-name=eso -period=87600h -policy=eso
    kubectl create secret generic vault-token -n external-secrets \
      --from-literal=token=<new-token> \
      --dry-run=client -o yaml | kubectl apply -f -
    vault kv put secret/lab/eso token=<new-token>

---

## Recovery scenarios

### Cluster workload gone wrong

    git revert <sha>
    git push
    # ArgoCD reconciles within minutes

For immediate relief before the revert lands:

    kubectl rollout undo deployment/<name> -n <namespace>

### Full cluster loss — etcd restore

    sudo systemctl stop k3s
    sudo k3s etcd-snapshot restore /mnt/cold-8t/etcd/<snapshot-name>
    sudo systemctl start k3s
    # ArgoCD re-syncs all workloads from git automatically

### NAS data loss — restic restore

    export VAULT_ADDR=http://192.168.1.128:8200
    export RESTIC_PASSWORD=$(vault kv get -field=password secret/lab/restic)
    export RESTIC_REPOSITORY=/mnt/cold-8t/restic
    restic restore latest --target /srv/nas

### UDMA CRC errors (SMART 199) — triage BEFORE replacing a disk

`UDMA_CRC_Error_Count` is a **link-layer** fault (cable / connector / SATA power /
controller), not the platters. Two disks erroring identically means a shared cause, not two
bad drives.

    smartctl -a /dev/sdX | grep -E "UDMA_CRC|Reallocated_Sector|Current_Pending|Offline_Uncorrectable"
    # 199 climbing  => active link problem. 5/197/198 all 0 => media is fine (link-only).

Fix order: (1) reseat/replace SATA **data** cables; (2) check SATA **power** (marginal
splitter is a classic cause); (3) move disks to **different SATA ports**; (4) update
**H4 BIOS**; (5) re-test. If 199 stops climbing after a cable+power+port swap, the disks
were never the problem.

### RAID 1 member dropped

The array is degraded, not lost — platter data is intact. After fixing the link:

    cat /proc/mdstat                       # see which member fell out
    mdadm --detail /dev/md1               # confirm state
    mdadm /dev/md1 --re-add /dev/sdX1    # re-add; resyncs automatically

Only if SMART 5/197/198 are non-zero (real media damage) do you replace the disk:
`mdadm --manage /dev/md1 --fail /dev/sdX1 --remove /dev/sdX1`, fit new disk, partition to
match, `--add`, let it rebuild.

### Burn-in a re-attached / replaced cold mirror

A re-attached array will assemble fine; the real question is whether the SATA link stays
clean **under sustained load** — CRC only shows up while pushing data.

1. Baseline 199 on both members:

        cat /proc/mdstat
        for d in sda sdb; do
          smartctl -a /dev/$d | grep -E "UDMA_CRC|Reallocated_Sector|Current_Pending|Offline_Uncorrectable"
        done

2. Confirm array is clean: `mdadm --detail /dev/md1` → State clean, both active sync,
   Failed Devices 0.

3. Full read scrub while watching the link (hours for 8 TB):

        # Terminal 1 — watch for link errors
        journalctl -k -f | grep -i 'ata\|sata\|hard resetting\|SError\|failed command'

        # Terminal 2 — run the scrub
        echo check > /sys/block/md1/md/sync_action
        watch -n5 cat /proc/mdstat

        # When done, check results
        cat /sys/block/md1/md/mismatch_cnt          # want 0
        for d in sda sdb; do smartctl -a /dev/$d | grep UDMA_CRC; done

4. Optional write stress (non-destructive to existing files):

        fio --name=burn --directory=/mnt/cold-8t --size=20G --rw=randrw \
            --bs=1M --numjobs=4 --time_based --runtime=1800 --group_reporting

5. Confirm monitoring is armed: `systemctl status mdmonitor smartd`

**Pass = all three:** 199 did not climb · no `ata`/`hard resetting` lines · `mismatch_cnt = 0`.

If `mismatch_cnt > 0`, run `echo repair > /sys/block/md1/md/sync_action`, then re-check.
Until it passes all three, keep backups landing on the secondary — don't promote on faith.

---

## Storage tiers

- **Primary — 8 TB (`md1`, 2×8 TB) → `/mnt/cold-8t`.** restic repo + etcd snapshots +
  Immich library. This is the trusted tier.
- **Secondary — ~5.45 TB (2×6 TB) → `/mnt/cold-sec`.** `restic copy` of the critical-but-small
  set (DB dumps, configs, irreplaceable originals).
- **Hot — NVMe 4 TB.** Live NAS (`lv_nas`) + k8s PVs (`local-path` StorageClass).

Because the secondary can't hold the entire multi-TB library, the bulk library's redundant
copy is the offsite restic + md1's own mirror. The secondary covers the small critical set.

### Migrate the ex-Synology secondary to a clean mirror

(One-time: the secondary disks came off an old Synology — ext4