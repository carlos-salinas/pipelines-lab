#!/usr/bin/env bash

# This script sets up a MultiKueue environment with one manager and a specified number of workers.

set -o errexit
set -o nounset
set -o pipefail

# Number of workers to create, default to 1
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"
# Kind pulls unqualified refs as docker.io/library/<name>; use the same FQDN for build/load/deploy.
# Hub (CRC): still builds from IMG then pushes/openshift deploy uses internal registry ref from push_tekton_kueue_to_crc.
export IMG="${IMG:-docker.io/library/tekton-kueue:dev}"
CRC_PUSH_NAMESPACE="${CRC_PUSH_NAMESPACE:-tekton-kueue}"
CRC_IMAGE_NAME="${CRC_IMAGE_NAME:-tekton-kueue}"
# Optional: CRC registry image tag override (unset => derive tag from IMG)
CRC_IMAGE_TAG="${CRC_IMAGE_TAG-}"
KIND_API_HOST="${KIND_API_HOST-}"
# When substituting LAN IP for a loopback Kind URL, validate cert against this name (defaults to loopback hostname from kubeconfig).
KIND_KUBECONFIG_TLS_SERVER_NAME="${KIND_KUBECONFIG_TLS_SERVER_NAME-}"
# Dev-only: if Kind API TLS mismatches LAN IP — set KIND_KUBECONFIG_INSECURE_SKIP_TLS_VERIFY=true
KIND_KUBECONFIG_INSECURE_SKIP_TLS_VERIFY="${KIND_KUBECONFIG_INSECURE_SKIP_TLS_VERIFY:-}"
# Published Kind API on host: base port + spoke index (spoke-1 uses base+1). Bound to 0.0.0.0 so CRC VM can reach Mac LAN IP:port.
KIND_SPOKE_API_BASE_PORT="${KIND_SPOKE_API_BASE_PORT:-7650}"
KIND_EXPOSE_SPOKE_API_ON_LAN="${KIND_EXPOSE_SPOKE_API_ON_LAN:-true}"

NUM_WORKERS=${1:-1}
KUEUE_MANIFEST_URL="https://gist.githubusercontent.com/khrm/a83998529449ae0f0e25c264d4e61dd0/raw/bd7933eea4b509996dbe7a4739ff96dd2101b0e3/gistfile0.txt"

TEMP_DIR="/tmp/tekton-kueue/e2e/multikueue"
export KUBECONFIG=${KUBECONFIG:-$TEMP_DIR/multikueue.kubeconfig}
TEMP_DIR=$(dirname $KUBECONFIG)
mkdir -p ${TEMP_DIR}

# kubeconfig context for the hub (CRC). Set when the hub is provisioned.
HUB_CONTEXT="${HUB_CONTEXT:-}"

ensure_crc_started() {
  local status
  # crc status exits non-zero when the VM is missing, stopped, etc.; do not fail the script.
  status=$(crc status 2>&1) || true
  if echo "${status}" | grep -q '^OpenShift:[[:space:]]*Running'; then
    echo "CRC / OpenShift already running; skipping crc start."
    echo "${status}"
    return 0
  fi
  if echo "${status}" | grep -qi 'Machine does not exist'; then
    echo "CRC machine not found (crc status: Machine does not exist). Creating it with crc start..."
  else
    echo "CRC is not running; starting with crc start..."
    echo "${status}"
  fi
  crc start --memory 16384 --disk-size 60
}

# Prefer `crc generate-kubeconfig` (writes kubeconfig YAML to stdout); works when `crc kubeconfig` is absent.
crc_generate_kubeconfig_file() {
  local out
  out="$(mktemp "${TEMP_DIR}/crc-gen-kubeconfig.XXXXXX")"
  if ! crc generate-kubeconfig >"${out}"; then
    echo "crc generate-kubeconfig failed." >&2
    rm -f "${out}"
    return 1
  fi
  if [[ ! -s "${out}" ]]; then
    echo "crc generate-kubeconfig produced an empty file." >&2
    rm -f "${out}"
    return 1
  fi
  printf '%s\n' "${out}"
}

