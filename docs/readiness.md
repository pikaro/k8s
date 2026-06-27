# Readiness Plan

This tracks the remaining concrete work before adding more complex workloads.
It intentionally excludes physical cluster shape, node count, Cilium, Longhorn,
and HA work that depends on the home rack being built out.

Readiness here means: an empty cluster can be converged mostly from this repo
plus externally stored secrets/backups, without remembered imperative app setup.

## Current State

| Area | Current repo state | Remaining gap |
| --- | --- | --- |
| CoreDNS | Managed by `argocd/applications/coredns.yaml` with values in `bootstrap/coredns/values.yaml`. | It still uses the `default` ArgoCD project. |
| ArgoCD | Self-managed via `argocd/catalog/platform/argocd.yaml` and `services/platform/argocd/values.yaml`. The chart renders `Ingress` for `argo.d-reis.com` and `argo.k8s.d-reis.com`, plus a cert-manager `Certificate` named `argocd-server`. | Authentik/OIDC, RBAC, notifications, and non-default AppProjects are not codified yet. Root/appset Applications still use `project: default`. |
| AppSets | `argocd/appsets/template.yaml.tpl` generates separate `platform`, `base`, and `app` ApplicationSets from `argocd/catalog/*/*.yaml`. It supports Helm, Kustomize, optional `requirementsPath`, optional `resourcesPath`, and optional server-side apply. | Namespace creation and project assignment are not codified per category. Most generated apps do not enable automated sync. |
| Terraform/AWS | `terraform/` manages the Kubernetes OIDC provider, Route53 access, external-dns DynamoDB registry, and IAM roles for external-dns, cert-manager, and external-secrets. `enable_iam_users = false` and `enable_oidc_roles = true` are checked in. | No backup bucket/role/user exists here yet. No Authentik or app secret inventory exists as SSM parameters in Terraform. |
| external-dns | `services/platform/external-dns/values.yaml` uses AWS web identity env vars and a projected service account token. It uses the DynamoDB registry and writes root-domain CNAMEs plus `k8s.d-reis.com` records. | Nothing structural. Keep root-domain names explicit in ingress annotations; do not infer or rewrite them. |
| cert-manager | `services/platform/cert-manager/values.yaml` uses AWS web identity env vars and a projected service account token. `services/platform/cert-manager/resources/issuers.yaml` defines staging and production Route53 DNS01 `ClusterIssuer`s. | Nothing structural. Bootstrap IAM-user comments can stay until README cleanup, but runtime should not depend on those Secrets. |
| external-secrets | Chart and `ClusterSecretStore` are present under `services/platform/external-secrets/`. Store reads AWS SSM Parameter Store via service account JWT. Authentik uses ESO generators and the Kubernetes provider to copy its CNPG password from `cnpg-database` into the `authentik` namespace. | App secrets are mostly not modeled as `ExternalSecret` resources yet. Verify the store against a real parameter before migrating app secrets that come from AWS SSM. |
| OIDC issuer | `services/platform/oidc/` publishes the Kubernetes service-account issuer metadata and JWKS via Kustomize. Terraform trusts `https://oidc.k8s.d-reis.com`. | JWKS refresh is still a manual repo update when service-account signing keys change. |
| Traefik | `services/platform/traefik/values.yaml` runs Traefik on host networking with ports 80/443 and publishes `thule.d-reis.com` as the ingress endpoint. | Shared middlewares are not codified yet. Authentik forward-auth is not present. |
| OpenEBS/ZFS | `services/platform/openebs/` enables ZFS LocalPV and defines `zfs`, `zfs-bulk`, `zfs-spof`, and temporary variants. | Volume backup tooling is absent. `VolumeSnapshotClass` is defined, but snapshot-controller/CRD ownership needs to be made explicit before relying on snapshots. |
| CNPG operator | Managed by `argocd/catalog/platform/cnpg-operator.yaml` with server-side apply. | Monitoring and operator resources are not enabled/tuned. |
| CNPG cluster | Managed by `argocd/catalog/base/cnpg-cluster.yaml`. It creates a 3-instance PostgreSQL 16 cluster on `zfs`. Because CNPG 1.29.1 has no `DatabaseRole`, `services/base/cnpg-cluster/values.yaml` still declares the Authentik managed role inline. Backups and monitoring are disabled. | Move app roles to `DatabaseRole` after CNPG 1.30 is adopted. No app databases are declared for Vaultwarden or Vikunja. Object-store backups are disabled. |
| Authentik | Managed by `argocd/catalog/base/authentik.yaml` in the `authentik` namespace. `services/base/authentik/requirements/` creates the namespace, Authentik database, canonical CNPG password Secret in `cnpg-database`, and ESO copies of the app config and CNPG CA into `authentik`. The chart disables bundled PostgreSQL, consumes the copied config Secret, mounts the copied CNPG server CA, uses PostgreSQL `verify-full`, keeps chart service account creation enabled, and exposes `auth.d-reis.com` plus `auth.k8s.d-reis.com` through Traefik/cert-manager/external-dns. | Initial Authentik blueprints, SMTP, ArgoCD OIDC, Vikunja OIDC, and any Vaultwarden-specific integration are not codified yet. |
| Vaultwarden | Managed by `argocd/catalog/app/vaultwarden.yaml`. Uses ZFS PVCs, TLS/DNS annotations, SMTP Secret, Bitwarden installation Secret, and currently `database.type: default` with a FIXME to move off SQLite. | Move admin token, SMTP, and installation secrets to ExternalSecrets. Migrate database to CNPG. Decide exact Authentik integration; do not assume normal vault login can be OIDC if the app/chart does not support it. |
| Vikunja | Managed by `argocd/catalog/app/vikunja.yaml`. Uses ZFS PVCs and TLS/DNS annotations. Current values define file and database PVCs, so it is still effectively local-state backed. | Move database to CNPG. Add Authentik OIDC config and secrets. |
| Odoo | `services/app/odoo/values.yaml` exists, but there is no `argocd/catalog/app/odoo.yaml`. | Intentionally parked until the chart/database/security issues are handled. Do not treat this as a readiness blocker for the current app set. |
| Observability | No Prometheus, Grafana, Loki, Alloy/Promtail, ServiceMonitor, PodMonitor, or alerting config is present. | Needs a platform observability stack and per-service metrics toggles. |
| Backups | No backup controller is present. CNPG backups are disabled. Volume backups are absent. | Needs off-cluster backup target, CNPG object-store backups, and PVC backup coverage for non-database state. |

