# Readiness Plan

This tracks the remaining concrete work before adding more complex workloads.
It intentionally excludes physical cluster shape, node count, Cilium, Longhorn,
and HA work that depends on the home rack being built out.

Readiness here means: an empty cluster can be converged from this repo, the
OpenTofu state/config for AWS and Authentik SSO, and externally stored
secrets/backups, without remembered imperative app setup.

## Current State

| Area | Current repo state | Remaining gap |
| --- | --- | --- |
| CoreDNS | Managed by `argocd/applications/coredns.yaml` with values in `bootstrap/coredns/values.yaml`. | It still uses the `default` ArgoCD project. |
| ArgoCD | Self-managed via `argocd/catalog/platform/argocd.yaml` and `services/platform/argocd/values.yaml`. The chart renders `Ingress` for `argo.d-reis.com` and `argo.k8s.d-reis.com`, plus a cert-manager `Certificate` named `argocd-server`. Authentik OIDC and group RBAC are codified. | Notifications, local-admin policy, non-default AppProjects, and automated-sync policy are not codified yet. Root/appset Applications still use `project: default`. |
| AppSets | `argocd/appsets/template.yaml.tpl` generates separate `platform`, `base`, and `app` ApplicationSets from `argocd/catalog/*/*.yaml`. It supports Helm, Kustomize, optional `requirementsPath`, optional `resourcesPath`, and optional server-side apply. | Namespace ownership and project assignment are not codified per category. Most generated apps do not enable automated sync. |
| OpenTofu/AWS/Auth | OpenTofu modules under `terraform/` manage the Kubernetes OIDC provider, Route53 access, external-dns DynamoDB registry, IAM roles for external-dns/cert-manager/external-secrets, and Authentik SSO catalog resources. `enable_iam_users = false` and `enable_oidc_roles = true` are checked in. | No backup bucket/role/user exists yet. The restore contract must explicitly include the SSO OpenTofu state/apply because Authentik apps/providers and generated OIDC client Secrets are not purely Kubernetes-declarative. |
| external-dns | `services/platform/external-dns/values.yaml` uses AWS web identity env vars and a projected service account token. It uses the DynamoDB registry and writes root-domain CNAMEs plus `k8s.d-reis.com` records. | Nothing structural. Keep root-domain names explicit in ingress annotations; do not infer or rewrite them. |
| cert-manager | `services/platform/cert-manager/values.yaml` uses AWS web identity env vars and a projected service account token. `services/platform/cert-manager/resources/issuers.yaml` defines staging and production Route53 DNS01 `ClusterIssuer`s. | Nothing structural. Bootstrap IAM-user comments can stay until README cleanup, but runtime should not depend on those Secrets. |
| external-secrets | Chart and `ClusterSecretStore` are present under `services/platform/external-secrets/`. Store reads AWS SSM Parameter Store via service account JWT and smoke tests have validated normal String and SecureString reads. Authentik uses ESO generators and the Kubernetes provider to copy its CNPG password from `cnpg-database` into the `authentik` namespace. | Non-generated secrets are not inventoried consistently yet. |
| OIDC issuer | `services/platform/oidc/` publishes the Kubernetes service-account issuer metadata and JWKS via Kustomize. Terraform trusts `https://oidc.k8s.d-reis.com`. | JWKS refresh is still a manual repo update when service-account signing keys change. |
| Traefik | `services/platform/traefik/values.yaml` runs Traefik on host networking with ports 80/443, publishes `thule.d-reis.com` as the ingress endpoint, sets host-network DNS policy for service-name forward-auth calls, and ships shared Authentik forward-auth plus the SSO-protected dashboard resources under `services/platform/traefik/resources/`. | Nothing structural for current readiness. |
| OpenEBS/ZFS | `services/platform/openebs/` enables ZFS LocalPV and defines `zfs`, `zfs-bulk`, `zfs-spof`, and temporary variants. | Volume backup tooling is absent. `VolumeSnapshotClass` is defined, but snapshot-controller/CRD ownership needs to be made explicit before relying on snapshots. |
| CNPG operator | Managed by `argocd/catalog/platform/cnpg-operator.yaml` with server-side apply. | Monitoring and operator resources are not enabled/tuned. |
| CNPG cluster | Managed by `argocd/catalog/base/cnpg-cluster.yaml`. It creates a 3-instance PostgreSQL 16 cluster on `zfs`. Because the current CNPG chart does not provide standalone `DatabaseRole`, `services/base/cnpg-cluster/values.yaml` still declares the Authentik managed role inline. | Object-store backups and monitoring are disabled. Moving app roles to `DatabaseRole` after a chart/operator upgrade is cleanup, not a current readiness blocker. |
| Authentik | Managed by `argocd/catalog/base/authentik.yaml` in the `authentik` namespace. `services/base/authentik/requirements/` creates the namespace, Authentik database, canonical CNPG password Secret in `cnpg-database`, and ESO copies of the app config and CNPG CA into `authentik`. The chart disables bundled PostgreSQL, consumes the copied config Secret, mounts the copied CNPG server CA, uses PostgreSQL `verify-full`, keeps chart service account creation enabled, and exposes `sso.d-reis.com` plus `sso.k8s.d-reis.com` through Traefik/cert-manager/external-dns. OpenTofu codifies users/groups, OIDC apps, proxy apps, and provider attachments from the ArgoCD catalog. | SMTP and the SSO OpenTofu restore contract still need to be documented/codified. |
| Vaultwarden | Managed by `argocd/catalog/app/vaultwarden.yaml`. Uses ZFS PVCs, TLS/DNS annotations, SMTP Secret, Bitwarden installation Secret, and currently `database.type: default` with a FIXME to move off SQLite. | App modernization remains open, but Vaultwarden is not a current readiness blocker. |
| Vikunja | Managed by `argocd/catalog/app/vikunja.yaml`. Uses ZFS PVCs and TLS/DNS annotations. Current values define file and database PVCs, so it is still effectively local-state backed. | App modernization remains open, but Vikunja is not a current readiness blocker. |
| Odoo | `services/app/odoo/values.yaml` exists, but there is no `argocd/catalog/app/odoo.yaml`. | Intentionally parked until the chart/database/security issues are handled. Do not treat this as a readiness blocker for the current app set. |
| Observability | No Prometheus, Grafana, Loki, Alloy/Promtail, ServiceMonitor, PodMonitor, or alerting config is present. | Needs a platform observability stack and per-service metrics toggles. |
| Backups | No backup controller is present. CNPG backups are disabled. Volume backups are absent. | Needs off-cluster backup target, CNPG object-store backups, and PVC backup coverage for non-database state. |