merge_crc_kubeconfig() {
  local kcfg crc_cfg merged
  kcfg="${KUBECONFIG%%:*}"
  [[ -f "${kcfg}" ]] || touch "${kcfg}"
  crc_cfg="$(crc_generate_kubeconfig_file)"
  merged="$(mktemp "${TEMP_DIR}/kubeconfig-merge.XXXXXX")"
  KUBECONFIG="${kcfg}:${crc_cfg}" kubectl config view --flatten > "${merged}"
  mv "${merged}" "${kcfg}"
  rm -f "${crc_cfg}"
  export KUBECONFIG="${kcfg}"
}

select_crc_context() {
  local ctx
  for ctx in crc-admin admin; do
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx "${ctx}"; then
      HUB_CONTEXT="${ctx}"
      kubectl config use-context "${HUB_CONTEXT}"
      echo "Using hub kubeconfig context: ${HUB_CONTEXT}"
      return 0
    fi
  done
  HUB_CONTEXT="$(kubectl config get-contexts -o name 2>/dev/null | grep -i crc | head -n1 || true)"
  if [[ -z "${HUB_CONTEXT}" ]]; then
    echo "Could not detect a CRC kubectl context (tried crc-admin, admin, or *crc*). Set HUB_CONTEXT." >&2
    exit 1
  fi
  kubectl config use-context "${HUB_CONTEXT}"
  echo "Using hub kubeconfig context: ${HUB_CONTEXT}"
}

