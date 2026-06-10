# Image URL to use all building/pushing image targets
IMG ?= konflux-ci/tekton-kueue:latest
KIND_CLUSTER ?= kind
RELEASE_DIR ?= release
VERSION ?= nightly

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
# Be aware that the target commands are only tested with Docker which is
# scaffolded by default. However, you might want to replace it to use other
# tools. (i.e. podman)
CONTAINER_TOOL ?= podman

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk command is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet setup-envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test $$(go list ./... | grep -v /e2e) -coverprofile cover.out

# TODO(user): To use a different vendor for e2e tests, modify the setup under 'tests/e2e'.
# The default setup assumes Kind is pre-installed and builds/loads the Manager Docker image locally.
# Prometheus and CertManager are installed by default; skip with:
# - PROMETHEUS_INSTALL_SKIP=true
# - CERT_MANAGER_INSTALL_SKIP=true
.PHONY: test-e2e
test-e2e: manifests generate fmt vet ## Run the e2e tests. Expected an isolated environment using Kind.
	@command -v kind >/dev/null 2>&1 || { \
		echo "Kind is not installed. Please install Kind manually."; \
		exit 1; \
	}
	@kind get clusters | grep -q -E 'kind|kueue' || { \
		echo "No Kind cluster is running. Please start a Kind cluster before running the e2e tests."; \
		exit 1; \
	}
	go test ./test/e2e/ -v -ginkgo.v

.PHONY: lint
lint: golangci-lint ## Run golangci-lint linter
	$(GOLANGCI_LINT) run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint linter and perform fixes
	$(GOLANGCI_LINT) run --fix

.PHONY: lint-config
lint-config: golangci-lint ## Verify golangci-lint linter configuration
	$(GOLANGCI_LINT) config verify

##@ Build

.PHONY: build
build: manifests generate fmt vet ## Build manager binary.
	go build -o bin/manager cmd/main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

# If you wish to build the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	$(CONTAINER_TOOL) build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

