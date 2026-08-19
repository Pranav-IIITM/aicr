// Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES.  All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package chainsaw

import (
	"context"
	"testing"
	"time"

	"github.com/NVIDIA/aicr/pkg/recipe"
)

func TestK8sAIBOMHealthCheckClusterStates(t *testing.T) {
	t.Parallel()

	provider := recipe.NewEmbeddedDataProvider(recipe.GetEmbeddedFS(), "")
	data, err := provider.ReadFile(context.Background(), "checks/k8s-aibom/health-check.yaml")
	if err != nil {
		t.Fatalf("read health check: %v", err)
	}

	tests := []struct {
		name               string
		desired            int64
		available          int64
		configPresent      bool
		generation         int64
		observedGeneration int64
		readyGeneration    int64
		readyStatus        string
		wantPass           bool
	}{
		{
			name:    "healthy rollout and current Ready condition",
			desired: 1, available: 1, configPresent: true,
			generation: 2, observedGeneration: 2, readyGeneration: 2, readyStatus: "True",
			wantPass: true,
		},
		{
			name:    "zero desired replicas fails closed",
			desired: 0, available: 0, configPresent: true,
			generation: 2, observedGeneration: 2, readyGeneration: 2, readyStatus: "True",
		},
		{
			name:    "partial rollout fails closed",
			desired: 2, available: 1, configPresent: true,
			generation: 2, observedGeneration: 2, readyGeneration: 2, readyStatus: "True",
		},
		{
			name:    "missing controller config fails closed",
			desired: 1, available: 1,
		},
		{
			name:    "stale top-level status fails closed",
			desired: 1, available: 1, configPresent: true,
			generation: 2, observedGeneration: 1, readyGeneration: 2, readyStatus: "True",
		},
		{
			name:    "stale Ready condition fails closed",
			desired: 1, available: 1, configPresent: true,
			generation: 2, observedGeneration: 2, readyGeneration: 1, readyStatus: "True",
		},
		{
			name:    "Ready false fails closed",
			desired: 1, available: 1, configPresent: true,
			generation: 2, observedGeneration: 2, readyGeneration: 2, readyStatus: "False",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			fetcher := newFakeFetcher()
			fetcher.addGet("apps/v1", "Deployment", "k8s-aibom-system", "k8s-aibom", map[string]any{
				"apiVersion": "apps/v1",
				"kind":       "Deployment",
				"metadata": map[string]any{
					"name":      "k8s-aibom",
					"namespace": "k8s-aibom-system",
				},
				"spec":   map[string]any{"replicas": tt.desired},
				"status": map[string]any{"availableReplicas": tt.available},
			})
			if tt.configPresent {
				fetcher.addGet("aibom.k8saibom.dev/v1alpha1", "AIBOMControllerConfig", "", "default", map[string]any{
					"apiVersion": "aibom.k8saibom.dev/v1alpha1",
					"kind":       "AIBOMControllerConfig",
					"metadata": map[string]any{
						"name":       "default",
						"generation": tt.generation,
					},
					"status": map[string]any{
						"observedGeneration": tt.observedGeneration,
						"conditions": []any{map[string]any{
							"type":               "Ready",
							"status":             tt.readyStatus,
							"observedGeneration": tt.readyGeneration,
						}},
					},
				})
			}

			result := runChainsawTestInProcess(
				context.Background(), "k8s-aibom", string(data), 2*time.Second, fetcher,
			)
			if result.Passed != tt.wantPass {
				t.Fatalf("passed = %v, want %v (output: %s)", result.Passed, tt.wantPass, result.Output)
			}
		})
	}
}