# Assume ${built_ref} already exists locally (make docker-build). Tag & push to OpenShift registry (CRC / OCP hub).
push_tekton_kueue_to_crc() {
  local built_ref="$1"
  local ns="${CRC_PUSH_NAMESPACE}"
  local name="${CRC_IMAGE_NAME}"
  local tag="${CRC_IMAGE_TAG-}"
  if [[ -z "${tag}" ]]; then
    if [[ "${built_ref}" == *:* ]]; then
      tag="${built_ref##*:}"
    else
      tag="latest"
    fi
  fi

  local host=""
  host="$(kubectl get routes.route.openshift.io default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "${host}" ]]; then
    host="$(kubectl get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  fi
  if [[ -z "${host}" ]]; then
    host="default-route-openshift-image-registry.apps-crc.testing"
  fi

  local tool="${CONTAINER_TOOL:-podman}"
  command -v "${tool}" >/dev/null 2>&1 || tool="docker"
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "Need podman or docker to push images to CRC/OpenShift." >&2
    return 1
  }

  local dest_public="${host}/${ns}/${name}:${tag}"

  oc whoami >/dev/null 2>&1 || {
    echo "CRC hub: oc is not authenticated. Complete oc login against the CRC API after crc start." >&2
    return 1
  }

  # Only the final printf may go to stdout — this function is used inside $(...) for deploy_img.
  oc create namespace "${ns}" --dry-run=client -o yaml | oc apply -f - >/dev/null

  echo "Logging in to image registry (${host}) as $(oc whoami)..." >&2
  if [[ "${tool}" == "podman" ]]; then
    "${tool}" login --tls-verify=false -u "$(oc whoami)" -p "$(oc whoami -t)" "${host}" >&2 || true
  else
    "${tool}" login -u "$(oc whoami)" -p "$(oc whoami -t)" "${host}" >&2 || true
  fi

  echo "Pushing Tekton-Kueue image (${built_ref} -> ${dest_public})..." >&2
  "${tool}" tag "${built_ref}" "${dest_public}"
  # OpenShift registry certs often lack IP SANs; podman verifies TLS again on push (not only login).
  if ({ [[ "${tool}" == "podman" ]] && ! "${tool}" push --tls-verify=false "${dest_public}" >&2; } || \
      { [[ "${tool}" != "podman" ]] && ! DOCKER_TLS_VERIFY=0 "${tool}" push "${dest_public}" >&2; }); then
    echo "Route-based push failed (on macOS CRC, ${host} -> 127.0.0.1:443 often has nothing listening)." >&2
    echo "Retrying via kubectl port-forward to openshift-image-registry/image-registry:5000..." >&2
    local pf_port="${CRC_REGISTRY_PF_PORT:-5050}"
    local pf_bind="${CRC_REGISTRY_PF_BIND:-0.0.0.0}"
    # Podman Desktop / podman machine on macOS resolves 127.0.0.1 inside the VM, not your Mac —
    # use the LAN IP so the forwarded port (bound on 0.0.0.0) is reachable.
    local pf_host="${CRC_REGISTRY_PUSH_HOST-}"
    if [[ -z "${pf_host}" && "$(uname -s)" == "Darwin" && "${tool}" == "podman" ]]; then
      pf_host="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ipconfig getifaddr bridge100 2>/dev/null || true)"
      if [[ -z "${pf_host}" ]]; then
        pf_host="127.0.0.1"
        echo "Warning: could not resolve a Mac LAN IP for podman push; trying 127.0.0.1 (often fails with podman machine). Set CRC_REGISTRY_PUSH_HOST." >&2
      else
        echo "Using ${pf_host}:${pf_port} for podman registry push (reachable from podman VM)." >&2
      fi
    else
      pf_host="${pf_host:-127.0.0.1}"
    fi

    local pf_log="${TEMP_DIR}/registry-port-forward.log"
    kubectl port-forward --address="${pf_bind}" -n openshift-image-registry svc/image-registry "${pf_port}:5000" >"${pf_log}" 2>&1 &
    local pf_pid=$!
    sleep 1
    if ! kill -0 "${pf_pid}" 2>/dev/null; then
      echo "kubectl port-forward to image-registry exited immediately; log:" >&2
      sed 's/^/  | /' "${pf_log}" >&2 || true
      return 1
    fi

    local w=0
    local code="000"
    while (( w < 30 )); do
      code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${pf_host}:${pf_port}/v2/" 2>/dev/null || echo "000")"
      if [[ "${code}" == "401" || "${code}" == "200" ]]; then
        break
      fi
      sleep 1
      w=$(( w + 1 ))
    done

    local dest_pf="${pf_host}:${pf_port}/${ns}/${name}:${tag}"
    local pf_ok=1
    if [[ "${tool}" == "podman" ]]; then
      if "${tool}" login --tls-verify=false -u "$(oc whoami)" -p "$(oc whoami -t)" "${pf_host}:${pf_port}" >&2 \
        && "${tool}" tag "${built_ref}" "${dest_pf}" \
        && "${tool}" push --tls-verify=false "${dest_pf}" >&2; then
        pf_ok=0
      fi
    else
      if DOCKER_TLS_VERIFY=0 "${tool}" login -u "$(oc whoami)" -p "$(oc whoami -t)" "${pf_host}:${pf_port}" >&2 \
        && "${tool}" tag "${built_ref}" "${dest_pf}" \
        && DOCKER_TLS_VERIFY=0 "${tool}" push "${dest_pf}" >&2; then
        pf_ok=0
      fi
    fi
    kill "${pf_pid}" 2>/dev/null || true
    wait "${pf_pid}" 2>/dev/null || true
    if [[ "${pf_ok}" -ne 0 ]]; then
      echo "Port-forward push failed. Tips: expose host IP (set CRC_REGISTRY_PUSH_HOST), bind (CRC_REGISTRY_PF_BIND), port (CRC_REGISTRY_PF_PORT), ensure podman-machine can route to Mac." >&2
      echo "Example: kubectl port-forward --address 0.0.0.0 -n openshift-image-registry svc/image-registry ${pf_port}:5000" >&2
      return 1
    fi
    echo "Push via port-forward (${dest_pf}) succeeded." >&2
  fi

  local internal="image-registry.openshift-image-registry.svc:5000/${ns}/${name}:${tag}"

  echo "Waiting for ImageStreamTag ${name}:${tag} to appear (confirms registry has the manifest)..." >&2
  local retries=40
  while (( retries > 0 )); do
    if oc get "istag/${name}:${tag}" -n "${ns}" >/dev/null 2>&1; then
      echo "Registry reports tag ${name}:${tag} ready in ${ns}. Controller will pull: ${internal}" >&2
      printf '%s' "${internal}"
      return 0
    fi
    sleep 3
    retries=$(( retries - 1 ))
  done
  echo "Timed out waiting for ImageStreamTag ${name}:${tag} in ${ns}; push may have failed silently." >&2
  echo "Check: crc status; registry route (443) vs port-forward (CRC_REGISTRY_PF_PORT, default 5050)." >&2
  return 1
}