## Prioritized Readiness Work

This order is based on impact versus implementation effort, not criticality or
data-loss risk. For this cluster, impact means how much the work improves
repeatable convergence, day-to-day iteration, or debugging.

| Order | Work | Impact | Effort | Rationale |
| --- | --- | --- | --- | --- |
| 1 | Add repo validation | High | Low | Catches chart value, YAML, Kustomize, and generated-manifest regressions before they reach ArgoCD. |
| 2 | Define restore inputs and secret ownership | High | Low | Turns the current implicit restore knowledge into a repeatable checklist without changing live workloads. |
| 3 | Finish small ArgoCD operational policy choices | Low | Low | Local-admin policy, notifications, and automated-sync choices are useful polish now that SSO works. |
| 4 | Codify ArgoCD Projects and namespace ownership | High | Medium | Makes app categories and empty-cluster namespace creation real, but touches templates and multiple catalog entries. |
| 5 | Add observability | Medium | Medium | Improves debugging and confidence, but adds a sizable platform app and per-service metrics toggles. |
| 6 | Add backups | Low | Medium/High | Useful for full rebuilds, but current irreplaceable data is small and easily exported; implementation spans AWS, CNPG, and PVC tooling. |

Vaultwarden and Vikunja modernization is useful, but it is not part of the
current readiness gate.

### 1. Add Repo Validation

Add a single repo-local validation command so chart/key regressions are caught
before pushing.

Suggested target: `scripts/validate.sh` or `make validate`.

Checks:

- `bash -n` over shell scripts.
- `yq` parse over YAML files.
- Regenerate AppSets and fail if generated files differ.
- `kubectl kustomize` for Kustomize services.
- `helm template` for catalog Helm apps with repo values.
- `tofu -chdir=terraform/<module> validate` for OpenTofu modules.
- Render ArgoCD ingress and certificate specifically, because chart value keys are easy to get wrong.

Acceptance checks:

- The command passes on a clean checkout.
- A wrong ArgoCD ingress key such as `additionalAnnotations` instead of `annotations` fails through the render check.

### 2. Define Restore Inputs and Secret Ownership

Make the restore contract explicit for the parts that are not purely Kubernetes
manifests.

