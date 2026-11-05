#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -Eeuo pipefail

trap exit SIGINT SIGTERM

################################################################################
# AKS Automatic -> transit NVA -> vWAN hub -> Nexus: end-to-end test
#
# Proves, for one environment:
#   1. routing      the hub gives the transit VNet a route to Nexus, gives the
#                   Nexus spoke a route back to the transit /28, and NEVER
#                   learns the (reused, non-routable) AKS range.
#   2. nva          every NVA instance behind the ILB is healthy.
#   3. ca-trust     the private root CA is in the cluster's securityProfile.
#   4. pod-pull     a pod reaches Nexus over TLS (private CA), pushes and pulls.
#   5. kubelet-pull containerd pulls from Nexus using node-level CA trust.
#                   NAP nodes created before CA trust was set are not reimaged;
#                   with RECYCLE_NODES=true their NodeClaims are deleted and the
#                   pull is retried on fresh nodes.
#
# Everything else is read from `terraform output` in TF_DIR.

################################################################################
# Default configuration
TF_DIR=${TF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
ENV_NAME=${ENV_NAME:-dev}
KUBECONFIG=${KUBECONFIG:-${TF_DIR}/.kubeconfig-${ENV_NAME}}
NAMESPACE=${NAMESPACE:-default}
RECYCLE_NODES=${RECYCLE_NODES:-true}
POD_TIMEOUT=${POD_TIMEOUT:-900}
AKS_API_VERSION=${AKS_API_VERSION:-2026-07-01}
################################################################################
export KUBECONFIG

__usage="
    -x  action to be executed.

Possible verbs are:
    all            Run every test below in order.
    check-deps     Check required tools.
    setup          Fetch credentials; create nexus-cred, nexus-pull, nexus-ca.
    routing        Assert hub effective routes (Nexus in, AKS range never out).
    nva            Assert all NVA backends are healthy (ILB DipAvailability).
    ca-trust       Assert the private CA is set in securityProfile.
    pod-pull       Run the crane Job (TLS with private CA, push + pull, MB/s).
    kubelet-pull   Pull from Nexus via kubelet/containerd (node CA trust).
    recycle-nodes  Delete all NAP NodeClaims so NAP provisions fresh nodes.
    cleanup        Delete the test Job/Pod (secrets and configmap are kept).

Environment variables (with defaults):
    TF_DIR=${TF_DIR}
    ENV_NAME=${ENV_NAME}
    KUBECONFIG=${KUBECONFIG}
    NAMESPACE=${NAMESPACE}
    RECYCLE_NODES=${RECYCLE_NODES}
    POD_TIMEOUT=${POD_TIMEOUT}
    AKS_API_VERSION=${AKS_API_VERSION}
"

usage() {
  echo "usage: ${0##*/} [options]"
  echo "${__usage/[[:space:]]/}"
  exit 1
}

print_header() {
  echo ""
  echo "AKS Automatic -> vWAN -> Nexus E2E test"
  echo "=========================================="
  echo ""
  echo "Terraform dir:   $TF_DIR"
  echo "Environment:     $ENV_NAME"
  echo "Kubeconfig:      $KUBECONFIG"
  echo "Recycle nodes:   $RECYCLE_NODES"
  echo ""
}

log() {
  echo "[$(date +"%r")] $*"
}

fail() {
  log "FAIL: $*"
  exit 1
}

check_dependencies() {
  log "Checking dependencies..."
  local _NEEDED="az terraform kubectl kubelogin jq"
  local _DEP_FLAG=false

  for i in ${_NEEDED}; do
    if hash "$i" 2>/dev/null; then
      log "  $i: OK"
    else
      log "  $i: NOT FOUND"
      _DEP_FLAG=true
    fi
  done

  if [[ "${_DEP_FLAG}" == "true" ]]; then
    log "Dependencies missing. Please install them before proceeding"
    exit 1
  fi

  log "All dependencies satisfied"
}

tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

load_outputs() {
  local _env_json

  RESOURCE_GROUP=$(tf_out resource_group_name)
  HUB_ID=$(tf_out virtual_hub_id)
  NEXUS_CIDR=$(tf_out nexus_cidr)
  NEXUS_REGISTRY=$(tf_out nexus_registry)
  CA_FILE=$(tf_out ca_cert_file)
  _env_json=$(terraform -chdir="$TF_DIR" output -json environments | jq -e --arg e "$ENV_NAME" '.[$e]') ||
    fail "environment '$ENV_NAME' not found in terraform output"
  CLUSTER_NAME=$(jq -r .cluster_name <<<"$_env_json")
  TRANSIT_CIDR=$(jq -r .transit_cidr <<<"$_env_json")
  AKS_CIDR=$(jq -r .aks_internal_cidr <<<"$_env_json")
  # Relative paths in outputs are relative to TF_DIR.
  case "$CA_FILE" in
    /*) ;;
    *) CA_FILE="${TF_DIR}/${CA_FILE#./}" ;;
  esac
}

# Prefixes the hub programs for a hub VNet connection, one per line.
hub_routes() {
  local _conn=$1
  local _hub_rg _hub_name _conn_id

  _hub_rg=$(cut -d/ -f5 <<<"$HUB_ID")
  _hub_name=${HUB_ID##*/}
  _conn_id=$(az network vhub connection show -g "$_hub_rg" --vhub-name "$_hub_name" -n "$_conn" --query id -o tsv)
  az network vhub get-effective-routes -g "$_hub_rg" -n "$_hub_name" \
    --resource-type HubVirtualNetworkConnection --resource-id "$_conn_id" \
    --query 'value[].addressPrefixes[]' -o tsv 2>/dev/null
}

