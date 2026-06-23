# Convenience targets. All Ansible runs target the host(s) in inventory/hosts.yml.
.PHONY: help check storage microshift backup argocd all dns ai-nodes vault ldap mqtt k3s-vms \
        update-containers update-vms bake-image validate-rollout

help:        ## Show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t-/' | sort

check:       ## Dry-run every playbook (no changes)
	cd ansible && ansible-playbook playbooks/site.yml --check

storage:     ## Configure RAID + LVM storage tiers
	cd ansible && ansible-playbook playbooks/storage.yml

microshift:  ## Install + configure MicroShift
	cd ansible && ansible-playbook playbooks/microshift.yml

backup:      ## Install restic + etcd backup timers
	cd ansible && ansible-playbook playbooks/backup.yml

ai-nodes:    ## Install NPU/iGPU inference runtimes (RKLLama, OpenVINO)
	cd ansible && ansible-playbook playbooks/ai-nodes.yml

argocd:      ## Bootstrap Argo CD + app-of-apps
	cd ansible && ansible-playbook playbooks/argocd.yml

dns:         ## Configure Pi-hole/dnsmasq lab zone (primary + secondary)
	cd ansible && ansible-playbook playbooks/dns.yml

vault:       ## Install + configure Vault (RPi 5)
	cd ansible && ansible-playbook playbooks/vault.yml

ldap:        ## Install + configure OpenLDAP (RPi 4B)
	cd ansible && ansible-playbook playbooks/ldap.yml

mqtt:        ## Install Mosquitto broker (lab Zero 2W)
	cd ansible && ansible-playbook playbooks/mqtt.yml

k3s-vms:     ## Install k3s on the Proxmox VMs (run terraform/inventory-from-tofu.sh first)
	cd ansible && ansible-playbook -i inventory/tofu-vms.yml playbooks/k3s.yml

all:         ## Run the full site playbook
	cd ansible && ansible-playbook playbooks/site.yml

# ── Update workflows ──────────────────────────────────────────────────────────
update-containers: ## Validate container rollout health (run post-ArgoCD sync)
	bash scripts/validate-rollout.sh

update-vms:        ## Rolling OS patch for all Proxmox VMs (k3s drain-aware)
	cd ansible && ansible-playbook playbooks/update-vms.yml

update-vms-check:  ## Dry-run VM update (no changes)
	cd ansible && ansible-playbook playbooks/update-vms.yml --check

update-non-apt:    ## Update Pi-hole, k3s binary, and check Vault seal status
	cd ansible && ansible-playbook playbooks/update-non-apt.yml

update-pihole:     ## Update Pi-hole only (secondary then primary)
	cd ansible && ansible-playbook playbooks/update-non-apt.yml -t pihole

update-k3s:        ## Upgrade k3s binary to pinned version in group_vars/all/k3s.yml
	cd ansible && ansible-playbook playbooks/update-non-apt.yml -t k3s

check-vault:       ## Verify Vault seal status (safe to run anytime)
	cd ansible && ansible-playbook playbooks/update-non-apt.yml -t vault

bake-image:        ## Bake a fresh patched Ubuntu Noble Proxmox template via Packer
	cd packer && packer init . && packer build -var-file=proxmox.pkrvars.hcl ubuntu-noble.pkr.hcl
