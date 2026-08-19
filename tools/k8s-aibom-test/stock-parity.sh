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

has_tools git go jq

BASE_REF=${BASE_REF:-$(git -C "${REPO_ROOT}" merge-base HEAD origin/main)}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aicr-aibom-stock-parity.XXXXXX")
WORK_DIR=$(cd "${WORK_DIR}" && pwd -P)
BASE_DIR=${WORK_DIR}/base
BASE_OUTPUT=${WORK_DIR}/base-output
CURRENT_OUTPUT=${WORK_DIR}/current-output

cleanup() {
    if [[ -d "${BASE_DIR}" ]]; then
        git -C "${REPO_ROOT}" worktree remove --force "${BASE_DIR}"
    fi
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf -- "${WORK_DIR}"
    fi
}
trap cleanup EXIT

generate_recipes() {
    local binary=$1
    local output=$2
    local name service accelerator intent os_name platform

    mkdir -p "${output}/recipes" "${output}/bundles"
    "${binary}" recipe list --format json --no-health >"${output}/catalog.json"

    while IFS='|' read -r name service accelerator intent os_name platform; do
        local args=(recipe --output "${output}/recipes/${name}.yaml")
        local has_coordinate=false
        if [[ -n "${service}" && "${service}" != "any" ]]; then
            args+=(--service "${service}")
            has_coordinate=true
        fi
        if [[ -n "${accelerator}" && "${accelerator}" != "any" ]]; then
            args+=(--accelerator "${accelerator}")
            has_coordinate=true
        fi
        if [[ -n "${intent}" && "${intent}" != "any" ]]; then
            args+=(--intent "${intent}")
            has_coordinate=true
        fi
        if [[ -n "${os_name}" && "${os_name}" != "any" ]]; then
            args+=(--os "${os_name}")
            has_coordinate=true
        fi
        if [[ -n "${platform}" && "${platform}" != "any" ]]; then
            args+=(--platform "${platform}")
            has_coordinate=true
        fi
        if [[ "${has_coordinate}" == "true" ]]; then
            if ! "${binary}" "${args[@]}" >>"${output}/generation.log" 2>&1; then
                cat "${output}/generation.log" >&2
                log_error "failed to resolve stock recipe ${name}"
                return 1
            fi
            if ! "${binary}" bundle \
                --recipe "${output}/recipes/${name}.yaml" \
                --output "${output}/bundles/${name}" \
                --deployer helm \
                --accelerated-node-selector nvidia.com/gpu.present=true \
                --accelerated-node-toleration nvidia.com/gpu=present:NoSchedule \
                --workload-selector aicr.nvidia.com/parity-test=true \
                --storage-class aicr-parity-rwo \
                --shared-storage-class aicr-parity-rwx \
                --nodes 3 >>"${output}/generation.log" 2>&1; then
                cat "${output}/generation.log" >&2
                log_error "failed to render stock bundle ${name}"
                return 1
            fi
        fi
    done < <(jq -r '
      .[]
      | [.name,
         (.criteria.Service // ""),
         (.criteria.Accelerator // ""),
         (.criteria.Intent // ""),
         (.criteria.OS // ""),
         (.criteria.Platform // "")]
      | join("|")
    ' "${output}/catalog.json")
}

git -C "${REPO_ROOT}" worktree add --detach "${BASE_DIR}" "${BASE_REF}"
(
    cd "${BASE_DIR}"
    GOFLAGS='-mod=vendor' go build -o "${WORK_DIR}/base-aicr" ./cmd/aicr
)
(
    cd "${REPO_ROOT}"
    GOFLAGS='-mod=vendor' go build -o "${WORK_DIR}/current-aicr" ./cmd/aicr
)

generate_recipes "${WORK_DIR}/base-aicr" "${BASE_OUTPUT}"
generate_recipes "${WORK_DIR}/current-aicr" "${CURRENT_OUTPUT}"

cmp "${BASE_OUTPUT}/catalog.json" "${CURRENT_OUTPUT}/catalog.json"
diff -ru "${BASE_OUTPUT}/recipes" "${CURRENT_OUTPUT}/recipes"
diff -ru "${BASE_OUTPUT}/bundles" "${CURRENT_OUTPUT}/bundles"

catalog_count=$(jq 'length' "${CURRENT_OUTPUT}/catalog.json")
recipe_count=$(find "${CURRENT_OUTPUT}/recipes" -type f -name '*.yaml' | wc -l | tr -d ' ')
bundle_count=$(find "${CURRENT_OUTPUT}/bundles" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
printf 'PASS base=%s catalog_overlays=%s resolved_recipes=%s rendered_bundles=%s\n' \
    "$(git -C "${BASE_DIR}" rev-parse HEAD)" "${catalog_count}" "${recipe_count}" "${bundle_count}"
