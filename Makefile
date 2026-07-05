# Convenience targets. All Ansible runs target the host(s) in inventory/hosts.yml.
.PHONY: help check storage microshift backup argocd all dns ai-nodes vault ldap mqtt k3s-vms \
        k3s-registry update-containers update-vms bake-image validate-rollout ansible-deps bootstrap

# Use the venv if present, fall back to whatever is on PATH.
VENV          ?= /opt/ansible
ANSIBLE        = $(shell [ -x $(VENV)/bin/ansible-playbook ] && echo $(VENV)/bin/ansible-playbook || echo ansible-playbook)
ANSIBLE_GALAXY = $(shell [ -x $(VENV)/bin/ansible-galaxy ]    && echo $(VENV)/bin/ansible-galaxy    || echo ansible-galaxy)

help:        ## Show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t-/' | sort

ansible-deps: ## Install required Ansible Galaxy collections (run once after clone)
	$(ANSIBLE_GALAXY) collection install -r ansible/requirements.yml -p /opt/ansible/collections

bootstrap:   ## Push SSH key + grant passwordless sudo (run once per new host; needs -k/-K)
	cd ansible && $(ANSIBLE) playbooks/bootstrap.yml -k -K $(if $(LIMIT),-e target_hosts=$(LIMIT),)

check:       ## Dry-run every playbook (no changes)
	cd ansible && $(ANSIBLE) playbooks/site.yml --check

storage:     ## Configure RAID + LVM storage tiers
	cd ansible && $(ANSIBLE) playbooks/storage.yml

k3s-h4:      ## Install k3s server on the H4 (replaces MicroShift)
	cd ansible && $(ANSIBLE) playbooks/k3s-h4.yml

k3s-h4-uninstall: ## Remove k3s from the H4 (runs k3s-uninstall.sh on the host)
	ssh $(shell grep ansible_host ansible/inventory/hosts.yml | head -1 | awk '{print $$2}') sudo /usr/local/bin/k3s-uninstall.sh

microshift:  ## (legacy) Install + configure MicroShift — H4 now uses k3s, see k3s-h4
	cd ansible && $(ANSIBLE) playbooks/microshift.yml

backup:      ## Install restic + etcd backup timers
	cd ansible && $(ANSIBLE) playbooks/backup.yml

ai-nodes:    ## Install NPU/iGPU inference runtimes (RKLLama, OpenVINO, orchestrator)
	cd ansible && $(ANSIBLE) playbooks/ai-nodes.yml

k3s-registry: ## Configure k3s nodes + build agent to use lab registry (run after registry is up)
	cd ansible && $(ANSIBLE) playbooks/k3s-registry.yml

argocd:      ## Bootstrap Argo CD + app-of-apps
	cd ansible && $(ANSIBLE) playbooks/argocd.yml

dns:         ## Configure Pi-hole/dnsmasq lab zone (primary + secondary)
	cd ansible && $(ANSIBLE) playbooks/dns.yml

vault:       ## Install + configure Vault (RPi 5)
	cd ansible && $(ANSIBLE) playbooks/vault.yml

ldap:        ## Install + configure OpenLDAP (RPi 4B)
	cd ansible && $(ANSIBLE) playbooks/ldap.yml

mqtt:        ## Install Mosquitto broker (lab Zero 2W)
	cd ansible && $(ANSIBLE) playbooks/mqtt.yml

k3s-vms:     ## Install k3s on the Proxmox VMs (run terraform/inventory-from-tofu.sh first)
	cd ansible && $(ANSIBLE) -i inventory/tofu-vms.yml playbooks/k3s.yml

all:         ## Run the full site playbook
	cd ansible && $(ANSIBLE) playbooks/site.yml

# ── Update workflows ──────────────────────────────────────────────────────────
update-containers: ## Validate container rollout health (run post-ArgoCD sync)
	bash scripts/validate-rollout.sh

update-vms:        ## Rolling OS patch for all Proxmox VMs (k3s drain-aware)
	cd ansible && $(ANSIBLE) playbooks/update-vms.yml

update-vms-check:  ## Dry-run VM update (no changes)
	cd ansible && $(ANSIBLE) playbooks/update-vms.yml --check

update-non-apt:    ## Update Pi-hole, k3s binary, and check Vault seal status
	cd ansible && $(ANSIBLE) playbooks/update-non-apt.yml

update-pihole:     ## Update Pi-hole only (secondary then primary)
	cd ansible && $(ANSIBLE) playbooks/update-non-apt.yml -t pihole

update-k3s:        ## Upgrade k3s binary to pinned version in group_vars/all/k3s.yml
	cd ansible && $(ANSIBLE) playbooks/update-non-apt.yml -t k3s

check-vault:       ## Verify Vault seal status (safe to run anytime)
	cd ansible && $(ANSIBLE) playbooks/update-non-apt.yml -t vault

bake-image:        ## Bake a fresh patched Ubuntu Noble Proxmox template via Packer
	cd packer && packer init . && packer build -var-file=proxmox.pkrvars.hcl ubuntu-noble.pkr.hcl