# PLATFORMS defines the target platforms for the manager image be built to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - be able to use docker buildx. More info: https://docs.docker.com/build/buildx/
# - have enabled BuildKit. More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image to your registry (i.e. if you do not set a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To adequately provide solutions that are compatible with multiple platforms, you should consider using this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- $(CONTAINER_TOOL) buildx create --name tekton-kueue-builder
	$(CONTAINER_TOOL) buildx use tekton-kueue-builder
	- $(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- $(CONTAINER_TOOL) buildx rm tekton-kueue-builder
	rm Dockerfile.cross

.PHONY: build-installer
build-installer: manifests generate kustomize ## Generate a consolidated YAML with CRDs and deployment.
	mkdir -p dist
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default > dist/install.yaml

.PHONY: release
release: kustomize
	mkdir -p ${RELEASE_DIR}
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	cd config/webhook && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default -o ${RELEASE_DIR}/release-${VERSION}.yaml

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	[[ ! -d config/crd ]] && { echo "config/crd directory doesn't exist"; } || \
	$(KUSTOMIZE) build config/crd | $(KUBECTL) apply --server-side -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy-apply
deploy-apply: manifests kustomize ## Apply controller manifests without waiting for rollouts.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	cd config/webhook && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply --server-side -f -

.PHONY: deploy
deploy: deploy-apply ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	$(KUBECTL) wait --for=condition=Available deployment --all -n tekton-kueue --timeout=300s

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

##@ Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUBECTL ?= kubectl
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GOLANGCI_LINT = $(LOCALBIN)/golangci-lint

## Tool Versions
KUSTOMIZE_VERSION ?= v5.5.0
CONTROLLER_TOOLS_VERSION ?= v0.17.1
#ENVTEST_VERSION is the version of controller-runtime release branch to fetch the envtest setup script (i.e. release-0.20)
ENVTEST_VERSION ?= $(shell go list -m -f "{{ .Version }}" sigs.k8s.io/controller-runtime | awk -F'[v.]' '{printf "release-%d.%d", $$2, $$3}')
#ENVTEST_K8S_VERSION is the version of Kubernetes to use for setting up ENVTEST binaries (i.e. 1.31)
ENVTEST_K8S_VERSION ?= $(shell go list -m -f "{{ .Version }}" k8s.io/api | awk -F'[v.]' '{printf "1.%d", $$3}')
GOLANGCI_LINT_VERSION ?= v2.7.2
KUEUE_VERSION ?= $(shell ./hack/get-kueue-version.sh)
# hack-oc MultiKueue spokes: must serve v1beta2 when CRC hub uses RH Kueue operator 1.3+ (override via KUEUE_OSS_VERSION in 01-setup-multikueue.sh).
KUEUE_OSS_VERSION ?= v0.17.3
TEKTON_VERSION ?= v1.7.0
CERT_MANAGER_VERSION ?= v1.19.2

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: setup-envtest
setup-envtest: envtest ## Download the binaries required for ENVTEST in the local bin directory.
	@echo "Setting up envtest binaries for Kubernetes version $(ENVTEST_K8S_VERSION)..."
	@$(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path || { \
		echo "Error: Failed to set up envtest binaries for version $(ENVTEST_K8S_VERSION)."; \
		exit 1; \
	}

.PHONY: envtest
envtest: $(ENVTEST) ## Download setup-envtest locally if necessary.
$(ENVTEST): $(LOCALBIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/v2/cmd/golangci-lint,$(GOLANGCI_LINT_VERSION))

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) || true ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $(1)-$(3) $(1)
endef

.PHONY: kueue
kueue:
	$(KUBECTL) apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/$(KUEUE_VERSION)/manifests.yaml -f hack/kueue-config.yaml
	$(KUBECTL) rollout status deployment/kueue-controller-manager -n kueue-system --timeout 300s

.PHONY: tekton
tekton:
	$(KUBECTL) apply --server-side -f https://infra.tekton.dev/tekton-releases/pipeline/previous/$(TEKTON_VERSION)/release.yaml
	$(KUBECTL) wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

.PHONY: cert-manager
cert-manager:
	$(KUBECTL) apply --server-side -f https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml 
	$(KUBECTL) wait --for=condition=Available deployment --all -n cert-manager --timeout=300s 

.PHONY: cert-manager-undeploy
cert-manager-undeploy:
	$(KUBECTL) delete -f https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml 

##@ OLM (CRC / OpenShift hub)

# Red Hat operators from the built-in redhat-operators catalog (see hack-oc/olm/README.md).
# Invoked by hack-oc/01-setup-multikueue.sh on the CRC hub (HUB_DEPS_INSTALL=olm).
OLM_DIR ?= hack-oc/olm
OC ?= $(shell command -v oc 2>/dev/null)
OLM_CERT_MANAGER_CHANNEL ?= stable-v1
# CRC 4.21+ catalogs ship stable-v1.2/stable-v1.3 (not stable-v1.0). Empty => packagemanifest defaultChannel.
OLM_KUEUE_CHANNEL ?=
# Pin a stable channel; CRC defaultChannel is often "latest" and can prolong operator reconcile.
OLM_PIPELINES_CHANNEL ?= pipelines-1.22
OLM_SUBSCRIPTION_WAIT_ITERATIONS ?= 120
OLM_SUBSCRIPTION_WAIT_SLEEP ?= 5

.PHONY: olm-cert-manager olm-openshift-pipelines olm-kueue olm-tekton-scc olm-deps-crc \
	olm-wait-marketplace olm-wait-subscription olm-wait-tektonconfig \
	olm-enable-pipelines-console-plugin

# Fresh CRC: catalog pods + gRPC must be healthy before subscriptions (avoids ResolutionFailed).
olm-wait-marketplace:
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@echo "Waiting for redhat-operators catalog pod (1/1 Running)..."
	@i=0; while [ $$i -lt 72 ]; do \
	  if $(OC) get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators --no-headers 2>/dev/null \
	    | awk 'NF && $$3 == "Running" && $$2 ~ /1\/1/ { ok=1 } END { exit !ok }'; then break; fi; \
	  if [ $$((i % 6)) -eq 0 ]; then \
	    echo "  redhat-operators catalog pod not ready:"; \
	    $(OC) get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators 2>/dev/null; \
	    if $(OC) get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators --no-headers 2>/dev/null | grep -q ImagePullBackOff; then \
	      echo "  FIX: CRC cannot pull registry.redhat.io/redhat/redhat-operator-index"; \
	      echo "       podman login registry.redhat.io  # Customer Portal credentials"; \
	      echo "       then: crc stop && crc start   # or merge into cluster pull-secret"; \
	      echo "       see hack-oc/olm/README.md#crc-registry-authentication"; fi; fi; \
	  sleep 5; i=$$((i + 1)); \
	done; \
	if [ $$i -ge 72 ]; then echo "Timed out waiting for redhat-operators catalog pod."; exit 1; fi
	@echo "Waiting for redhat-operators catalog gRPC (packagemanifest API)..."
	@stable=0; i=0; \
	pkgs="openshift-cert-manager-operator openshift-pipelines-operator-rh kueue-operator"; \
	while [ $$i -lt 60 ]; do \
	  ok=1; \
	  for pkg in $$pkgs; do \
	    if ! $(OC) get packagemanifest "$$pkg" >/dev/null 2>&1; then ok=0; fi; \
	  done; \
	  if [ $$ok -eq 1 ]; then stable=$$((stable + 1)); else stable=0; fi; \
	  if [ $$stable -ge 3 ]; then echo "Catalog API ready (packagemanifests resolvable)."; exit 0; fi; \
	  if [ $$((i % 6)) -eq 0 ]; then echo "  packagemanifest API not stable yet (need 3 OK polls)..."; fi; \
	  sleep 5; i=$$((i + 1)); \
	done; \
	echo "Timed out waiting for catalog gRPC. Check: oc get pods -n openshift-marketplace"; exit 1

# Usage: make olm-wait-subscription OLM_WAIT_NS=... OLM_WAIT_SUB=... [OLM_WAIT_MANIFEST=path/to/subscription.yaml]
olm-wait-subscription:
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@test -n "$(OLM_WAIT_NS)" -a -n "$(OLM_WAIT_SUB)" || { echo "Set OLM_WAIT_NS and OLM_WAIT_SUB."; exit 1; }
	@echo "Waiting for subscription $(OLM_WAIT_SUB) in $(OLM_WAIT_NS) (AtLatestKnown)..."
	@ns="$(OLM_WAIT_NS)"; sub="$(OLM_WAIT_SUB)"; manifest="$(OLM_WAIT_MANIFEST)"; \
	iter="$(OLM_SUBSCRIPTION_WAIT_ITERATIONS)"; sleep_s="$(OLM_SUBSCRIPTION_WAIT_SLEEP)"; \
	recreated=0; i=0; while [ $$i -lt $$iter ]; do \
	  state=$$($(OC) get subscription "$$sub" -n "$$ns" -o jsonpath='{.status.state}' 2>/dev/null || true); \
	  csv=$$($(OC) get subscription "$$sub" -n "$$ns" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true); \
	  phase=; \
	  if [ -n "$$csv" ]; then phase=$$($(OC) get csv "$$csv" -n "$$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true); fi; \
	  if [ "$$state" = "AtLatestKnown" ] && [ "$$phase" = "Succeeded" ]; then \
	    echo "Subscription $$sub ready (CSV $$csv)."; exit 0; fi; \
	  if [ "$$state" = "UpgradeFailed" ] || [ "$$phase" = "Failed" ]; then \
	    echo "Subscription $$sub failed (state=$$state, csv=$$csv, phase=$$phase)."; \
	    $(OC) describe subscription "$$sub" -n "$$ns" 2>/dev/null | tail -20 || true; exit 1; fi; \
	  res_failed=$$($(OC) get subscription "$$sub" -n "$$ns" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}' 2>/dev/null || true); \
	  res_msg=$$($(OC) get subscription "$$sub" -n "$$ns" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}' 2>/dev/null || true); \
	  pkg=$$($(OC) get subscription "$$sub" -n "$$ns" -o jsonpath='{.spec.name}' 2>/dev/null || true); \
	  if echo "$$res_msg" | grep -q "no operators found in channel"; then \
	    echo "Subscription $$sub: channel not in catalog (wrong OLM_KUEUE_CHANNEL?)."; \
	    echo "  Available channels: $$($(OC) get packagemanifest "$$pkg" -o jsonpath='{range .status.channels[*]}{.name}{" "}{end}' 2>/dev/null)"; exit 1; fi; \
	  if [ "$$res_failed" = "True" ] && [ -n "$$manifest" ] && [ $$recreated -eq 0 ]; then \
	    if echo "$$res_msg" | grep -q "no operators found in channel"; then :; else \
	    if [ -n "$$pkg" ] && $(OC) get packagemanifest "$$pkg" >/dev/null 2>&1; then \
	      echo "Recreating subscription $$sub (stale ResolutionFailed after catalog came up)..."; \
	      $(OC) delete subscription "$$sub" -n "$$ns" --ignore-not-found; sleep 5; \
	      $(OC) apply -f "$$manifest"; recreated=1; i=0; continue; fi; fi; fi; \
	  if [ $$((i % 6)) -eq 0 ]; then \
	    echo "  still waiting: state=$${state:-<none>} currentCSV=$${csv:-<none>} phase=$${phase:-<none>}"; \
	    if [ "$$res_failed" = "True" ]; then echo "  ResolutionFailed: $$res_msg"; fi; fi; \
	  sleep $$sleep_s; i=$$((i + 1)); \
	done; \
	echo "Timed out waiting for subscription $$sub in $$ns."; \
	$(OC) get subscription,csv,installplan -n "$$ns" 2>/dev/null || true; exit 1

# Wait until the OpenShift Pipelines operator reports TektonConfig ready (not every Deployment).
olm-wait-tektonconfig:
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@echo "Waiting for TektonConfig/config Ready..."
	@iter="$(OLM_SUBSCRIPTION_WAIT_ITERATIONS)"; sleep_s="$(OLM_SUBSCRIPTION_WAIT_SLEEP)"; \
	i=0; while [ $$i -lt $$iter ]; do \
	  ready=$$($(OC) get tektonconfig config -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true); \
	  if [ "$$ready" = "True" ]; then echo "TektonConfig/config is Ready."; exit 0; fi; \
	  msg=$$($(OC) get tektonconfig config -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true); \
	  if [ $$((i % 6)) -eq 0 ]; then echo "  TektonConfig not ready: $${msg:-<no TektonConfig yet>}"; fi; \
	  sleep $$sleep_s; i=$$((i + 1)); \
	done; \
	echo "TektonConfig still not Ready; checking core deployments in openshift-pipelines..."; \
	ok=1; \
	for dep in tekton-pipelines-controller tekton-pipelines-webhook tekton-events-controller; do \
	  if ! $(OC) wait deployment/$$dep -n openshift-pipelines --for=condition=Available --timeout=120s 2>/dev/null; then ok=0; fi; \
	done; \
	if [ $$ok -eq 1 ]; then echo "Core OpenShift Pipelines deployments are Available (TektonConfig may still be catching up)."; exit 0; fi; \
	echo "Timed out waiting for OpenShift Pipelines."; \
	$(OC) get tektonconfig,tektonpipeline -o wide 2>/dev/null || true; \
	$(OC) get deploy,pods -n openshift-pipelines 2>/dev/null || true; exit 1

# Operator installs ConsolePlugin + backend, but the web console loads plugins only when listed in
# console.operator/cluster spec.plugins (opt-in; Subscription YAML install skips OperatorHub UI).
olm-enable-pipelines-console-plugin:
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@echo "Enabling pipelines-console-plugin in OpenShift Console..."
	@plugin="pipelines-console-plugin"; \
	i=0; while [ $$i -lt 60 ]; do \
	  if $(OC) get consoleplugin "$$plugin" >/dev/null 2>&1; then break; fi; \
	  if [ $$((i % 6)) -eq 0 ]; then echo "  waiting for ConsolePlugin/$$plugin..."; fi; \
	  sleep 5; i=$$((i + 1)); \
	done; \
	if ! $(OC) get consoleplugin "$$plugin" >/dev/null 2>&1; then \
	  echo "ConsolePlugin $$plugin not found; skipping console enable."; exit 0; fi; \
	if command -v jq >/dev/null 2>&1; then \
	  patch=$$($(OC) get console.operator cluster -o json | jq -c --arg p "$$plugin" \
	    'if ((.spec.plugins // []) | index($$p)) then empty \
	     else {spec: {plugins: ((.spec.plugins // []) + [$$p] | unique)}} end'); \
	  if [ -z "$$patch" ]; then \
	    echo "pipelines-console-plugin already enabled in console.operator/cluster."; exit 0; fi; \
	  $(OC) patch console.operator cluster --type=merge -p "$$patch"; \
	  echo "pipelines-console-plugin enabled in console.operator/cluster."; exit 0; fi; \
	enabled=$$($(OC) get console.operator cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || true); \
	case " $$enabled " in *" $$plugin "*) \
	  echo "pipelines-console-plugin already enabled in console.operator/cluster."; exit 0;; esac; \
	$(OC) patch console.operator cluster --type=merge \
	  -p='{"spec":{"plugins":["networking-console-plugin","pipelines-console-plugin"]}}'; \
	echo "pipelines-console-plugin enabled in console.operator/cluster."

olm-cert-manager: olm-wait-marketplace
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@echo "=== cert-manager operator (OLM) ==="
	$(OC) apply -f $(OLM_DIR)/cert-manager/namespace.yaml
	$(OC) apply -f $(OLM_DIR)/cert-manager/operatorgroup.yaml
	@sed 's/^  channel: .*/  channel: $(OLM_CERT_MANAGER_CHANNEL)/' $(OLM_DIR)/cert-manager/subscription.yaml > $(OLM_DIR)/cert-manager/.subscription.generated.yaml
	$(OC) apply -f $(OLM_DIR)/cert-manager/.subscription.generated.yaml
	@$(MAKE) olm-wait-subscription OLM_WAIT_NS=cert-manager-operator OLM_WAIT_SUB=openshift-cert-manager-operator OLM_WAIT_MANIFEST=$(OLM_DIR)/cert-manager/.subscription.generated.yaml
	$(OC) apply -f $(OLM_DIR)/cert-manager/instance.yaml
	@echo "Waiting for cert-manager operand in cert-manager namespace..."
	$(OC) wait --for=condition=Available deployment --all -n cert-manager --timeout=600s

olm-openshift-pipelines: olm-wait-marketplace
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@echo "=== OpenShift Pipelines operator (OLM) ==="
	@channel="$(OLM_PIPELINES_CHANNEL)"; \
	echo "OpenShift Pipelines channel: $$channel"; \
	sed "s/^  channel: .*/  channel: $$channel/" $(OLM_DIR)/openshift-pipelines/subscription.yaml > $(OLM_DIR)/openshift-pipelines/.subscription.generated.yaml; \
	$(OC) apply -f $(OLM_DIR)/openshift-pipelines/.subscription.generated.yaml
	@$(MAKE) olm-wait-subscription OLM_WAIT_NS=openshift-operators OLM_WAIT_SUB=openshift-pipelines-operator OLM_WAIT_MANIFEST=$(OLM_DIR)/openshift-pipelines/.subscription.generated.yaml
	@$(MAKE) olm-tekton-scc
	@$(MAKE) olm-wait-tektonconfig
	@$(MAKE) olm-enable-pipelines-console-plugin

.PHONY: olm-tekton-scc
olm-tekton-scc:
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@echo "Granting privileged SCC to OpenShift Pipelines service accounts (CRC)..."
	@ns=openshift-pipelines; \
	if ! $(OC) get ns $$ns >/dev/null 2>&1; then ns=tekton-pipelines; fi; \
	for sa in tekton-pipelines-controller tekton-pipelines-webhook tekton-events-controller \
		tekton-pipelines-resolvers tekton-operators-proxy-webhook pipeline; do \
	  $(OC) adm policy add-scc-to-user privileged -z $$sa -n $$ns 2>/dev/null || true; \
	done

# Install Kueue operator only; run make olm-cert-manager first (olm-deps-crc orders this for you).
olm-kueue:
	@test -n "$(OC)" || { echo "oc is required for OLM targets (CRC/OpenShift)."; exit 1; }
	@echo "=== Kueue operator (OLM) ==="
	$(OC) apply -f $(OLM_DIR)/kueue/namespace.yaml
	$(OC) apply -f $(OLM_DIR)/kueue/operatorgroup.yaml
	@channel="$(OLM_KUEUE_CHANNEL)"; \
	if [ -z "$$channel" ]; then \
	  channel=$$($(OC) get packagemanifest kueue-operator -o jsonpath='{.status.defaultChannel}' 2>/dev/null) || channel=stable-v1.3; \
	fi; \
	echo "Kueue operator channel: $$channel (override: make olm-kueue OLM_KUEUE_CHANNEL=<channel>)"; \
	sed "s/^  channel: .*/  channel: $$channel/" $(OLM_DIR)/kueue/subscription.yaml > $(OLM_DIR)/kueue/.subscription.generated.yaml
	@$(OC) apply -f $(OLM_DIR)/kueue/.subscription.generated.yaml
	@$(MAKE) olm-wait-subscription OLM_WAIT_NS=openshift-kueue-operator OLM_WAIT_SUB=kueue-operator OLM_WAIT_MANIFEST=$(OLM_DIR)/kueue/.subscription.generated.yaml
	$(OC) apply -f $(OLM_DIR)/kueue/instance.yaml
	@echo "Waiting for Kueue controller..."
	$(OC) wait --for=condition=Available deployment --all -n openshift-kueue-operator --timeout=600s 2>/dev/null || true
	$(OC) wait --for=condition=Available deployment --all -n kueue-system --timeout=600s 2>/dev/null || true

# Full hub stack (cert-manager -> pipelines+SCC+TektonConfig -> kueue). Used by hack-oc/01-setup-multikueue.sh.
olm-deps-crc: olm-cert-manager olm-openshift-pipelines olm-kueue
	@echo "OLM hub dependencies ready (cert-manager, OpenShift Pipelines, Kueue)."

##@ MultiKueue (CRC hub + Kind spokes)

MULTIKUEUE_SCRIPT ?= hack-oc/01-setup-multikueue.sh
MULTIKUEUE_KUBECONFIG ?= /tmp/tekton-kueue/e2e/multikueue/multikueue.kubeconfig
NUM_WORKERS ?= 1
HUB_DEPS_INSTALL ?= olm

.PHONY: provision provision-hub provision-spokes provision-run

# Shared env for hack-oc/01-setup-multikueue.sh (phase set by each public target).
provision-run:
	@test -f "$(MULTIKUEUE_SCRIPT)" || { echo "Missing $(MULTIKUEUE_SCRIPT)"; exit 1; }
	MULTIKUEUE_PHASE=$(MULTIKUEUE_PHASE) \
	NUM_WORKERS=$(NUM_WORKERS) \
	KUBECONFIG=$(MULTIKUEUE_KUBECONFIG) \
	HUB_DEPS_INSTALL=$(HUB_DEPS_INSTALL) \
	KUEUE_OSS_VERSION=$(KUEUE_OSS_VERSION) \
	IMG=$(IMG) \
	bash "$(MULTIKUEUE_SCRIPT)"

provision: ## Provision CRC hub and Kind spokes end-to-end
	@$(MAKE) provision-run MULTIKUEUE_PHASE=all NUM_WORKERS=$(NUM_WORKERS)

provision-hub: ## Provision CRC hub only (OLM deps, tekton-kueue, MultiKueue CRs)
	@$(MAKE) provision-run MULTIKUEUE_PHASE=hub

provision-spokes: ## Provision Kind spokes and register them with the hub
	@$(MAKE) provision-run MULTIKUEUE_PHASE=spokes NUM_WORKERS=$(NUM_WORKERS)

.PHONY: load-image
load-image: docker-build
	dir=$$(mktemp -d) && \
	$(CONTAINER_TOOL) save $(IMG) -o $${dir}/tekton-kueue.tar && \
	kind load image-archive -n $(KIND_CLUSTER) $${dir}/tekton-kueue.tar && \
	rm -r $${dir}

# Apply tekton config  with all its dependencies.
.PHONY: apply
apply: docker-build docker-push release
	$(KUBECTL) apply --server-side -f ${RELEASE_DIR}/release-${VERSION}.yaml
	$(KUBECTL) wait --for=condition=Available deployment --all -n tekton-kueue --timeout=300s
