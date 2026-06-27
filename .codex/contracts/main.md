# Repo-Specific Contract

## Derived Configuration

- Do not hardcode values in manifests, chart values, scripts, or documentation
  when they can be mechanically derived from catalog definitions, provider
  outputs, or established repo defaults.
- Derive values in the layer that owns the source data or API object. Consumers
  should receive the derived value through the existing repo interface for that
  boundary, such as Kubernetes Secrets, generated manifests, or catalog-driven
  configuration.
- OpenTofu may patch API-managed gaps and write the resulting consumer-facing
  values into Kubernetes Secrets, but it must not replace Kubernetes/GitOps
  ownership for resources and configuration that can be expressed directly as
  Kubernetes state.
- If a derived value must be duplicated, document why the duplication is
  unavoidable and keep one side clearly authoritative.
