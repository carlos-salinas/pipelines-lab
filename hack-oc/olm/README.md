# OLM installs for CRC / OpenShift hub

Installs Red Hat operators from the built-in `redhat-operators` catalog (CRC already has OLM and the catalog).

| Component | Package | Namespace | Notes |
| --------- | ------- | --------- | ----- |
| cert-manager | `openshift-cert-manager-operator` | `cert-manager-operator` | Requires `CertManager` CR; operand runs in `cert-manager` |
| OpenShift Pipelines | `openshift-pipelines-operator-rh` | `openshift-operators` | Workloads in `openshift-pipelines` |
| Kueue | `kueue-operator` | `openshift-kueue-operator` | Requires cert-manager; needs `Kueue` CR named `cluster` |

## Make targets

All OLM install logic lives in the repo `Makefile` (not a separate shell script).

```bash
make olm-deps-crc              # full hub stack (used by hack-oc/01-setup-multikueue.sh)
make olm-cert-manager          # cert-manager operator + operand
make olm-openshift-pipelines   # operator + SCC + wait for TektonConfig Ready
make olm-tekton-scc            # privileged SCC only (also run from olm-openshift-pipelines)
make olm-wait-tektonconfig     # wait for TektonConfig/config Ready (progress logs)
make olm-kueue                 # Kueue operator + Kueue CR (requires cert-manager first)
```

Override subscription channels if your CRC version differs:

```bash
make olm-openshift-pipelines OLM_PIPELINES_CHANNEL=pipelines-1.23
make olm-kueue OLM_KUEUE_CHANNEL=stable-v1.3
make olm-cert-manager OLM_CERT_MANAGER_CHANNEL=stable-v1
```

Discover channels:

```bash
oc get packagemanifest openshift-pipelines-operator-rh -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
oc get packagemanifest kueue-operator -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
```

## Multikueue setup script

`hack-oc/01-setup-multikueue.sh` uses OLM on the CRC hub by default (`HUB_DEPS_INSTALL=olm`).
Kind spokes still use OSS manifests (`make kueue tekton cert-manager`).

Makefile targets (from repo root):

```bash
make provision              # hub + spokes (NUM_WORKERS=1 default)
make provision-hub          # CRC hub only
make provision-spokes       # Kind spokes + hub registration (hub must exist)
make provision-spokes NUM_WORKERS=2
```

To use upstream YAML on the hub instead:

```bash
make provision HUB_DEPS_INSTALL=oss
```

## Troubleshooting (CRC)

**`still waiting: state=<none>` / `ResolutionFailed: connection refused` on fresh CRC**

Subscriptions were created before the **redhat-operators** catalog gRPC was listening (pod can be `1/1 Running` while port `50051` is not ready yet). OLM caches `ResolutionFailed` with a stale pod IP.

The Makefile now:
1. Waits for the **redhat-operators** catalog pod (not only community/certified catalogs)
2. Waits until **packagemanifest** API works (3 successful polls)
3. **Recreates** the subscription automatically when `ResolutionFailed` clears

### CRC registry authentication

OLM catalog pods pull `registry.redhat.io/redhat/redhat-operator-index:v4.x`. On a clean CRC you will see:

```text
Init:ImagePullBackOff
unauthorized: Please login to the Red Hat Registry using your Customer Portal credentials
```

Until this is fixed, **no Red Hat operator** (cert-manager, Pipelines, Kueue) can install.

```bash
# 1) Log in on the host (Customer Portal → Registry Service Accounts, or your RH account)
podman login registry.redhat.io

# 2) Restart CRC so the cluster pull-secret is refreshed from your local auth (or merge manually)
crc stop
crc start

# 3) Verify catalog pod
oc get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators
# READY 1/1, STATUS Running

# 4) Continue OLM install
make olm-wait-marketplace
make olm-deps-crc
```

If the pod pulls after several minutes without login, auth was eventually satisfied — still run `make olm-wait-marketplace` before subscriptions so gRPC is ready.

Manual fix on a stuck run:

```bash
oc delete subscription openshift-cert-manager-operator -n cert-manager-operator
make olm-wait-marketplace
make olm-cert-manager
```

**`no operators found in channel stable-v1.0 of package kueue-operator`**

CRC 4.21 catalogs expose **`stable-v1.2`** and **`stable-v1.3`** (default), not `stable-v1.0`. The Makefile now picks `defaultChannel` automatically; fix a stuck subscription:

```bash
oc delete subscription kueue-operator -n openshift-kueue-operator
make olm-kueue
# or: make olm-kueue OLM_KUEUE_CHANNEL=stable-v1.3
```

**Stuck on “Waiting for OpenShift Pipelines workloads”**

The old Makefile waited on every Deployment in `openshift-pipelines`, including optional components that may never become Available. It now waits on `TektonConfig/config` Ready (with progress logs) and grants SCC before that wait.

**Hub previously installed OSS Tekton (`tekton-pipelines` namespace)**

Do not mix OSS `make tekton` on the hub with `HUB_DEPS_INSTALL=olm`. Remove the old namespace before re-running:

```bash
oc delete namespace tekton-pipelines --wait=false
make olm-openshift-pipelines OLM_PIPELINES_CHANNEL=pipelines-1.22
```

**Channel `latest` on CRC**

CRC’s packagemanifest default is often `latest`. The Makefile pins `OLM_PIPELINES_CHANNEL=pipelines-1.22` by default.

**No space on Podman machine** (`no space left on device`, `make docker-build` / `podman push` fails)

CRC and `make provision*` image builds use the **Podman machine** VM on macOS. When its disk is full:

```bash
podman machine start
podman system df
podman system prune -a
podman builder prune -a
```

Re-check with `podman system df`, then retry your build (`make docker-build`, `make provision-hub`, etc.).

If still full, recreate the machine (removes all images/containers in the VM):

```bash
podman machine stop
podman machine rm
podman machine init
podman machine start
```
