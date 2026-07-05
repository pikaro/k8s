# Completion Checklist

Before finishing a repo/configuration change:

- Regenerate ApplicationSets/AppProjects if catalog entries changed.
- Run focused YAML/Helm/Kustomize/OpenTofu validation for touched paths.
- Run `git diff --check`.
- Review `git diff` for accidental unrelated changes.
- Summarize what changed, validation performed, and any manual/live follow-up
  required.

Do not run live `kubectl apply`, delete, patch, restart, scale, or Helm upgrade
unless the user explicitly requests a live cluster mutation.
