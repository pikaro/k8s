# Conventions

Follow the local AGENTS.md contract: keep changes scoped, minimal, reviewable,
and aligned with existing patterns. Do not store plaintext secrets in the repo.
Use AWS SSM Parameter Store for external durable secrets; use External Secrets
generators for cluster-local generated secrets. Prefer catalog-driven and
provider-output-driven configuration over hardcoding where repo patterns allow
it.

Service catalog entries usually define `name`, optional `namespace`, chart
source/version, optional `resourcesPath`/`requirementsPath`, and optional
`authentik` metadata. Appset generation uses `argocd/appsets/template.yaml.tpl`;
platform services default to namespace equal to `name`.

For Kubernetes config, validate locally first with YAML parsing, Helm rendering,
Kustomize rendering, and `argocd/appsets/generate.sh`. Server-side dry-run may
be used for schema/admission validation but is still validation only, not
deployment.