## Ordered Work

### 1. Codify Namespaces and ArgoCD Projects

Add concrete ArgoCD project and namespace manifests before adding more apps.

- Add `argocd/projects/platform.yaml`, `argocd/projects/base.yaml`, and `argocd/projects/app.yaml`.
- Change `argocd/appsets/template.yaml.tpl` so generated Applications use `project: ${TYPE}` or an explicit catalog override.
- Add namespace requirements where charts do not create namespaces:
  - `services/platform/external-dns/requirements/namespace.yaml`
  - `services/platform/cert-manager/requirements/namespace.yaml`
  - `services/platform/argocd/requirements/namespace.yaml` if ArgoCD should own labels on its namespace
  - app namespaces as apps are migrated
- Set `requirementsPath` in the matching catalog YAMLs.
- Put namespace manifests in sync wave `-10`.

Acceptance checks:

- Generated Applications under `kubectl -n argocd get applications.argoproj.io -o yaml` use `spec.project` values other than `default`.
- Recreating a non-critical namespace and resyncing its app recreates the namespace from Git.

### 2. Finish ArgoCD as a Managed Service

ArgoCD is self-managed now; finish the parts that affect daily use.

- Keep `global.domain: argo.d-reis.com`; this is the real public UI domain.
- Keep `argo.k8s.d-reis.com` as the cluster-domain alias.
- Add Authentik OIDC config to `services/platform/argocd/values.yaml` after Authentik exists.
- Add RBAC in `configs.rbac`:
  - an admin group from Authentik
  - a read-only/default role for authenticated users if desired
- Disable the local admin account only after OIDC login works.
- Add ArgoCD notifications using the same SMTP path as the other apps, backed by an ExternalSecret.
- Decide whether the root app and generated apps should use automated sync. Current manifests do not codify automated sync.

