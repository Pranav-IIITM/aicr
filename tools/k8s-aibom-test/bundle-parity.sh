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

has_tools crane curl docker helm jq yq

AICR_BIN=${AICR_BIN:-}

QUALIFIED_IMAGE=ghcr.io/googlecloudplatform/k8s-aibom@sha256:b5040d14a20b4e890956d5f47b78445dac6c871eb5799586d9011c48ce71c198
QUALIFIED_IMAGE_DIGEST=sha256:b5040d14a20b4e890956d5f47b78445dac6c871eb5799586d9011c48ce71c198
QUALIFIED_CHART_SHA=534d05b540bf82a0d8279e342a82606be187bca9480ff25e274d4f11bae00097
REGISTRY_IMAGE=$(yq -r '.testing_tools.registry_image' "${REPO_ROOT}/.settings.yaml")
REGISTRY_CONTAINER=aicr-aibom-registry-${PPID}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aicr-aibom-bundle.XXXXXX")
WORK_DIR=$(cd "${WORK_DIR}" && pwd -P)

cleanup() {
    docker stop "${REGISTRY_CONTAINER}" >/dev/null 2>&1 || true
    if [[ "${KEEP_WORK_DIR:-false}" == "true" ]]; then
        log_warning "Keeping bundle qualification files: ${WORK_DIR}"
        return
    fi
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

find_aicr_binary() {
    if [[ -n "${AICR_BIN}" && -x "${AICR_BIN}" ]]; then
        return
    fi
    local candidate
    while IFS= read -r candidate; do
        if [[ -x "${candidate}" ]]; then
            AICR_BIN=${candidate}
            return
        fi
    done < <(find "${REPO_ROOT}/dist" -name aicr -type f 2>/dev/null)
    fail "AICR binary not found under dist/"
}

assert_values() {
    local values=$1
    yq -e '
      .image.repository == "ghcr.io/googlecloudplatform/k8s-aibom" and
      .image.digest == "sha256:b5040d14a20b4e890956d5f47b78445dac6c871eb5799586d9011c48ce71c198" and
      .readiness.strictConfig == true and
      (.config.sinks | length) == 0 and
      .rbac.sinkSecretAccess == false and
      .nodeSelector.dedicated == "aicr-system" and
      (.tolerations | length) == 1 and
      .tolerations[0].key == "dedicated" and
      .tolerations[0].value == "aicr-system" and
      .tolerations[0].effect == "NoSchedule"
    ' "${values}" >/dev/null
}

assert_scheduling_render() {
    local rendered=$1
    yq -e '
      select(.kind == "Deployment" and .metadata.name == "k8s-aibom") |
      .spec.template.spec.nodeSelector.dedicated == "aicr-system" and
      (.spec.template.spec.tolerations | length) == 1 and
      .spec.template.spec.tolerations[0].key == "dedicated" and
      .spec.template.spec.tolerations[0].value == "aicr-system" and
      .spec.template.spec.tolerations[0].effect == "NoSchedule"
    ' "${rendered}" >/dev/null
}

bundle_local() {
    local deployer=$1
    local mode=$2
    local output=${WORK_DIR}/local-${mode}-${deployer}
    local normalized_values=${WORK_DIR}/values-${mode}-${deployer}.yaml
    local render_values=${WORK_DIR}/render-values-${mode}-${deployer}.yaml
    local rendered=${WORK_DIR}/rendered-${mode}-${deployer}.yaml
    local args=(
        bundle
        --recipe "${SCRIPT_DIR}/recipe.yaml"
        --output "${output}"
        --deployer "${deployer}"
        --system-node-selector dedicated=aicr-system
        --system-node-toleration dedicated=aicr-system:NoSchedule
    )

    if [[ "${deployer}" == "argocd" || "${deployer}" == "flux" ]]; then
        args+=(--repo https://example.com/aicr-bundles.git)
    fi
    if [[ "${mode}" == "vendored" ]]; then
        args+=(--vendor-charts)
    fi
    "${AICR_BIN}" "${args[@]}" >"${WORK_DIR}/${mode}-${deployer}.log" 2>&1

    if [[ "${deployer}" == "flux" ]]; then
        if [[ "${mode}" == "vendored" ]]; then
            yq '.spec.values."k8s-aibom"' "${output}/k8s-aibom/helmrelease.yaml" >"${normalized_values}"
            yq '.spec.values' "${output}/k8s-aibom/helmrelease.yaml" >"${render_values}"
        else
            yq '.spec.values' "${output}/k8s-aibom/helmrelease.yaml" >"${normalized_values}"
            cp "${normalized_values}" "${render_values}"
        fi
    elif [[ "${mode}" == "vendored" ]]; then
        yq '."k8s-aibom"' "${output}/001-k8s-aibom/values.yaml" >"${normalized_values}"
        cp "${output}/001-k8s-aibom/values.yaml" "${render_values}"
    else
        cp "${output}/001-k8s-aibom/values.yaml" "${normalized_values}"
        cp "${normalized_values}" "${render_values}"
    fi
    assert_values "${normalized_values}"

    if [[ "${mode}" == "vendored" ]]; then
        local chart_dir=${output}/001-k8s-aibom
        if [[ "${deployer}" == "flux" ]]; then
            chart_dir=${output}/k8s-aibom
        fi
        local chart_archive
        chart_archive=$(find "${chart_dir}/charts" -maxdepth 1 -name 'k8s-aibom-1.2.0.tgz' -type f)
        [[ -n "${chart_archive}" ]] || fail "${mode}/${deployer}: vendored chart missing"
        [[ "$(sha256_file "${chart_archive}")" == "${QUALIFIED_CHART_SHA}" ]] \
            || fail "${mode}/${deployer}: vendored chart SHA-256 changed"
        helm template k8s-aibom "${chart_dir}" \
            --namespace k8s-aibom-system --include-crds \
            --values "${render_values}" >"${rendered}"
    else
        helm template k8s-aibom "${WORK_DIR}/upstream/k8s-aibom" \
            --namespace k8s-aibom-system --include-crds \
            --values "${render_values}" >"${rendered}"
    fi
    assert_scheduling_render "${rendered}"

    if [[ "${deployer}" == "helmfile" ]]; then
        yq -e '.releases[] | select(.name == "k8s-aibom") | .disableValidation == true' \
            "${output}/helmfile.yaml" >/dev/null
    fi
}

bundle_oci() {
    local deployer=$1
    local mode=$2
    local suffix=${deployer//-/_}-${mode}
    local reference=${LOCAL_REGISTRY}/aicr/k8s-aibom-${suffix}:1.0.0-qualification
    local args=(
        bundle
        --recipe "${SCRIPT_DIR}/recipe.yaml"
        --output "oci://${reference}"
        --plain-http
        --deployer "${deployer}"
        --system-node-selector dedicated=aicr-system
        --system-node-toleration dedicated=aicr-system:NoSchedule
    )
    if [[ "${mode}" == "vendored" ]]; then
        args+=(--vendor-charts)
    fi
    "${AICR_BIN}" "${args[@]}" >"${WORK_DIR}/oci-${mode}-${deployer}.log" 2>&1
    crane digest --insecure "${reference}" >/dev/null
}

find_aicr_binary
helm pull oci://ghcr.io/googlecloudplatform/charts/k8s-aibom \
    --version 1.2.0 --untar --untardir "${WORK_DIR}/upstream" >/dev/null

for mode in upstream vendored; do
    for deployer in helm helmfile argocd argocd-helm flux; do
        bundle_local "${deployer}" "${mode}"
    done
done

docker run --detach --rm \
    --name "${REGISTRY_CONTAINER}" \
    --publish 127.0.0.1::5000 \
    "${REGISTRY_IMAGE}" >/dev/null
registry_port=$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' \
    "${REGISTRY_CONTAINER}")
LOCAL_REGISTRY=127.0.0.1:${registry_port}
for _ in $(seq 1 30); do
    if curl --fail --silent --show-error --connect-timeout 2 --max-time 3 \
        "http://${LOCAL_REGISTRY}/v2/" >/dev/null; then
        break
    fi
    sleep 1
done
curl --fail --silent --show-error --connect-timeout 2 --max-time 3 \
    "http://${LOCAL_REGISTRY}/v2/" >/dev/null \
    || fail "local OCI registry did not become ready"

for mode in upstream vendored; do
    for deployer in helm helmfile argocd argocd-helm flux; do
        bundle_oci "${deployer}" "${mode}"
    done
done

"${AICR_BIN}" mirror list --recipe "${SCRIPT_DIR}/recipe.yaml" --format json \
    >"${WORK_DIR}/mirror.json" 2>"${WORK_DIR}/mirror.log"
jq -e --arg image "${QUALIFIED_IMAGE}" \
    '.images == [$image] and
     (.components | length) == 1 and
     .components[0].component == "k8s-aibom" and
     .components[0].type == "helm" and
     .components[0].images == [$image]' \
    "${WORK_DIR}/mirror.json" >/dev/null

mirror_reference=${LOCAL_REGISTRY}/mirror/k8s-aibom:qualified
crane copy --insecure "${QUALIFIED_IMAGE}" "${mirror_reference}" \
    >"${WORK_DIR}/mirror-copy.log" 2>&1
mirrored_digest=$(crane digest --insecure "${mirror_reference}")
[[ "${mirrored_digest}" == "${QUALIFIED_IMAGE_DIGEST}" ]] \
    || fail "mirrored image digest changed: got ${mirrored_digest}, want ${QUALIFIED_IMAGE_DIGEST}"

printf 'PASS deployers=5 modes=upstream,vendored outputs=local,oci image=%s\n' \
    "${QUALIFIED_IMAGE_DIGEST}"
