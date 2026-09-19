ANSIBLE_DIR := ansible
TF_DIR      := terraform/dns
VAULT_ARGS  ?=

.PHONY: help hooks ping check deploy lint tf-init tf-plan tf-apply

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

hooks: ## Install the pre-commit hooks (gitleaks, linters, public-IP check)
	@command -v pre-commit >/dev/null || { \
		echo "pre-commit is not installed — the hooks in .pre-commit-config.yaml"; \
		echo "(gitleaks, terraform_fmt, ansible-lint, detect-private-key, the"; \
		echo "public-IP check) do NOT run without it. Install with:"; \
		echo "    brew install pre-commit"; \
		exit 1; }
	pre-commit install
	@echo "bypass a single commit with --no-verify"

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