# Kind extraPortMappings (listenAddress 0.0.0.0) writes server https://0.0.0.0:<port> into kubeconfig.
# The API server cert is not valid for 0.0.0.0, so local kubectl fails OpenAPI/TLS validation.
# Point local kubectl at 127.0.0.1:<published-port>; CRC hub kubeconfig still uses LAN IP + tls-server-name.
fix_kind_spoke_local_kubeconfig() {
  local cluserName=$1
  local ppfile="${TEMP_DIR}/${cluserName}.published-api-port"
  [[ -f "${ppfile}" ]] || return 0
  local port
  port="$(tr -d '[:space:]' < "${ppfile}")"
  kubectl config set-cluster "kind-${cluserName}" \
    --server="https://127.0.0.1:${port}" \
    --kubeconfig="${KUBECONFIG}"
  echo "Local kubectl: kind-${cluserName} -> https://127.0.0.1:${port} (hub spoke kubeconfig uses LAN + tls-server-name)." >&2
}

function create_cluster() {
    local cluserName=$1
    local clusterType="spoke"
    # Optional second arg: hub | spoke. Anything else leaves default spoke and stays in "$@" for kind.
    if [[ $# -ge 2 && ( "$2" == "hub" || "$2" == "spoke" ) ]]; then
      clusterType=$2
      shift 2
    else
      shift 1
    fi

    if [[ "${clusterType}" == "hub" ]]; then
      ensure_crc_started
      merge_crc_kubeconfig
      select_crc_context

      oc create namespace tekton-pipelines --dry-run=client -o yaml | oc apply -f -  

      oc adm policy add-scc-to-user privileged \
      -z tekton-pipelines-controller \
      -n tekton-pipelines

      oc adm policy add-scc-to-user privileged \
      -z tekton-pipelines-webhook \
      -n tekton-pipelines

      oc adm policy add-scc-to-user privileged \
      -z tekton-events-controller \
      -n tekton-pipelines

      echo "Hub uses CRC (OpenShift): skipping kind; image will be built and pushed to the cluster registry."
    else
      local spoke_idx=1
      if [[ "${cluserName}" =~ ^spoke- ]]; then
        spoke_idx="${cluserName#spoke-}"
        [[ "${spoke_idx}" =~ ^[0-9]+$ ]] || spoke_idx=1
      fi
      local published_port=$(( KIND_SPOKE_API_BASE_PORT + spoke_idx ))
      local ppfile="${TEMP_DIR}/${cluserName}.published-api-port"
      local kind_cfg="${TEMP_DIR}/kind-config-${cluserName}.yaml"

      if kind get clusters | grep -q "^${cluserName}$"; then
        echo "  ✅ Cluster ${cluserName} already exists."
        if [[ "${KIND_EXPOSE_SPOKE_API_ON_LAN}" == "true" ]] && [[ ! -f "${ppfile}" ]]; then
          echo "  ⚠️  This cluster was not created with LAN-published API (missing ${ppfile})." >&2
          echo "      CRC hub cannot use 127.0.0.1-bound Docker ports. Delete and recreate:" >&2
          echo "        kind delete cluster --name ${cluserName}" >&2
          echo "      Expected published port for ${cluserName}: ${published_port} (host 0.0.0.0)." >&2
        fi
      else
        if [[ "${KIND_EXPOSE_SPOKE_API_ON_LAN}" == "true" ]]; then
          cat > "${kind_cfg}" <<EOFKIND
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${cluserName}
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 6443
    hostPort: ${published_port}
    listenAddress: "0.0.0.0"
    protocol: TCP
EOFKIND
          echo "  Creating Kind cluster ${cluserName} with API published on 0.0.0.0:${published_port} (LAN-reachable for CRC)." >&2
          kind create cluster --config="${kind_cfg}" "$@"
          echo "${published_port}" > "${ppfile}"
        else
          echo "  Creating Kind cluster ${cluserName} (no LAN publish — hub must reach spokes another way)." >&2
          kind create cluster --name="${cluserName}" "$@"
        fi
      fi

      kubectl config use-context "kind-${cluserName}"
      fix_kind_spoke_local_kubeconfig "${cluserName}"
      ( cd "${ROOT}" && make load-image "IMG=${IMG}" "KIND_CLUSTER=${cluserName}" )
    fi

    echo "Installing Kueue controller on $cluserName..."
    kubectl apply --server-side -f ${KUEUE_MANIFEST_URL}

    echo "Waiting for Kueue to be ready..."
    kubectl wait --for=condition=Available deployment --all -n kueue-system --timeout=300s

    echo "Installing tekton and cert-manager"
    ( cd "${ROOT}" && make tekton cert-manager )

    local deploy_img="${IMG}"
    if [[ "${clusterType}" == "hub" ]]; then
      echo "Building Tekton-Kueue manager image (${IMG}) for CRC hub..."
      ( cd "${ROOT}" && make docker-build "IMG=${IMG}" )
      deploy_img="$(push_tekton_kueue_to_crc "${IMG}")"
    fi

    echo "Deploying Tekton-Kueue controller (pull spec: ${deploy_img})..."
    ( cd "${ROOT}" && make deploy "IMG=${deploy_img}" )

    # Kind: never hit docker.io — use the tarball loaded via kind load image-archive only.
    if [[ "${clusterType}" != "hub" ]]; then
      echo "Kind spoke: forcing imagePullPolicy=Never so kubelet uses the loaded image (${deploy_img})..." >&2
      for dep in tekton-kueue-controller-manager tekton-kueue-webhook; do
        kubectl patch deployment/"${dep}" -n tekton-kueue --type=json \
          -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' 2>/dev/null \
          || echo "Could not patch imagePullPolicy for ${dep} (does it exist yet?)." >&2
      done
    fi

    echo "Waiting for cert-manager Certificates in tekton-kueue (metrics/webhook TLS secrets)..." >&2
    kubectl wait --for=condition=Ready certificate.cert-manager.io --all -n tekton-kueue --timeout=180s >/dev/null 2>&1 || true
    echo "Rolling controller/webhook workloads so mounts pick up metric/webhook certs..." >&2
    kubectl rollout restart deployment/tekton-kueue-controller-manager deployment/tekton-kueue-webhook -n tekton-kueue >/dev/null 2>&1 || true
    kubectl rollout status deployment/tekton-kueue-controller-manager -n tekton-kueue --timeout=300s || true
    kubectl rollout status deployment/tekton-kueue-webhook -n tekton-kueue --timeout=300s || true

    echo "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

    echo "Waiting for Tekton Pipelines to be ready..."
    kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

    case "${clusterType}" in
      hub)
        echo "Hub base install complete for ${cluserName} (MultiKueue applied from setup_hub_cluster)."
        ;;
      spoke|*)
        echo "Applying spoke worker setup on ${cluserName}..."
        kubectl apply -f "${ROOT}/config/samples/kueue/kueue-resources.yaml"
        create_worker_kubeconfig "${cluserName}"
        ;;
    esac

    echo "Cluster ${cluserName} is ready (${clusterType})"
}



