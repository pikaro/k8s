# Suggested Commands

- `argocd/appsets/generate.sh`: regenerate ArgoCD ApplicationSets and
  AppProjects after catalog changes.
- `yq eval '.' <file>`: YAML syntax validation.
- `helm template <release> <chart> --repo <repo> --namespace <ns> -f <values>`:
  render external Helm chart values.
- `helm template <release> <local-chart> --namespace <ns> -f <values>`: render
  repo-local Helm charts.
- `kubectl kustomize <path>`: render Kustomize resources locally.
- `tofu -chdir=terraform/aws validate`, `tofu -chdir=terraform/sso validate`,
  `tofu -chdir=terraform/push validate`: validate OpenTofu modules.
- `git diff --check`: check whitespace/conflict markers.
- `rg <pattern>` and `rg --files`: preferred search commands.