Acceptance checks:

- `helm template argocd argo/argo-cd --version 9.7.0 -n argocd -f services/platform/argocd/values.yaml --show-only templates/argocd-server/certificate.yaml` renders `dnsNames` for `argo.d-reis.com` and `argo.k8s.d-reis.com`.
- Browser login works through Authentik.
- A deliberately failed sync sends one notification.

### 3. Finish Authentik

Initial Authentik deployment is now a base backed by CNPG and ExternalSecrets.

- `argocd/catalog/base/authentik.yaml` pins the Authentik Helm chart.
- `services/base/authentik/values.yaml` disables bundled PostgreSQL, mounts the CNPG CA Secret, uses PostgreSQL `verify-full`, keeps chart service account creation enabled, and configures the public/internal ingress names.
- `services/base/cnpg-cluster/values.yaml` declares the Authentik role inline because CNPG 1.29.1 does not provide `DatabaseRole`.
- `services/base/authentik/requirements/` declares the Authentik namespace, CNPG `Database`, canonical DB password Secret in `cnpg-database`, and ESO Kubernetes-provider copies of the app config and CNPG CA into the `authentik` namespace.

Remaining resources to add:

- Add `services/base/authentik/resources/` for:
  - ExternalSecrets for SMTP and OIDC client secrets
  - Authentik blueprints

Initial blueprints to codify:

- ArgoCD provider/application/groups.
- Vikunja provider/application/groups.
- Vaultwarden integration only after deciding the exact mechanism. Likely candidates are admin-path protection or a proxy/forward-auth flow, not native vault login unless the deployed app supports it.

Acceptance checks:

- Authentik can be recreated from Git plus External Secrets-generated credentials and SSM parameters for non-generated secrets.
- Authentik reaches the shared CNPG database with TLS verification enabled.
- ArgoCD OIDC login works.
- Vikunja login works through Authentik after Vikunja is migrated/configured.

### 4. Move App Secrets to ExternalSecrets

Use the existing `ClusterSecretStore` named `aws-ssm`.

Add ExternalSecret resources for current manual secrets:

- Vaultwarden:
  - `vaultwarden-smtp`
  - `vaultwarden-installation`
  - admin token or the chart-specific Secret key it maps to
  - future PostgreSQL connection material if not read directly from CNPG-generated Secrets
- Vikunja:
  - service secret/JWT secret
  - OIDC client secret
  - PostgreSQL password or URL if not read directly from CNPG-generated Secrets
- Authentik:
  - SMTP credentials
  - OIDC client secrets for apps if blueprints read them from Kubernetes Secrets
- ArgoCD:
  - OIDC client secret
  - notification SMTP credentials

Implementation shape:

- Put app-local ExternalSecrets under `services/<type>/<name>/resources/`.
- Set `resourcesPath` in the corresponding `argocd/catalog/<type>/<name>.yaml`.
- Use SSM paths under the existing Terraform prefix `/external-secrets/...`.

Acceptance checks:

- `kubectl get externalsecret -A` shows all app secrets.
- Restarting an app after deleting its Kubernetes Secret lets external-secrets recreate it.
- No important app secret is represented only by a README command.

### 5. Migrate Vaultwarden and Vikunja to CNPG

The shared CNPG cluster exists, and Authentik is the first declarative app database.

- Add database/user declarations for:
  - `vaultwarden`
  - `vikunja`
- Until CNPG 1.30 is adopted, add only the required `managed.roles` entries in `services/base/cnpg-cluster/values.yaml`.
- Put each app's `Database`, canonical DB password Secret, and ESO namespace copy under that app's `requirements/` directory.
- After CNPG 1.30 is adopted, move app roles from inline `managed.roles` to app-owned `DatabaseRole` resources in the app requirements directory.
- Update Vaultwarden values to use PostgreSQL and remove the SQLite FIXME after data migration.
- Update Vikunja values to use PostgreSQL and remove the database PVC after data migration.
- Keep file/attachment PVCs for app data that is not database state.

Acceptance checks:

- `services/base/cnpg-cluster/test.yaml` still succeeds.
- Vaultwarden starts with PostgreSQL and existing logins/items present.
- Vikunja starts with PostgreSQL and existing tasks/files present.
- SQLite/database PVCs are no longer needed for those apps after migration.

### 6. Add Backups

Do this before adding more stateful apps.

Terraform:

- Add an off-cluster S3 backup bucket.
- Add IAM access for CNPG backups.
- Add IAM access for the volume backup controller.
- Store any non-role backup credentials in SSM and expose them through ExternalSecrets.

PostgreSQL:

- Enable `backups.enabled` in `services/base/cnpg-cluster/values.yaml`.
- Set the S3 bucket/region/path and retention.
- Keep the daily scheduled backup unless there is a concrete reason to change it.

Volumes:

- Add a platform backup controller, preferably VolSync with Restic for first implementation.
- Add per-PVC backup manifests for:
  - Vaultwarden attachments/files
  - Vikunja files
  - Authentik media, if applicable
  - Grafana/Loki only if their state is not otherwise disposable
- Make snapshot-controller/VolumeSnapshot CRD ownership explicit if using CSI snapshots.

Acceptance checks:

- A manual CNPG backup completes and appears in the bucket.
- A VolSync backup completes for one non-critical PVC.
- One throwaway restore is performed into a temporary namespace before trusting the setup.

### 7. Add Observability

Add this after the core auth/database/backup paths are stable.

- Add `argocd/catalog/platform/monitoring.yaml` for `kube-prometheus-stack`.
- Add `services/platform/monitoring/values.yaml` with:
  - Grafana ingress and TLS
  - Grafana admin/OIDC/SMTP via ExternalSecrets
  - persistent storage on `zfs`
- Add Loki and log collection, either:
  - separate `loki` and `alloy` platform apps, or
  - a single observability app if the chart boundaries stay clean
- Enable metrics integrations in existing values:
  - ArgoCD metrics and ServiceMonitors
  - Traefik metrics ServiceMonitor/PodMonitor
  - cert-manager ServiceMonitor
  - external-dns ServiceMonitor
  - external-secrets ServiceMonitor
  - CNPG operator monitoring
  - CNPG cluster monitoring

Initial alerts to codify as PrometheusRules:

- ArgoCD app degraded or sync failed.
- Certificate expires soon or cert-manager challenge failing.
- CNPG backup failed or too old.
- PostgreSQL cluster not healthy.
- PVC free space low for app volumes.
- Pod crash-looping in managed namespaces.

Acceptance checks:

- Grafana is reachable through Traefik with a cert-manager certificate.
- Prometheus has targets for ArgoCD, Traefik, cert-manager, external-dns, external-secrets, CNPG, and app pods where applicable.
- One synthetic alert reaches the selected notification target.

### 8. Add Shared Traefik Middlewares

Do this once Authentik exists.

- Add `services/platform/traefik/resources/`.
- Add shared Middleware resources for:
  - secure headers
  - compression if wanted
  - Authentik forward-auth
- Set `resourcesPath: services/platform/traefik/resources` in `argocd/catalog/platform/traefik.yaml`.
- Reference these middlewares from apps that need them.

Acceptance checks:

- A test ingress can attach the shared middleware chain.
- Authentik forward-auth works on a non-critical test route before being used for real apps.

### 9. Add Repo Validation

Add a single repo-local validation command so chart/key regressions are caught
before pushing.

Suggested target: `scripts/validate.sh` or `make validate`.

Checks:

- `bash -n` over shell scripts.
- `yq` parse over YAML files.
- Regenerate AppSets and fail if generated files differ.
- `kubectl kustomize` for Kustomize services.
- `helm template` for catalog Helm apps with repo values.
- `tofu -chdir=terraform validate`.
- Render ArgoCD ingress and certificate specifically, because chart value keys are easy to get wrong.

Acceptance checks:

- The command passes on a clean checkout.
- A wrong ArgoCD ingress key such as `additionalAnnotations` instead of `annotations` fails through the render check.

## Deferred

- Odoo adoption.
- Multi-node HA, anti-affinity tuning, and control-plane redundancy.
- Replacing the storage or network foundation.
- Full empty-cluster restore drill. Do one targeted CNPG restore and one PVC restore first.
