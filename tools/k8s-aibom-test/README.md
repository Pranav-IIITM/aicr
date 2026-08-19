# k8s-aibom Kind Qualification

Run the dedicated behavior test with:

```bash
make k8s-aibom-test
```

The target creates a uniquely named Kind cluster with its own temporary
`KUBECONFIG`; it never reuses the caller's current context. The cluster is
deleted on exit. Set `KEEP_CLUSTER=true` to retain it for debugging, or
`OUTPUT_DIR=<path>` to keep the evidence files after a successful run.

The test installs the registry component through AICR's single-component
bundle path, runs its read-only health check, and then proves:

- an explicitly labeled namespace produces a Ready AIBOM for a digest-pinned,
  replicas-zero Deployment;
- the AIBOM has a controller owner reference to that Deployment;
- `status.bomDocument.sha256` matches the decoded canonical bytes;
- both initial and updated documents pass the official CycloneDX 1.6 JSON
  schemas;
- a reconcile with unchanged inventory input preserves `status.inputHash`;
- changing the workload image digest changes `status.inputHash`; and
- deleting the Deployment garbage-collects its AIBOM.

The test intentionally makes no `status.bomHash` stability assertion because
that hash covers output containing a generation timestamp.

The fixtures cannot start pods: they request zero replicas. Their image
references are immutable inputs for the controller only. The schemas are
downloaded from CycloneDX specification tag `1.6.1`, bounded by finite curl
timeouts, and verified against the SHA-256 values recorded in `run.sh` before
the validator uses them.

To prove that registry-only adoption does not change any stock recipe, run:

```bash
make k8s-aibom-stock-parity
```

That target builds AICR from the branch merge-base in a temporary detached
worktree, resolves every concrete stock catalog entry with both binaries, and
renders its full Helm bundle with both binaries. It requires exact catalog,
resolved-recipe, and generated-bundle byte equality. Override `BASE_REF` only
when comparing against a deliberately selected base commit. Fixed synthetic
scheduling and storage inputs satisfy components whose bundle contracts require
them; the same inputs are applied to both binaries.

Cross-deployer, vendoring, OCI-publication, scheduling, and mirror parity use a
second explicit target:

```bash
make k8s-aibom-bundle-test
```

It renders `helm`, `helmfile`, `argocd`, `argocd-helm`, and `flux` bundles in
upstream-chart and vendored-chart modes; checks the vendored chart archive
digest; renders each effective chart to verify system scheduling reaches the
controller Deployment; checks Helmfile's self-referencing-CRD validation
setting; publishes every combination to a disposable local OCI registry; and
copies the sole mirror-discovered image while preserving its digest. Docker is
required for the disposable registry.
