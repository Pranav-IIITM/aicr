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

package main

import (
	"bytes"
	stderrors "errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	projecterrors "github.com/NVIDIA/aicr/pkg/errors"
)

func TestRun(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	schemas := map[string]string{
		"bom-1.6.schema.json": `{
  "$id": "http://cyclonedx.org/schema/bom-1.6.schema.json",
  "type": "object",
  "required": ["bomFormat", "specVersion"],
  "properties": {
    "bomFormat": {"const": "CycloneDX"},
    "specVersion": {"const": "1.6"}
  }
}`,
		"spdx.schema.json": `{
  "$id": "http://cyclonedx.org/schema/spdx.schema.json",
  "type": "object"
}`,
		"jsf-0.82.schema.json": `{
  "$id": "http://cyclonedx.org/schema/jsf-0.82.schema.json",
  "type": "object"
}`,
	}
	for name, content := range schemas {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
			t.Fatalf("write schema %s: %v", name, err)
		}
	}

	tests := []struct {
		name      string
		bom       string
		wantError bool
	}{
		{name: "valid", bom: `{"bomFormat":"CycloneDX","specVersion":"1.6"}`},
		{name: "wrong spec version", bom: `{"bomFormat":"CycloneDX","specVersion":"1.5"}`, wantError: true},
		{name: "invalid JSON", bom: `{`, wantError: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			bomPath := filepath.Join(t.TempDir(), "bom.json")
			if err := os.WriteFile(bomPath, []byte(tt.bom), 0o600); err != nil {
				t.Fatalf("write BOM: %v", err)
			}
			var output bytes.Buffer
			err := run([]string{dir, bomPath}, &output)
			if (err != nil) != tt.wantError {
				t.Fatalf("run() error = %v, wantError %v", err, tt.wantError)
			}
			if !tt.wantError && !strings.Contains(output.String(), "CycloneDX 1.6") {
				t.Errorf("run() output = %q", output.String())
			}
		})
	}
}

func TestRunRequiresPaths(t *testing.T) {
	t.Parallel()

	err := run(nil, &bytes.Buffer{})
	if !stderrors.Is(err, projecterrors.New(projecterrors.ErrCodeInvalidRequest, "")) {
		t.Fatalf("run() error = %v, want ErrCodeInvalidRequest", err)
	}
}

func TestReadBounded(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	smallPath := filepath.Join(dir, "small")
	if err := os.WriteFile(smallPath, []byte("content"), 0o600); err != nil {
		t.Fatalf("write small input: %v", err)
	}
	data, err := readBounded(smallPath)
	if err != nil {
		t.Fatalf("readBounded() error = %v", err)
	}
	if string(data) != "content" {
		t.Errorf("readBounded() = %q, want content", data)
	}

	largePath := filepath.Join(dir, "large")
	if writeErr := os.WriteFile(largePath, bytes.Repeat([]byte{'x'}, maxInputBytes+1), 0o600); writeErr != nil {
		t.Fatalf("write large input: %v", writeErr)
	}
	_, err = readBounded(largePath)
	if !stderrors.Is(err, projecterrors.New(projecterrors.ErrCodeInvalidRequest, "")) {
		t.Fatalf("readBounded(large) error = %v, want ErrCodeInvalidRequest", err)
	}

	_, err = readBounded(filepath.Join(dir, "missing"))
	if !stderrors.Is(err, projecterrors.New(projecterrors.ErrCodeNotFound, "")) {
		t.Fatalf("readBounded(missing) error = %v, want ErrCodeNotFound", err)
	}
}
