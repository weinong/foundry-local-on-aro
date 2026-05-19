# Makefile — Foundry Local on Azure Red Hat OpenShift
#
# Each target writes a sentinel under .state/ so `make all` is resumable.
# See AGENTS.md for the goal and behavior rules.

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

REPO_ROOT := $(shell pwd)
STATE_DIR := $(REPO_ROOT)/.state
SCRIPTS   := $(REPO_ROOT)/scripts
ENV       := $(REPO_ROOT)/env.sh

SOURCE_ENV := source $(ENV)

.PHONY: help all preflight aro oc-login prep-arc arc-connect entra-app \
        cert-manager ingress foundry-operator validate report teardown \
        clean-state

help:
	@echo "Foundry Local on ARO — make targets"
	@echo ""
	@echo "  make preflight         Check local tools and pull secret."
	@echo "  make aro               Create ARO cluster (~45 min)."
	@echo "  make oc-login          Fetch kubeadmin creds, write ./kubeconfig."
	@echo "  make prep-arc          OpenShift SCC + Arc resource providers + CLI ext."
	@echo "  make arc-connect       Connect cluster to Azure Arc."
	@echo "  make entra-app         Create Entra app registration for Foundry auth."
	@echo "  make cert-manager      Install Microsoft.CertManagement Arc extension."
	@echo "  make ingress           Install ingress-nginx (ClusterIP only)."
	@echo "  make foundry-operator  Install Microsoft.Foundry Arc extension."
	@echo "  make validate          Deploy a model and run an inference call."
	@echo ""
	@echo "  make all               Run the full pipeline in order (resumable)."
	@echo "  make report            Print docs/validation-report.md."
	@echo "  make teardown          Delete all Azure resources (interactive)."
	@echo "  make clean-state       Remove .state/ sentinels (forces re-run)."
	@echo ""
	@echo "Variables (override on the command line):"
	@echo "  LOCATION (default: centralus)"
	@echo "  RESOURCEGROUP (default: aro-virt-test-rg)"
	@echo "  CLUSTER (default: aro-virt-test)"

all: validate

preflight: $(STATE_DIR)/preflight.done
$(STATE_DIR)/preflight.done:
	@$(SOURCE_ENV)
	echo "[preflight] checking local tools..."
	for cmd in az oc kubectl helm jq curl python3; do
	  if ! command -v $$cmd >/dev/null 2>&1; then
	    echo "[preflight] missing required tool: $$cmd" >&2
	    exit 1
	  fi
	done
	require_azure_login
	if ! validate_pull_secret "$$PULL_SECRET_FILE"; then
	  exit 1
	fi
	echo "[preflight] OK"
	mark_state preflight
	touch $@

aro: $(STATE_DIR)/aro.done
$(STATE_DIR)/aro.done: $(STATE_DIR)/preflight.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/01-aro-infra.sh
	touch $@

oc-login: $(STATE_DIR)/oc-login.done
$(STATE_DIR)/oc-login.done: $(STATE_DIR)/aro.done
	@$(SOURCE_ENV)
	require_azure_login
	echo "[oc-login] retrieving kubeadmin credentials..."
	creds=$$(az aro list-credentials -g "$$RESOURCEGROUP" -n "$$CLUSTER" -o json)
	user=$$(echo "$$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["kubeadminUsername"])')
	pass=$$(echo "$$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["kubeadminPassword"])')
	api=$$(az aro show -g "$$RESOURCEGROUP" -n "$$CLUSTER" --query apiserverProfile.url -o tsv)
	# Restrict kubeconfig to owner-only — it embeds a long-lived kubeadmin token.
	umask 077
	export KUBECONFIG="$$KUBECONFIG_FILE"
	: > "$$KUBECONFIG_FILE"
	chmod 600 "$$KUBECONFIG_FILE"
	oc login --server="$$api" --username="$$user" --password="$$pass" --insecure-skip-tls-verify=true
	chmod 600 "$$KUBECONFIG_FILE"
	oc whoami
	oc get nodes
	mark_state oc-login
	progress_log "oc-login" "Wrote kubeconfig to local file for API \`$$api\`."
	touch $@

prep-arc: $(STATE_DIR)/prep-arc.done
$(STATE_DIR)/prep-arc.done: $(STATE_DIR)/oc-login.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/03-aro-prep-for-arc.sh
	touch $@

arc-connect: $(STATE_DIR)/arc-connect.done
$(STATE_DIR)/arc-connect.done: $(STATE_DIR)/prep-arc.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/04-arc-connect.sh
	touch $@

entra-app: $(STATE_DIR)/entra-app.done
$(STATE_DIR)/entra-app.done: $(STATE_DIR)/arc-connect.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/05-entra-app.sh
	touch $@

cert-manager: $(STATE_DIR)/cert-manager.done
$(STATE_DIR)/cert-manager.done: $(STATE_DIR)/arc-connect.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/06-cert-manager.sh
	touch $@

ingress: $(STATE_DIR)/ingress.done
$(STATE_DIR)/ingress.done: $(STATE_DIR)/arc-connect.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/07-ingress-nginx.sh
	touch $@

foundry-operator: $(STATE_DIR)/foundry-operator.done
$(STATE_DIR)/foundry-operator.done: $(STATE_DIR)/cert-manager.done $(STATE_DIR)/ingress.done $(STATE_DIR)/entra-app.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/08-foundry-operator.sh
	touch $@

validate: $(STATE_DIR)/validate.done
$(STATE_DIR)/validate.done: $(STATE_DIR)/foundry-operator.done
	@$(SOURCE_ENV)
	$(SCRIPTS)/09-validate.sh
	touch $@

report:
	@cat $(REPO_ROOT)/docs/validation-report.md

teardown:
	@$(SOURCE_ENV)
	if ! tty -s; then
	  echo "[teardown] requires an interactive terminal (refusing to run with non-TTY stdin)" >&2
	  exit 1
	fi
	read -r -p "This will DELETE the ARO cluster, Arc connectedCluster, Entra app, and resource group [$$RESOURCEGROUP]. Type the cluster name to confirm: " confirm
	if [[ "$$confirm" != "$$CLUSTER" ]]; then
	  echo "Aborted."
	  exit 1
	fi
	$(SCRIPTS)/99-teardown.sh

clean-state:
	rm -f $(STATE_DIR)/*.done
	@echo "Cleared .state/ sentinels. Next 'make' will re-run all phases."