# Function to set up the manager cluster
setup_hub_cluster() {
  cluserName=$1
  echo "Creating $cluserName cluster..."
  create_cluster "${cluserName}" hub

  #Apply MultiKueue Setup
  kubectl apply --server-side -f $ROOT/config/samples/multikueue/


}

# Function to create a kubeconfig for a worker
create_worker_kubeconfig() {
    local worker_name=$1
    local kubeconfig_out="$TEMP_DIR/${worker_name}.kubeconfig"
    local multikueue_sa="multikueue-sa"
    local namespace="kueue-system"

    kubectl config use-context "kind-${worker_name}"

    local ppfile="${TEMP_DIR}/${worker_name}.published-api-port"
    local published_api_port=""
    [[ -f "${ppfile}" ]] && published_api_port="$(tr -d '[:space:]' < "${ppfile}" || true)"

    local raw_server
    raw_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")"

    local hp="" h="" p=""
    local current_cluster_addr=""
    local tls_extra=""
    if [[ -n "${published_api_port}" ]]; then
      p="${published_api_port}"
      h="127.0.0.1"
    elif [[ -n "${raw_server}" ]]; then
      hp="${raw_server#https://}"
      hp="${hp#http://}"
      hp="${hp%%/*}"
      if [[ "${hp}" == *:* ]]; then
        h="${hp%%:*}"
        p="${hp##*:}"
      else
        h="${hp}"
        p="6443"
      fi
    fi

    local publish_host="${KIND_API_HOST-}"
    if [[ -n "${h}" ]] && [[ -z "${publish_host}" ]] && ([[ "${h}" == "127.0.0.1" ]] || [[ "${h}" == "localhost" ]]); then
      if [[ "$(uname -s)" == "Darwin" ]]; then
        publish_host="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ipconfig getifaddr bridge100 2>/dev/null || true)"
      fi
    fi

    if [[ -n "${p}" && ( -n "${published_api_port}" || -n "${raw_server}" ) ]] && [[ -n "${h}" || -n "${published_api_port}" ]]; then
      # published path: h may be set to 127.0.0.1 from above
      if [[ -z "${h}" ]]; then
        h="127.0.0.1"
      fi
      if [[ -n "${publish_host}" ]]; then
        current_cluster_addr="https://${publish_host}:${p}"
        local tls_sn="${KIND_KUBECONFIG_TLS_SERVER_NAME-}"
        [[ -n "${tls_sn}" ]] || tls_sn="127.0.0.1"
        tls_extra=$'\n    tls-server-name: '"${tls_sn}"
        echo "Spoke kubeconfig for CRC hub: API -> ${current_cluster_addr} (tls-server-name: ${tls_sn})" >&2
      elif [[ -n "${published_api_port}" ]]; then
        echo "Warning: LAN host unknown; set KIND_API_HOST. Published API port is ${p} on host 0.0.0.0." >&2
        current_cluster_addr="https://127.0.0.1:${p}"
      else
        current_cluster_addr="${raw_server}"
        if ([[ "${h}" == "127.0.0.1" ]] || [[ "${h}" == "localhost" ]]); then
          echo "Warning: Kind API URL is ${raw_server}. Docker may bind 127.0.0.1 only — CRC needs 0.0.0.0 publish (recreate cluster) or KIND_API_HOST." >&2
        fi
      fi
    else
      current_cluster_addr="https://${worker_name}-control-plane:6443"
      echo "Warning: could not derive Kind API URL; fallback ${current_cluster_addr}." >&2
    fi

    if [[ "${KIND_KUBECONFIG_INSECURE_SKIP_TLS_VERIFY:-}" == "true" ]]; then
      tls_extra=$'\n    insecure-skip-tls-verify: true'
      echo "Writing spoke kubeconfig with insecure-skip-tls-verify (dev only)." >&2
    fi

    echo "Creating RBAC for multikueue service account on ${worker_name}..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${multikueue_sa}
  namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${multikueue_sa}-role
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: ["kueue.x-k8s.io"]
  resources: ["workloads", "workloads/status"]
  verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns", "pipelineruns/status"]
  verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${multikueue_sa}-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${multikueue_sa}-role
subjects:
- kind: ServiceAccount
  name: ${multikueue_sa}
  namespace: ${namespace}
EOF

    local sa_secret_name
    sa_secret_name=$(kubectl get -n ${namespace} sa/${multikueue_sa} -o "jsonpath={.secrets[0]..name}")
    if [ -z "$sa_secret_name" ]; then
        kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: ${multikueue_sa}
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: "${multikueue_sa}"
EOF
        sa_secret_name=${multikueue_sa}
    fi

    local sa_token
    sa_token=$(kubectl get -n ${namespace} "secrets/${sa_secret_name}" -o "jsonpath={.data['token']}" | base64 -d)
    local ca_cert
    ca_cert=$(kubectl get -n ${namespace} "secrets/${sa_secret_name}" -o "jsonpath={.data['ca\.crt']}")
    local current_context
    current_context=$(kubectl config current-context)
    local current_cluster
    current_cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name == \"${current_context}\")].context.cluster}")

    echo "Writing kubeconfig in ${kubeconfig_out}"
    cat > "${kubeconfig_out}" <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${ca_cert}
    server: ${current_cluster_addr}${tls_extra}
  name: ${current_cluster}
