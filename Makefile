ANSIBLE_DIR := ansible
TF_DIR      := terraform/dns
VAULT_ARGS  ?=

.PHONY: help ping check deploy lint tf-init tf-plan tf-apply

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

ping: ## Check SSH connectivity to all hosts
	cd $(ANSIBLE_DIR) && ansible all -m ping $(VAULT_ARGS)

check: ## Dry-run the full playbook (--check --diff)
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --check --diff $(VAULT_ARGS)

deploy: ## Apply the full playbook
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(VAULT_ARGS)

lint: ## Lint Ansible + Terraform
	cd $(ANSIBLE_DIR) && ansible-lint
	cd $(TF_DIR) && terraform fmt -check && terraform validate

tf-init: ## Initialise Terraform
	cd $(TF_DIR) && terraform init -input=false

tf-plan: tf-init ## Plan DNS changes
	cd $(TF_DIR) && terraform plan

tf-apply: tf-init ## Apply DNS changes
	cd $(TF_DIR) && terraform apply
