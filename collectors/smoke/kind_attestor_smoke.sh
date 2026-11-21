#!/usr/bin/env bash
set -euo pipefail

# Runs only in an isolated throwaway kind cluster using generated test credentials.
namespace="deplograph-attestor-smoke"
service_account="system:serviceaccount:${namespace}:deplograph-control-plane-attestor"

kubectl create namespace "${namespace}"

# Both Deployments use a single public OCI image; container names match the
# operator-approved workload contract in the attestor manifest.
kubectl -n "${namespace}" create deployment web --replicas=2 --image=registry.k8s.io/pause:3.10.1
kubectl -n "${namespace}" create deployment worker --replicas=1 --image=registry.k8s.io/pause:3.10.1
kubectl -n "${namespace}" rollout status deployment/web --timeout=180s
kubectl -n "${namespace}" rollout status deployment/worker --timeout=180s

private_key="$(mktemp)"
trap 'rm -f "${private_key}"' EXIT
openssl genpkey -algorithm ED25519 -out "${private_key}"
kubectl -n "${namespace}" create secret generic deplograph-ed25519-key \
  --from-file="private.pem=${private_key}"
kubectl -n "${namespace}" create secret generic deplograph-control-plane-credential \
  --from-literal=token=smoke-only-no-production-credential

# Deploy the real security-restricted example, substituting only the namespace,
# private/local image and observed workload image. No real Deplograph endpoint is used.
sed -e "s/namespace: production/namespace: ${namespace}/g" \
  -e 's|example.invalid/deplograph-control-plane-attestor@sha256:REPLACE_WITH_64_HEX_DIGEST|deplograph-attestor:smoke|g' \
  -e 's|ghcr.io/acme/payments|registry.k8s.io/pause|g' \
  collectors/examples/kubernetes-control-plane-attestor.yaml | kubectl apply -f -

# The smoke job uses the same executable image, runtime inventory collector,
# projected service-account credential and least-privilege RBAC, but does not
# call an external API or attempt to auto-resolve a finding.
kubectl -n "${namespace}" patch cronjob deplograph-control-plane-attestor --type=json -p='[
  {"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/command",
   "value":["ruby","/app/collectors/bin/kubernetes_control_plane_probe"]},
  {"op":"replace","path":"/spec/jobTemplate/spec/backoffLimit","value":0}
]'

[[ "$(kubectl auth can-i list pods --as="${service_account}" -n "${namespace}")" == "yes" ]]
[[ "$(kubectl auth can-i list replicasets.apps --as="${service_account}" -n "${namespace}")" == "yes" ]]
[[ "$(kubectl auth can-i get deployments.apps --as="${service_account}" -n "${namespace}")" == "yes" ]]
[[ "$(kubectl auth can-i get secrets --as="${service_account}" -n "${namespace}")" == "no" ]]
[[ "$(kubectl auth can-i create pods --as="${service_account}" -n "${namespace}")" == "no" ]]

# Kubernetes runtimes differ in imageID. An opaque config/container digest
# must NOT be promoted into a registry-manifest attestation.
image_identity="$(kubectl -n "${namespace}" get pods -l 'app in (web,worker)' -o json |
python3 -c '
import json
import re
import sys
pods = json.load(sys.stdin)["items"]
ids = [status.get("imageID", "") for pod in pods
       for status in pod.get("status", {}).get("containerStatuses", [])]
assert len(pods) == 3 and len(ids) == 3, "Expected three healthy workload containers"
manifest = r"(?:docker-pullable://)?registry\\.k8s\\.io/pause@sha256:[a-f0-9]{64}"
print("registry-manifest" if all(re.fullmatch(manifest, value) for value in ids) else "opaque")
')"

run_probe() {
  local job_name="$1"
  local outcome="$2"
  kubectl -n "${namespace}" create job "${job_name}" --from=cronjob/deplograph-control-plane-attestor
  if [[ "${outcome}" == "complete" ]]; then
    kubectl -n "${namespace}" wait --for=condition=complete "job/${job_name}" --timeout=120s
    kubectl -n "${namespace}" logs "job/${job_name}" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
assert data["complete"] is True
assert data["image_repository"] == "registry.k8s.io/pause"
assert data["observed_replicas"] == 3
assert sorted((w["name"], w["ready_replicas"]) for w in data["workloads"]) == [
    ("web", 2), ("worker", 1)
]
'
  else
    kubectl -n "${namespace}" wait --for=condition=failed "job/${job_name}" --timeout=120s
    kubectl -n "${namespace}" logs "job/${job_name}" | grep -q "probe rejected the observation"
  fi
}

if [[ "${image_identity}" == "registry-manifest" ]]; then
  echo "Live Kubernetes runtime exposed a verifiable registry manifest digest."
  run_probe attestor-healthy complete
else
  echo "Live Kubernetes runtime exposed opaque image IDs: collector must fail closed."
  run_probe attestor-opaque denied
fi

# Independently of imageID format, fail closed if a Deployment no longer
# satisfies the administrator-pinned replica-count contract.
kubectl -n "${namespace}" scale deployment/web --replicas=1
kubectl -n "${namespace}" rollout status deployment/web --timeout=120s
run_probe attestor-partial-rollout denied

echo "Kind control-plane smoke passed: RBAC, live observation and rejection gates."