do_setup() {
  load_outputs
  log "Fetching credentials for $CLUSTER_NAME into $KUBECONFIG"
  (umask 077 && : >>"$KUBECONFIG")
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --file "$KUBECONFIG" --overwrite-existing -o none
  kubelogin convert-kubeconfig -l azurecli

  # The Nexus password only travels through pipes, never argv.
  log "Creating secret nexus-cred, dockerconfigjson secret nexus-pull, configmap nexus-ca"
  tf_out nexus_admin_password |
    kubectl -n "$NAMESPACE" create secret generic nexus-cred --from-file=password=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  tf_out nexus_admin_password |
    jq -Rr --arg r "$NEXUS_REGISTRY" \
      '{auths: {($r): {username: "admin", password: ., auth: ("admin:" + . | @base64)}}}' |
    kubectl -n "$NAMESPACE" create secret generic nexus-pull --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NAMESPACE" create configmap nexus-ca --from-file=ca.crt="$CA_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "Setup completed"
}

do_routing() {
  load_outputs
  local _transit_routes _nexus_routes

  _transit_routes=$(hub_routes "conn-${ENV_NAME}-transit")
  log "Hub routes on conn-${ENV_NAME}-transit: $(tr '\n' ' ' <<<"$_transit_routes")"
  grep -qxF "$NEXUS_CIDR" <<<"$_transit_routes" || fail "transit VNet has no hub route to Nexus $NEXUS_CIDR"

  _nexus_routes=$(hub_routes conn-shared-nexus)
  log "Hub routes on conn-shared-nexus: $(tr '\n' ' ' <<<"$_nexus_routes")"
  grep -qxF "$TRANSIT_CIDR" <<<"$_nexus_routes" || fail "Nexus spoke has no route back to transit $TRANSIT_CIDR"

  if printf '%s\n%s\n' "$_transit_routes" "$_nexus_routes" | grep -qxF "$AKS_CIDR"; then
    fail "AKS range $AKS_CIDR leaked into the hub"
  fi
  log "PASS routing: Nexus reachable via the hub; $AKS_CIDR never advertised"
}

do_nva() {
  load_outputs
  local _lb_id _avail

  _lb_id=$(az network lb show -g "$RESOURCE_GROUP" -n "ilb-${ENV_NAME}-nva" --query id -o tsv)
  # data[-2] is the last complete minute; the current minute is partial.
  _avail=$(az monitor metrics list --resource "$_lb_id" --metric DipAvailability --interval PT1M \
    --aggregation Average --offset 10m --query 'value[0].timeseries[0].data[-2].average' -o tsv)
  log "ILB backend health (DipAvailability, last full minute): ${_avail:-n/a}%"
  [[ "${_avail%.*}" == "100" ]] || fail "not all NVA instances are healthy"
  log "PASS nva: all NVA backends healthy"
}

do_ca_trust() {
  load_outputs
  local _set _want _sub

  _sub=$(az account show --query id -o tsv)
  _want=$(base64 <"$CA_FILE" | tr -d '\n')
  _set=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${_sub}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerService/managedClusters/${CLUSTER_NAME}?api-version=${AKS_API_VERSION}" \
    --query 'properties.securityProfile.customCATrustCertificates' -o json)
  jq -e --arg w "$_want" 'index($w) != null' <<<"$_set" >/dev/null ||
    fail "private CA is not in securityProfile.customCATrustCertificates"
  log "PASS ca-trust: private CA present in securityProfile.customCATrustCertificates"
}