- Document that Authentik catalog applications, providers, users/groups, OIDC client Secrets, and proxy outpost attachments are owned by the OpenTofu SSO module under `terraform/sso`.
- Document the order of operations for restoring Authentik: CNPG/ESO prerequisites, Authentik chart, then OpenTofu SSO apply.
- Inventory non-generated secrets and pick one owner for each:
  - Authentik SMTP credentials
  - ArgoCD notification SMTP credentials
  - backup credentials, if role-based auth is not enough
  - any future platform observability credentials
- Put non-generated Kubernetes app secrets behind ExternalSecrets from SSM where possible.
- Document the service-account OIDC issuer/JWKS rotation path, including how `services/platform/oidc/oidc.json` and `jwks.json` are refreshed when signing keys change.

Acceptance checks:

- A reader can identify which secrets are generated locally, which come from SSM, and which are produced by OpenTofu.
- No platform secret needed for restore exists only as an undocumented manual `kubectl` command.
- The Authentik SSO restore path is documented well enough to recreate ArgoCD and Traefik dashboard login.

### 3. Finish Small ArgoCD Operational Policy Choices

Keep this as a small follow-up, not a large ArgoCD redesign.

- Decide whether the local admin account should stay enabled as break-glass access or be disabled after documenting another break-glass path.
- Add ArgoCD notifications using the same SMTP/ExternalSecret pattern as the rest of the platform, if notifications are wanted before observability exists.
- Decide whether the root app and generated apps should use automated sync.

Acceptance checks:

- The chosen local-admin policy is visible in `services/platform/argocd/values.yaml`.
- A deliberately failed sync sends one notification if notifications are enabled.
- Automated sync behavior is explicit rather than inherited from defaults.

### 4. Codify ArgoCD Projects and Namespace Ownership

Add concrete ownership boundaries before treating the repo as an empty-cluster
source of truth.

- Add `argocd/projects/platform.yaml`, `argocd/projects/base.yaml`, and `argocd/projects/app.yaml`.
- Change `argocd/appsets/template.yaml.tpl` so generated Applications use `project: platform`, `project: base`, or `project: app`, with an explicit catalog override if needed.
- Decide whether the root and CoreDNS Applications stay in `default` or move to a named project, then codify that decision.
- Add namespace requirements where charts do not create namespaces:
  - `services/platform/external-dns/requirements/namespace.yaml`
  - `services/platform/cert-manager/requirements/namespace.yaml`
  - `services/platform/argocd/requirements/namespace.yaml` if ArgoCD should own labels on its namespace
  - other platform/base/app namespaces that are expected to exist on an empty cluster
- Set `requirementsPath` in the matching catalog YAMLs.
- Put namespace manifests in sync wave `-10`.

Acceptance checks:

- Generated Applications use non-default projects unless a specific exception is documented.
- A non-critical namespace can be deleted and recreated by resyncing its owning Application.

### 5. Add Observability

Add this after the core auth/database paths are stable. It can start before full
backup automation if the first pass stays modest.

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

### 6. Add Backups

Do this when the cluster state is worth preserving automatically rather than by
manual export.

OpenTofu/AWS:

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

## Completed Or Non-Blocking Work

### ArgoCD SSO and RBAC

ArgoCD OIDC and group RBAC are codified in `services/platform/argocd/values.yaml`.
Policy follow-ups are tracked in the prioritized work section.

Acceptance checks:

- Browser login works through Authentik.
- Group membership maps to the expected ArgoCD roles.

### Authentik and SSO Catalog

Authentik itself is Kubernetes-managed, and its application/provider layer is
OpenTofu-managed from the ArgoCD catalog files. Do not add a parallel blueprint
system for the same ArgoCD, Traefik dashboard, or future catalog-managed apps.

Acceptance checks:

- Authentik reaches the shared CNPG database with TLS verification enabled.
- ArgoCD OIDC login works.
- Traefik forward-auth works on the SSO debug route and the dashboard.

### Shared Traefik Middlewares

Authentik forward-auth and the dashboard route are now codified.

- Extend `services/platform/traefik/resources/` if more shared Middleware resources are wanted:
  - secure headers
  - compression if wanted
- Reference these middlewares from apps that need them.

Acceptance checks:

- A test ingress can attach the shared middleware chain.
- Authentik forward-auth works on a non-critical test route and the Traefik dashboard before being used for real apps.

## Deferred

- Vaultwarden migration to CNPG, ExternalSecrets, and any admin-path/proxy Authentik integration.
- Vikunja migration to CNPG, ExternalSecrets, and native OIDC.
- Odoo adoption.
- Multi-node HA, anti-affinity tuning, and control-plane redundancy.
- Replacing the storage or network foundation.
- Full empty-cluster restore drill. Do one targeted CNPG restore and one PVC restore first.