contexts:
- context:
    cluster: ${current_cluster}
    user: ${current_cluster}-${multikueue_sa}
  name: ${current_context}
current-context: ${current_context}
kind: Config
preferences: {}
users:
- name: ${current_cluster}-${multikueue_sa}
  user:
    token: ${sa_token}
EOF
}

# Function to set up a spoke cluster
setup_spoke_cluster() {
  local cluserName=$1
  echo "Creating worker cluster ${cluserName}..."
  create_cluster "${cluserName}"
}

function add_spoke_to_hub() {
    local spoke=$1
    local kubeconfig_out="$TEMP_DIR/${spoke}.kubeconfig"

    local hub_context="${HUB_CONTEXT:?HUB_CONTEXT is not set; run hub (CRC) setup first}"
    echo "Adding Spoke $spoke into $hub_context"
    kubectl config use-context "${hub_context}"
    kubectl --context="${hub_context}" create secret generic "${spoke}-secret" -n kueue-system --from-file=kubeconfig=${kubeconfig_out} --dry-run=client -o yaml | kubectl apply -f -

    # Add Spoke into MultiKueueCluster Config

    # Create MultiKueueCluster
    kubectl --context="${hub_context}" apply -f - << EOF
      apiVersion: kueue.x-k8s.io/v1beta1
      kind: MultiKueueCluster
      metadata:
        name: $spoke
      spec:
        kubeConfig:
          locationType: Secret
          location: $spoke-secret
EOF


#kubectl get multikueueconfig  multikueue-test -o yaml | \
#  yq  ".spec.clusters += \"$spoke\" | .spec.clusters |=unique " | \
#  kubectl apply -f -

    kubectl --context="${hub_context}" get multikueueconfig multikueue-test -o yaml | \
      yq '.spec.clusters = (.spec.clusters // []) |
      .spec.clusters += ["'$spoke'"] |
      .spec.clusters |= unique' | \
      kubectl --context="${hub_context}" apply -f -

    kubectl --context="${hub_context}" get multikueueconfig multikueue-test -o jsonpath="{.spec}" | jq

}

