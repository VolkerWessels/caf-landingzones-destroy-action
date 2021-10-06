# Internal variables.
SHELL := /bin/bash

# COLORS
LIGHTGRAY=\033[0;37m

_TFVARS_PATH:=/tf/caf/configuration
TFVARS_PATH?=$(_TFVARS_PATH)
_BASE_DIR = $(shell dirname $(TFVARS_PATH))

LANDINGZONES_DIR?="$(_BASE_DIR)/landingzones" ### Landingzone directory checkout dir. Defaults to 'landingzones/'
ENVIRONMENT := $(shell echo $(ENVIRONMENT) | tr '[:upper:]' '[:lower:]') ### Environment name to deploy to.
_VAR_FOLDERS= $(shell find $(TFVARS_PATH)/level$(_LEVEL)/$(_SOLUTION) -type d -print0 | xargs -0 -I '{}' sh -c "printf -- '-var-folder %s \ \n' '{}';" )
_TFSTATE = $(shell basename $(_SOLUTION))

_PREFIX:=g$(GITHUB_RUN_ID)
PREFIX?=$(_PREFIX)
PREFIX?=$(shell echo $(PREFIX)|tr '[:upper:]' '[:lower:]') ### Prefix azure resource naming.

destroy: ## Run `terraform destroy` using rover. Usage example: make destroy SOLUTION=launchpad_name LEVEL=0
	@echo -e "${LIGHTGRAY}$$(cd $(_BASE_DIR) && pwd)${NC}"
	@echo -e "${GREEN}Terraform destroy for '$(_SOLUTION) level$(_LEVEL)'${NC}"
	_LEVEL="level$(_LEVEL)"
	_SOLUTION=$(SOLUTION)
	_VARS=""
	if [ "$(_LEVEL)" == "0" ]; then _ADD_ON="caf_launchpad" _LEVEL="level0 -launchpad" && _VARS="'-var random_length=$(RANDOM_LENGTH)' '-var prefix=$(PREFIX)'"; fi
	if [ "$(_LEVEL)" == "1" ]; then _ADD_ON="ssc_foundations_sharedservices" _LEVEL="level1" && _VARS="'-var random_length=$(RANDOM_LENGTH)' '-var prefix=$(PREFIX)'"; fi
	/tf/rover/rover.sh -lz ${LANDINGZONES_DIR}/${ADD_ON} -a destroy \
		$(_VAR_FOLDERS) \
		-level $$_LEVEL \
		-tfstate $(_TFSTATE).tfstate \
		-parallelism $(PARALLELISM) \
		-env $(ENVIRONMENT) \
		$$_VARS"

purge:
	for i in `az monitor diagnostic-settings subscription list -o tsv --query "value[?contains(name, '${{ github.run_id }}' )].name"`; do echo "purging subscription diagnostic-settings: $i" && $(az monitor diagnostic-settings subscription delete --name $i --yes); done
	for i in `az monitor log-profiles list -o tsv --query '[].name'`; do az monitor log-profiles delete --name $i; done
	for i in `az ad group list --query "[?contains(displayName, '${{ github.run_id }}')].objectId" -o tsv`; do echo "purging Azure AD group: $i" && $(az ad group delete --verbose --group $i || true); done
	for i in `az ad app list --query "[?contains(displayName, '${{ github.run_id }}')].appId" -o tsv`; do echo "purging Azure AD app: $i" && $(az ad app delete --verbose --id $i || true); done
	for i in `az keyvault list-deleted --query "[?tags.environment=='${{ github.run_id }}'].name" -o tsv`; do az keyvault purge --name $i; done
	for i in `az group list --query "[?tags.environment=='${{ github.run_id }}'].name" -o tsv`; do echo "purging resource group: $i" && $(az group delete -n $i -y --no-wait || true); done
	for i in `az role assignment list --query "[?contains(roleDefinitionName, '${{ github.run_id }}')].roleDefinitionName" -o tsv`; do echo "purging role assignment: $i" && $(az role assignment delete --role $i || true); done
	for i in `az role definition list --query "[?contains(roleName, '${{ github.run_id }}')].roleName" -o tsv`; do echo "purging custom role definition: $i" && $(az role definition delete --name $i || true); done
