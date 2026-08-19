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
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/santhosh-tekuri/jsonschema/v6"

	"github.com/NVIDIA/aicr/pkg/errors"
)

const maxInputBytes = 2 << 20

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, output io.Writer) error {
	if len(args) != 2 {
		return errors.New(errors.ErrCodeInvalidRequest, "usage: validator <schema-directory> <bom.json>")
	}

	compiler := jsonschema.NewCompiler()
	resources := []struct {
		name string
		url  string
	}{
		{"bom-1.6.schema.json", "http://cyclonedx.org/schema/bom-1.6.schema.json"},
		{"spdx.schema.json", "http://cyclonedx.org/schema/spdx.schema.json"},
		{"jsf-0.82.schema.json", "http://cyclonedx.org/schema/jsf-0.82.schema.json"},
	}
	for _, resource := range resources {
		data, err := readBounded(filepath.Join(args[0], resource.name))
		if err != nil {
			return errors.PropagateOrWrap(err, errors.ErrCodeInternal, "read CycloneDX schema")
		}
		document, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
		if err != nil {
			return errors.Wrap(errors.ErrCodeInvalidRequest, "decode CycloneDX schema", err)
		}
		if err := compiler.AddResource(resource.url, document); err != nil {
			return errors.Wrap(errors.ErrCodeInvalidRequest, "register CycloneDX schema", err)
		}
	}

	schema, err := compiler.Compile(resources[0].url)
	if err != nil {
		return errors.Wrap(errors.ErrCodeInvalidRequest, "compile CycloneDX 1.6 schema", err)
	}
	bomBytes, err := readBounded(args[1])
	if err != nil {
		return errors.PropagateOrWrap(err, errors.ErrCodeInternal, "read AIBOM document")
	}
	bom, err := jsonschema.UnmarshalJSON(bytes.NewReader(bomBytes))
	if err != nil {
		return errors.Wrap(errors.ErrCodeInvalidRequest, "decode AIBOM document", err)
	}
	if err := schema.Validate(bom); err != nil {
		return errors.Wrap(errors.ErrCodeInvalidRequest, "AIBOM failed CycloneDX 1.6 validation", err)
	}
	if _, err := fmt.Fprintln(output, "CycloneDX 1.6 schema validation passed"); err != nil {
		return errors.Wrap(errors.ErrCodeInternal, "write validation result", err)
	}
	return nil
}

func readBounded(path string) ([]byte, error) {
	cleanPath := filepath.Clean(path)
	root, err := os.OpenRoot(filepath.Dir(cleanPath))
	if err != nil {
		return nil, errors.Wrap(errors.ErrCodeNotFound, "open validation input directory", err)
	}
	defer func() { _ = root.Close() }()

	file, err := root.Open(filepath.Base(cleanPath))
	if err != nil {
		return nil, errors.Wrap(errors.ErrCodeNotFound, "open validation input", err)
	}
	defer func() { _ = file.Close() }()

	data, err := io.ReadAll(io.LimitReader(file, maxInputBytes+1))
	if err != nil {
		return nil, errors.Wrap(errors.ErrCodeInternal, "read validation input", err)
	}
	if len(data) > maxInputBytes {
		return nil, errors.New(errors.ErrCodeInvalidRequest, "validation input exceeds 2 MiB")
	}
	return data, nil
}