function validate() {
  spokes=$1
    kubectl config use-context "${HUB_CONTEXT:?HUB_CONTEXT is not set}"
    sleep 10 # Give some time for controllers to reconcile

    kubectl get clusterqueues cluster-queue -o jsonpath="{.kind} - {'\t'}{.metadata.name} - {'\t'} {range .status.conditions[?(@.type == 'Active')]}{'CQ - Active: '}{@.status}{' Reason: '}{@.reason}{' Message: '}{@.message}{'\n'}{end}"
    kubectl get admissionchecks sample-multikueue -o jsonpath="{.kind} - {'\t'}{.metadata.name} - {'\t'} {range .status.conditions[?(@.type == 'Active')]}{'AC - Active: '}{@.status}{' Reason: '}{@.reason}{' Message: '}{@.message}{'\n'}{end}"
    for key in ${spokes[@]} ; do
      kubectl get multikueuecluster $key -o jsonpath="{.kind} - {'\t'}{.metadata.name} - {'\t'} {range .status.conditions[?(@.type == 'Active')]}{'MC - Active: '}{@.status}{' Reason: '}{@.reason}{' Message: '}{@.message}{'\n'}{end}"
    done
}

function main() {
#  docker run -d --restart=always -p "127.0.0.1:5001:5000" --name "kind-registry" registry:2
#  docker network connect "kind" "kind-registry"
  echo "Building Tekton-Kueue"

  # Setup Hub Cluster
  setup_hub_cluster "hub"
  echo "##########  Hub is Ready"
  # Setup  Spoke Clusters
  spokes=()
   for i in $(seq 1 "${NUM_WORKERS}"); do
    local cluserName="spoke-${i}"
    setup_spoke_cluster $cluserName
    add_spoke_to_hub $cluserName
    spokes+=($cluserName)
    echo "Validate Newly added spoke"
    validate $cluserName
  done

  echo "Setup complete. Verifying..."
  validate $spokes
}

main