do_pod_pull() {
  log "Running Job nexus-pull-test (crane, TLS verified with nexus-ca)"
  kubectl -n "$NAMESPACE" delete job nexus-pull-test --ignore-not-found --wait=true >/dev/null
  kubectl apply -f "${TF_DIR}/k8s/nexus-pull-test.yaml" 2>&1 | grep -v '^Warning:' || true
  if ! kubectl -n "$NAMESPACE" wait --for=condition=complete job/nexus-pull-test --timeout="${POD_TIMEOUT}s"; then
    kubectl -n "$NAMESPACE" logs job/nexus-pull-test --tail=30 || true
    fail "nexus-pull-test did not complete"
  fi
  kubectl -n "$NAMESPACE" logs job/nexus-pull-test | grep -E '^(Node IP|Pulled|SUCCESS)' |
    while read -r l; do log "  $l"; done
  log "PASS pod-pull"
}

# Succeeded, Running, X509, or the current waiting reason of the CURRENT pod.
# Reads pod status (not events) so results from earlier pods can't leak in.
kubelet_pod_state() {
  local _json
  _json=$(kubectl -n "$NAMESPACE" get pod kubelet-pull-test -o json 2>/dev/null) || {
    echo Missing
    return
  }
  jq -r '
    (.status.containerStatuses[0].state.waiting // {}) as $w
    | if ($w.message // "" | test("x509")) then "X509"
      elif .status.phase == "Succeeded" or .status.phase == "Running" then .status.phase
      else ($w.reason // .status.phase) end' <<<"$_json"
}

# Sets KUBELET_STATE.
run_kubelet_pod() {
  local _deadline _node

  kubectl -n "$NAMESPACE" delete pod kubelet-pull-test --ignore-not-found --wait=true >/dev/null
  kubectl apply -f "${TF_DIR}/k8s/kubelet-pull-test.yaml" 2>&1 | grep -v '^Warning:' || true
  _deadline=$((SECONDS + POD_TIMEOUT))
  KUBELET_STATE=Pending
  while ((SECONDS < _deadline)); do
    KUBELET_STATE=$(kubelet_pod_state)
    case "$KUBELET_STATE" in
      Succeeded | Running | X509) break ;;
    esac
    sleep 10
  done
  _node=$(kubectl -n "$NAMESPACE" get pod kubelet-pull-test -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  log "  pod state: $KUBELET_STATE (node: ${_node:-unscheduled})"
}

do_recycle_nodes() {
  log "Deleting NAP NodeClaims (graceful drain; NAP provisions replacements with the current node config)"
  kubectl get nodeclaims --no-headers \
    -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels.karpenter\\.sh/nodepool,CREATED:.metadata.creationTimestamp |
    while read -r l; do log "  $l"; done
  kubectl delete nodeclaims --all --wait=true
  log "NodeClaims recycled"
}

do_kubelet_pull() {
  log "Kubelet pull: $(awk '/image:/ {print $2; exit}' "${TF_DIR}/k8s/kubelet-pull-test.yaml")"
  run_kubelet_pod
  if [[ "$KUBELET_STATE" == "X509" && "$RECYCLE_NODES" == "true" ]]; then
    log "  x509 on a node that predates CA trust; recycling NAP nodes and retrying"
    do_recycle_nodes
    run_kubelet_pod
  fi

  case "$KUBELET_STATE" in
    Succeeded | Running)
      kubectl -n "$NAMESPACE" get events --field-selector involvedObject.name=kubelet-pull-test,reason=Pulled \
        -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1 | while read -r l; do log "  $l"; done
      log "PASS kubelet-pull"
      ;;
    X509) fail "kubelet rejects the Nexus certificate (x509). Check ca-trust; rerun with RECYCLE_NODES=true." ;;
    *) fail "kubelet-pull-test ended in state '$KUBELET_STATE'" ;;
  esac
}

do_cleanup() {
  kubectl -n "$NAMESPACE" delete job nexus-pull-test --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" delete pod kubelet-pull-test --ignore-not-found >/dev/null
  log "Test workloads deleted"
}

do_all() {
  check_dependencies
  do_setup
  do_routing
  do_nva
  do_ca_trust
  do_pod_pull
  do_kubelet_pull
  log ""
  log "ALL TESTS PASSED for $ENV_NAME"
}

exec_case() {
  local _opt=$1

  case ${_opt} in
    all) do_all ;;
    check-deps) check_dependencies ;;
    setup) do_setup ;;
    routing) do_routing ;;
    nva) do_nva ;;
    ca-trust) do_ca_trust ;;
    pod-pull) do_pod_pull ;;
    kubelet-pull) do_kubelet_pull ;;
    recycle-nodes) do_recycle_nodes ;;
    cleanup) do_cleanup ;;
    *) usage ;;
  esac
  unset _opt
}

################################################################################
# Entry point
main() {
  local exec_flag=false

  while getopts "x:" opt; do
    case $opt in
      x)
        exec_flag=true
        EXEC_OPT="${OPTARG}"
        ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ $OPTIND = 1 ]; then
    print_header
    usage
  fi

  if [[ "${exec_flag}" == "true" ]]; then
    print_header
    exec_case "${EXEC_OPT}"
  fi
}

main "$@"
exit 0
