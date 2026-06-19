# Convenience targets. All Ansible runs target the host(s) in inventory/hosts.yml.
.PHONY: help check storage microshift backup argocd all dns ai-nodes vault ldap mqtt k3s-vms

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
