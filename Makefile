# Internal variables.
SHELL := /bin/bash

# COLORS
NOCOLOR=\033[0m
NC=${NOCOLOR}
RED=\033[0;31m
GREEN=\033[0;32m
ORANGE=\033[0;33m
BLUE=\033[0;34m
PURPLE=\033[0;35m
CYAN=\033[0;36m
LIGHTGRAY=\033[0;37m
DARKGRAY=\033[1;30m
LIGHTRED=\033[1;31m
LIGHTGREEN=\033[1;32m
YELLOW=\033[1;33m
LIGHTBLUE=\033[1;34m
LIGHTPURPLE=\033[1;35m
LIGHTCYAN=\033[1;36m
WHITE=\033[1;37m

.ONESHELL:
.SHELLFLAGS := -euc -o pipefail
.DELETE_ON_ERROR:
MAKEFLAGS += --silent
MAKEFLAGS += --no-print-directory
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

.PHONY: help info landingzones login logout destroy _destroy purge purge._start purge.diagnostic-settings purge.log-profiles purge.ad-users purge.ad-groups purge.ad-apps purge.keyvaults purge.resource-groups purge.role-assignments purge.custom-role-definitions

help:
	@echo "Please use 'make [<arg1=a> <argN=...>] <target>' where <target> is one of"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z\._-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

info: ## Information about ENVIRONMENT variables and how to use them.
	@echo "Please use '<env> <env> make [<arg1=a> <argN=...>] <target>' where <env> is one of"
	@awk  'BEGIN { FS = "\\s?(\\?=|:=).*###"} /^[a-zA-Z\._-]+.*?###.* / {printf "\033[33m%-28s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

PARALLELISM?='30'### Limit the number of concurrent operation as Terraform walks the graph. Defaults to 30.
RANDOM_LENGTH?='5'### Random string length for azure resource naming. Defaults to 5

_TFVARS_PATH:="$(shell pwd)/.github/tests/config"
TFVARS_PATH?=$(_TFVARS_PATH)
_BASE_DIR:=$(shell dirname $(TFVARS_PATH))

LANDINGZONES_DIR?="$(_BASE_DIR)/landingzones"### Landingzone directory checkout dir. Defaults to 'landingzones/'

ENVIRONMENT := $(shell echo $(ENVIRONMENT) | tr '[:upper:]' '[:lower:]')### Environment name to deploy to.

_PREFIX:=g$(GITHUB_RUN_ID)
PREFIX?=$(_PREFIX)
PREFIX?=$(shell echo $(PREFIX)|tr '[:upper:]' '[:lower:]')### Prefix azure resource naming.

_PURGE:="false"
PURGE?=$(_PURGE)

_TF_VAR_workspace:=tfstate
TF_VAR_workspace?=$(_TF_VAR_workspace)### Terraform workspace. Defaults to `tfstate`.

TF_VAR_tfstate_subscription_id:=$(ARM_SUBSCRIPTION_ID)

landingzones: ## Install caf-terraform-landingzones
	@echo -e "${LIGHTGRAY}TFVARS_PATH:		$(TFVARS_PATH)${NC}"
	@echo -e "${LIGHTGRAY}LANDINGZONES_DIR:	$(LANDINGZONES_DIR)${NC}"
	if [ ! -d \"$(LANDINGZONES_DIR)\" ]; then \
		echo -e "${GREEN}Installing landingzones (version : $(TF_LZ_BRANCH))${NC}"; \
		git clone --branch $(TF_LZ_BRANCH) $(TF_LZ_GIT) $(LANDINGZONES_DIR); \
		echo -e "${GREEN}Creating symlink for .devcontainer.$$(cd /tf/caf/ && ln -s $(LANDINGZONES_DIR)/.devcontainer .devcontainer)${NC}" ;\
	fi
	echo -e "${GREEN}Landingzones installed (version: $$(cd $(LANDINGZONES_DIR) && git branch --show-current))${NC}"
	echo -e "${CYAN}#### ROVER IMAGE VERSION REQUIRED FOR LANDINGZONES: $$(cat $(LANDINGZONES_DIR)/.devcontainer/docker-compose.yml | yq .services.rover.image) ####${NC}"

login: ## Login to azure using a service principal
	@echo -e "${GREEN}Azure login using service principal${NC}"
	az login --service-principal --allow-no-subscriptions -u ${ARM_CLIENT_ID} -p ${ARM_CLIENT_SECRET} --tenant ${ARM_TENANT_ID};
	if [ ! -z "$${ARM_SUBSCRIPTION_ID}" ]; then \
		echo -e "${LIGHTGREEN}Subscription set!${NC}";
		az account set --subscription $$ARM_SUBSCRIPTION_ID; \
	else \
		echo -e "${RED}No subscription set!${NC}"; exit 1;
	fi
	@echo -e "${GREEN}Logged in to $$(az account show --query 'name')${NC}"; \

logout: ## Logout service principal
	@echo -e "${GREEN}Logout service principal${NC}"
	az logout || true
	# Cleaup any service principal session
	unset ARM_TENANT_ID
	unset ARM_SUBSCRIPTION_ID
	unset ARM_CLIENT_ID
	unset ARM_CLIENT_SECRET

	@echo -e "${GREEN}Azure session closed${NC}"

_destroy: _ADD_ON = "caf_solution/"
_destroy: _TFSTATE = $(shell basename $(_SOLUTION))
_destroy: _VAR_FOLDERS= $(shell find $(TFVARS_PATH)/level$(_LEVEL)/$(_SOLUTION) -type d -print0 | xargs -0 -I '{}' sh -c "printf -- '-var-folder %s \ \n' '{}';" )
_destroy: ## Run `terraform destroy` using rover. Usage example: make destroy SOLUTION=launchpad_name LEVEL=0
	@echo -e "${LIGHTGRAY}$$(cd $(_BASE_DIR) && pwd)${NC}"
	@echo -e "${GREEN}Terraform destroy for '$(_SOLUTION) level$(_LEVEL)'${NC}"
	_ADD_ON=$(_ADD_ON)
	_LEVEL="level$(_LEVEL)"
	_SOLUTION=$(SOLUTION)
	_VARS=""
	if [ "$(_LEVEL)" == "0" ]; then _ADD_ON="caf_launchpad" _LEVEL="level0 -launchpad" && _VARS="'-var random_length=$(RANDOM_LENGTH)' '-var prefix=$(PREFIX)'"; fi
	if [ -d "$(LANDINGZONES_DIR)/caf_solution/$(_SOLUTION)" ]; then _ADD_ON="caf_solution/$(_SOLUTION)"; fi
	/bin/bash -c \
		"/tf/rover/rover.sh -lz $(LANDINGZONES_DIR)/$$_ADD_ON -a destroy \
			$(_VAR_FOLDERS) \
			-level $$_LEVEL \
			-tfstate $(_TFSTATE).tfstate \
			-log-severity ERROR \
			-parallelism $(PARALLELISM) \
			-env $(ENVIRONMENT)" || true

purge._skip:
	echo -e "${GREEN}Skip purging '$(PURGE)'${NC}";

purge._start:
	echo -e "${GREEN}Start Purging '$(PURGE)'${NC}";

purge.diagnostic-settings: ## Purge diagnostic settings using azure CLI (only for level 0)
	if [ "$(_LEVEL)" == "0" ]; then
		echo -e "${PURPLE}Running target '$@'${NC}";
		/bin/bash -c \
			"for i in \`az monitor diagnostic-settings subscription list -o tsv --query \"value[?contains(name, '$(PREFIX)-' )].name\"\`; do echo \"purging subscription diagnostic-settings: \$$i\" && \$$(az monitor diagnostic-settings subscription delete --name \$$i --yes); done"
	fi
purge.log-profiles: ## Purge log profiles using azure CLI
	if [ "$(_LEVEL)" == "0" ]; then
		echo -e "${PURPLE}Running target '$@'${NC}";
		/bin/bash -c \
			"for i in \`az monitor log-profiles list -o tsv --query '[].name'\`; do az monitor log-profiles delete --name \$$i; done"
	fi
purge.ad-users: ## Purge ad users using azure CLI
	if [ "$(_LEVEL)" == "0" ]; then
	echo -e "${PURPLE}Running target '$@'${NC}";
		/bin/bash -c \
			"for i in \`az ad user list -o tsv --query \"[?contains(displayName, '$(PREFIX)-' )].objectId\"\`; do echo \"purging Azure AD user: \$$i\" && \$$(az ad user delete --verbose --id \$$i || true); done"
	fi
purge.ad-groups: ## Purge ad groups using azure CLI
	if [ "$(_LEVEL)" == "0" ]; then
		echo -e "${PURPLE}Running target '$@'${NC}";
		/bin/bash -c \
			"for i in \`az ad group list -o tsv --query \"[?contains(displayName, '$(PREFIX)-' )].objectId\"\`; do echo \"purging Azure AD group: \$$i\" && \$$(az ad group delete --verbose --group \$$i || true); done"
	fi
purge.ad-apps: ## Purge ad apps using azure CLI
	if [ "$(_LEVEL)" == "0" ]; then
		echo -e "${PURPLE}Running target '$@'${NC}";
		/bin/bash -c \
			"for i in \`az ad app list -o tsv --query \"[?contains(displayName, '$(PREFIX)-' )].appId\"\`; do echo \"purging Azure AD app: \$$i\" && \$$(az ad app delete --verbose --id \$$i || true); done"
	fi
purge.keyvaults: ## Purge keyvaults using azure CLI
	@echo -e "${PURPLE}Running target '$@'${NC}";
	/bin/bash -c \
		"for i in \`az keyvault list-deleted -o tsv --query \"[?tags.environment=='$(ENVIRONMENT)' && tags.level=='level$(_LEVEL)' && tags.landingzone=='$(_SOLUTION)'].name\"\`; do az keyvault purge --name \$$i; done"
purge.resource-groups: ## Purge resource groups using azure CLI
	@echo -e "${PURPLE}Running target '$@'${NC}";
	/bin/bash -c \
    	"for i in \`az group list -o tsv --query \"[?tags.environment=='$(ENVIRONMENT)' && tags.level=='level$(_LEVEL)' && tags.landingzone=='$(_SOLUTION)' ].name\"\`; do echo \"purging resource group: \$$i\" && \$$(az group delete -n \$$i -y --no-wait || true); done"
purge.role-assignments: ## Purge custom role assignments using azure CLI
	if [ "$(_LEVEL)" == "0" ]; then
		echo -e "${PURPLE}Running target '$@'${NC}";
		/bin/bash -c \
			"for i in \`az role assignment list -o tsv --query \"[?contains(roleDefinitionName, '$(ENVIRONMENT)')].roleDefinitionName\"\`; do echo \"purging role assignment: \$$i\" && \$$(az role assignment delete --role \$$i || true); done"
	fi
purge.custom-role-definitions: ## Purge custom role definitions using azure CLI
	if [ "$(_LEVEL)" == "0" ]; then
		echo -e "${PURPLE}Running target '$@'${NC}";
		/bin/bash -c \
			"for i in \`az role definition list -o tsv --query \"[?contains(roleName, '$(ENVIRONMENT)')].roleName\"\`; do echo \"purging custom role definition: \$$i\" && \$$(az role definition delete --name \$$i || true); done"
	fi

purge: purge._start purge.diagnostic-settings purge.log-profiles purge.ad-users purge.ad-groups purge.ad-apps purge.keyvaults purge.resource-groups purge.role-assignments purge.custom-role-definitions ## Purge everything from all CAF landingzones using azure CLI
	echo -e "${GREEN}Purging complete${NC}"

destroy: _PURGE=$(PURGE)
destroy: _LEVEL=$(LEVEL)
destroy: _SOLUTION=$(SOLUTION)
destroy: _destroy $(if $(findstring false,$(PURGE)), purge._skip, purge) ## Destroy (and Purge) everything from all CAF landingzones using azure CLI
