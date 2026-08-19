#!/usr/bin/env bash
# Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

# shellcheck source=../common
. "${REPO_ROOT}/tools/common"

has_tools curl go helm jq kind kubectl yq chainsaw

NODE_IMAGE=$(yq -r '.testing.kind_node_image' "${REPO_ROOT}/.settings.yaml")
CLUSTER_NAME=${CLUSTER_NAME:-aicr-aibom-${PPID}}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aicr-aibom-kind.XXXXXX")
OUTPUT_DIR=${OUTPUT_DIR:-${WORK_DIR}/evidence}
SCHEMA_DIR=${WORK_DIR}/schemas
export KUBECONFIG=${WORK_DIR}/kubeconfig

cleanup() {
    if [[ "${KEEP_CLUSTER:-false}" == "true" ]]; then
        log_warning "Keeping cluster ${CLUSTER_NAME}; kubeconfig: ${KUBECONFIG}"
        return
    fi
    kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf -- "${WORK_DIR}"
    fi
}
trap cleanup EXIT

fail() {
    log_error "$*"
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

download_schema() {
    local name=$1
    local expected=$2
    local source="https://raw.githubusercontent.com/CycloneDX/specification/1.6.1/schema/${name}"
    local destination="${SCHEMA_DIR}/${name}"

    curl --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 60 --retry 3 \
        --proto '=https' --tlsv1.2 \
        --output "${destination}" "${source}"
    local actual
    actual=$(sha256_file "${destination}")
    [[ "${actual}" == "${expected}" ]] || \
        fail "schema ${name} SHA-256 mismatch: got ${actual}, want ${expected}"
}

wait_for_ready_aibom() {
    local name=$1
    local _
    for _ in $(seq 1 180); do
        if kubectl -n aicr-aibom-test get "aibom/${name}" -o json 2>/dev/null \
            | jq -e '.status.conditions[]? | select(.type == "Ready" and .status == "True")' >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_observed_generation() {
    local name=$1
    local target=$2
    local _ observed
    for _ in $(seq 1 120); do
        observed=$(kubectl -n aicr-aibom-test get "aibom/${name}" \
            -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
        if [[ "${observed}" == "${target}" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

decode_base64() {
    if base64 --decode </dev/null >/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

validate_bom() {
    GOFLAGS='-mod=vendor' go run "${SCRIPT_DIR}/validator" "${SCHEMA_DIR}" "$1"
}

mkdir -p "${OUTPUT_DIR}" "${SCHEMA_DIR}"
download_schema bom-1.6.schema.json efc54d749e32a6e16abd19394b80b4c67d846e12c782e04505130375f94ea541
download_schema spdx.schema.json c41917196639055e9f9670811bac23ef777732144f3ff5a2f39686f61580dbe6
download_schema jsf-0.82.schema.json 8bae002c25e723db7ee1f26afde680ae1a2b1a8f6b4b4b0fd65dc3becb090aae

kind create cluster \
    --name "${CLUSTER_NAME}" \
    --image "${NODE_IMAGE}" \
    --kubeconfig "${KUBECONFIG}" \
    --wait 120s

kubectl version -o json >"${OUTPUT_DIR}/kubernetes-version.json"
COMPONENT=k8s-aibom bash "${REPO_ROOT}/tools/component-test/deploy-component.sh"
COMPONENT=k8s-aibom bash "${REPO_ROOT}/tools/component-test/run-health-check.sh"

helm get metadata k8s-aibom -n k8s-aibom-system -o json >"${OUTPUT_DIR}/helm-metadata.json"
kubectl apply -f "${SCRIPT_DIR}/workload-v1.yaml"

aibom_name=apps-deployment-aicr-aibom-fixture
wait_for_ready_aibom "${aibom_name}" || fail "initial AIBOM did not become Ready"

deployment_uid=$(kubectl -n aicr-aibom-test get deployment/aicr-aibom-fixture \
    -o jsonpath='{.metadata.uid}')
kubectl -n aicr-aibom-test get "aibom/${aibom_name}" -o json >"${OUTPUT_DIR}/aibom-v1.json"
jq -e --arg uid "${deployment_uid}" \
    '.metadata.ownerReferences | any(.uid == $uid and .controller == true)' \
    "${OUTPUT_DIR}/aibom-v1.json" >/dev/null \
    || fail "AIBOM controller ownerReference does not match the Deployment"
jq -e '
  .status.bomDocument.format == "CycloneDX" and
  .status.bomDocument.specVersion == "1.6" and
  .status.bomDocument.inline.data != null and
  .status.summary.workload.kind == "Deployment" and
  .status.summary.runtime.name == "triton"
' "${OUTPUT_DIR}/aibom-v1.json" >/dev/null \
    || fail "initial AIBOM status contract failed"

jq -r '.status.bomDocument.inline.data' "${OUTPUT_DIR}/aibom-v1.json" \
    | decode_base64 >"${OUTPUT_DIR}/bom-v1.json"
expected_sha=$(jq -r '.status.bomDocument.sha256' "${OUTPUT_DIR}/aibom-v1.json")
actual_sha=$(sha256_file "${OUTPUT_DIR}/bom-v1.json")
[[ "${actual_sha}" == "${expected_sha}" ]] \
    || fail "initial canonical BOM SHA mismatch: got ${actual_sha}, want ${expected_sha}"
validate_bom "${OUTPUT_DIR}/bom-v1.json"
input_hash_v1=$(jq -r '.status.inputHash' "${OUTPUT_DIR}/aibom-v1.json")

kubectl -n aicr-aibom-test patch deployment/aicr-aibom-fixture --type merge \
    -p '{"spec":{"template":{"metadata":{"annotations":{"aicr.nvidia.com/test-reconcile":"cosmetic"}}}}}'
cosmetic_generation=$(kubectl -n aicr-aibom-test get deployment/aicr-aibom-fixture \
    -o jsonpath='{.metadata.generation}')
wait_for_observed_generation "${aibom_name}" "${cosmetic_generation}" \
    || fail "AIBOM did not observe cosmetic workload generation ${cosmetic_generation}"
kubectl -n aicr-aibom-test get "aibom/${aibom_name}" -o json >"${OUTPUT_DIR}/aibom-cosmetic.json"
input_hash_cosmetic=$(jq -r '.status.inputHash' "${OUTPUT_DIR}/aibom-cosmetic.json")
[[ "${input_hash_cosmetic}" == "${input_hash_v1}" ]] \
    || fail "cosmetic workload change altered inputHash"

kubectl apply -f "${SCRIPT_DIR}/workload-v2.yaml"
relevant_generation=$(kubectl -n aicr-aibom-test get deployment/aicr-aibom-fixture \
    -o jsonpath='{.metadata.generation}')
wait_for_observed_generation "${aibom_name}" "${relevant_generation}" \
    || fail "AIBOM did not observe relevant workload generation ${relevant_generation}"
wait_for_ready_aibom "${aibom_name}" || fail "updated AIBOM did not become Ready"
kubectl -n aicr-aibom-test get "aibom/${aibom_name}" -o json >"${OUTPUT_DIR}/aibom-v2.json"
input_hash_v2=$(jq -r '.status.inputHash' "${OUTPUT_DIR}/aibom-v2.json")
[[ "${input_hash_v2}" != "${input_hash_v1}" ]] \
    || fail "digest-pinned image update did not alter inputHash"

jq -r '.status.bomDocument.inline.data' "${OUTPUT_DIR}/aibom-v2.json" \
    | decode_base64 >"${OUTPUT_DIR}/bom-v2.json"
expected_sha=$(jq -r '.status.bomDocument.sha256' "${OUTPUT_DIR}/aibom-v2.json")
actual_sha=$(sha256_file "${OUTPUT_DIR}/bom-v2.json")
[[ "${actual_sha}" == "${expected_sha}" ]] \
    || fail "updated canonical BOM SHA mismatch: got ${actual_sha}, want ${expected_sha}"
validate_bom "${OUTPUT_DIR}/bom-v2.json"

kubectl -n aicr-aibom-test delete deployment/aicr-aibom-fixture --wait=true
kubectl -n aicr-aibom-test wait --for=delete "aibom/${aibom_name}" --timeout=120s

{
    printf 'PASS\n'
    printf 'node_image=%s\n' "${NODE_IMAGE}"
    printf 'input_hash_v1=%s\n' "${input_hash_v1}"
    printf 'input_hash_cosmetic=%s\n' "${input_hash_cosmetic}"
    printf 'input_hash_v2=%s\n' "${input_hash_v2}"
} | tee "${OUTPUT_DIR}/result.txt"
