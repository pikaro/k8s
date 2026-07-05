# CNPG 1.30 Database Consumer Migration Plan

Status: draft for review.

## Context

CloudNativePG 1.30 adds the `DatabaseRole` CRD. The CRD is namespace-scoped
and references a cluster by name only, so `Database` and `DatabaseRole`
resources for the shared `cnpg-cluster` must still live in `cnpg-database`.

The useful change is ownership structure: per-consumer PostgreSQL objects can
move out of the `cnpg-cluster` service directory and into each owning service's
configuration, while a narrow ArgoCD project limits what those consumer
applications may write.

## Goals

- Upgrade the CNPG operator chart to the 1.30.0 release.
- Add a narrow ArgoCD project for database consumer resources.
- Add a repo-local Helm chart that creates a consumer database, role, generated
  password material, and target namespace secret sync.
- Move per-service database configuration into the owning service directory:
  - `services/base/authentik`
  - `services/app/habitsync`
  - `services/app/openproject`
- Preserve live Secret names and PostgreSQL object names so migration does not
  rotate credentials or require app config changes.
- Leave cluster-owned CNPG configuration in `services/base/cnpg-cluster`.

## Non-Goals

- Do not change PostgreSQL major version.
- Do not migrate from native Barman object-store backup to the CNPG Barman Cloud
  Plugin in this change. That should be planned before CNPG 1.31.
- Do not change app database names, usernames, or target Secret names.
- Do not change Vault-related files; those are being handled separately.

## Proposed ArgoCD Model

Add a new static AppProject, tentatively named `cnpg-consumer`.

This project should allow only the namespaces needed for database consumers:

- `cnpg-database`
- `authentik`
- `habitsync`
- `openproject`

It should allow only the namespace-scoped resource kinds needed by the consumer
chart:

- `postgresql.cnpg.io/Database`
- `postgresql.cnpg.io/DatabaseRole`
- `generators.external-secrets.io/Password`
- `external-secrets.io/ExternalSecret`
- `external-secrets.io/SecretStore`
- `v1/ServiceAccount`
- `rbac.authorization.k8s.io/Role`
- `rbac.authorization.k8s.io/RoleBinding`

It should not allow cluster-scoped resources.

Do not put these entries in `argocd/catalog/app`. The current generator builds
the broad `app` project destinations from every file in that catalog; adding
`namespace: cnpg-database` there would weaken the existing `app` project.

Instead, add a separate static ApplicationSet, tentatively:

- `argocd/appsets/cnpg-consumer.yaml`
- `argocd/catalog/cnpg-consumer/*.yaml`

Each catalog entry should point to the shared local Helm chart and a values file
under the owning service directory, for example:

- `services/base/authentik/cnpg.yaml`
- `services/app/habitsync/cnpg.yaml`
- `services/app/openproject/cnpg.yaml`

The Application destination namespace should be the consumer namespace when the
chart needs ArgoCD `CreateNamespace=true` behavior, or `cnpg-database` if we
choose to rely on existing namespaces. In either case, the rendered manifests
must explicitly set namespaces for all resources.

## Proposed Local Helm Chart

Add a chart under `helm/cnpg-database-consumer`.

The chart should create these resources:

In `cnpg-database`:

- ESO `Password` generator for the database password.
- ESO `ExternalSecret` that materializes the CNPG role password Secret in
  `kubernetes.io/basic-auth` format.
- CNPG `DatabaseRole`.
- CNPG `Database`.
- `Role` and `RoleBinding` allowing the target namespace reader service account
  to read only the generated role Secret and, when requested, `cnpg-cluster-ca`.

In the target namespace:

- Reader `ServiceAccount`.
- Kubernetes-provider ESO `SecretStore` pointing at `cnpg-database`.
- ESO `ExternalSecret` that creates the app-facing Secret.
- Optional target namespace `Password` generators for app-local values such as
  `JWT_SECRET` or `AUTHENTIK_SECRET_KEY`.

The values shape should be explicit rather than app-specific. Proposed outline:

```yaml
cluster:
  name: cnpg-cluster
  namespace: cnpg-database
  host: cnpg-cluster-rw.cnpg-database.svc.cluster.local
  caSecretName: cnpg-cluster-ca

database:
  name: habitsync
  owner: habitsync
  reclaimPolicy: retain

role:
  name: habitsync
  login: true
  superuser: false
  createdb: false
  createrole: false
  replication: false
  reclaimPolicy: retain
  passwordSecretName: habitsync-db-auth

password:
  generatorName: habitsync-db-password
  length: 64
  digits: 12
  symbols: 0

target:
  namespace: habitsync
  readerServiceAccountName: habitsync-secret-reader
  secretStoreName: cnpg-database
  secret:
    name: habitsync-config
    creationPolicy: Orphan
    refreshPolicy: CreatedOnce
    type: Opaque
    includeCA: true
    templateData:
      SPRING_DATASOURCE_USERNAME: '{{ .username }}'
      SPRING_DATASOURCE_PASSWORD: '{{ .password }}'
      JWT_SECRET: '{{ .JWT_SECRET }}'
      ca.crt: '{{ index . "ca.crt" }}'
  extraGenerators:
    - name: habitsync-jwt-secret
      namespace: habitsync
      secretKeys:
        - JWT_SECRET
      length: 96
      digits: 12
      symbols: 0
```

The actual implementation should avoid hardcoding service-specific field names
in templates. Service-specific output keys belong in values files.

## Service Migration Plan

### Operator

- Update `argocd/catalog/platform/cnpg-operator.yaml` from chart `0.28.3` to
  `0.29.0`.
- Keep `services/platform/cnpg-operator/values.yaml` unchanged unless template
  validation exposes a required change.

### CNPG Cluster

- Remove `authentik`, `habitsync`, and `openproject` from
  `services/base/cnpg-cluster/values.yaml` `cluster.roles`.
- Keep backup-related requirements in
  `services/base/cnpg-cluster/requirements/s3-auth.yaml`.
- Remove per-consumer requirement files from
  `services/base/cnpg-cluster/requirements/kustomization.yaml` after the
  replacement consumer Applications exist:
  - `habitsync.yaml`
  - `openproject.yaml`

### Authentik

- Add `services/base/authentik/cnpg.yaml`.
- Move these concerns into the new chart values:
  - `authentik-db-password`
  - `authentik-db-auth`
  - `DatabaseRole` for `authentik`
  - `Database` for `authentik`
  - `authentik-secret-reader`
  - `cnpg-database` SecretStore in `authentik`
  - `cnpg-cluster-ca` copy into `authentik`
  - `authentik-config`
  - `authentik-secret-key`
- Remove the database-specific resources from
  `services/base/authentik/requirements`.
- Keep non-database requirements such as namespace and mail configuration.

### HabitSync

- Add `services/app/habitsync/cnpg.yaml`.
- Move these concerns into the new chart values:
  - `habitsync-db-password`
  - `habitsync-db-auth`
  - `DatabaseRole` for `habitsync`
  - `Database` for `habitsync`
  - target `habitsync-config` ExternalSecret
  - `habitsync-jwt-secret`
  - CA copy inside `habitsync-config`
- Simplify `services/app/habitsync/templates/externalsecrets.yaml` so it keeps
  only mail-related ExternalSecret resources, or remove it if mail is moved
  elsewhere later.
- Keep the app values pointing at `habitsync-config`.

### OpenProject

- Add `services/app/openproject/cnpg.yaml`.
- Move these concerns into the new chart values:
  - `openproject-db-password`
  - `openproject-db-auth`
  - `DatabaseRole` for `openproject`
  - `Database` for `openproject`
  - `openproject-secret-reader`
  - target `openproject-database` ExternalSecret
- Remove `services/app/openproject/requirements/db-secret.yaml`.
- Keep admin password, mail, namespace, enterprise, and backup configuration in
  the existing OpenProject service area.

## Migration Safety

Keep all object names stable:

- `authentik-db-password`
- `authentik-db-auth`
- `authentik-config`
- `habitsync-db-password`
- `habitsync-db-auth`
- `habitsync-config`
- `openproject-db-password`
- `openproject-db-auth`
- `openproject-database`

Keep ESO targets with `refreshPolicy: CreatedOnce` and
`target.creationPolicy: Orphan` where currently used. This prevents a chart move
from rotating passwords or deleting live app-facing Secrets.

Set every CNPG `Database` and `DatabaseRole` reclaim policy to `retain`.

Avoid having `Cluster.spec.managed.roles` and `DatabaseRole` manage the same
PostgreSQL role for a long period. The implementation should switch each role
from inline cluster management to `DatabaseRole` in the same reviewed change set
after the CNPG 1.30 CRD is available.

Because ArgoCD pruning is currently disabled in the generated ApplicationSets,
removing old manifests should not delete live resources. Still, the migration
should be checked for shared-resource warnings while the new consumer
Applications adopt existing objects.

## Validation Plan

Local validation:

```sh
argocd/appsets/generate.sh
helm template cnpg cloudnative-pg \
  --repo https://cloudnative-pg.github.io/charts \
  --version 0.29.0 \
  -n cnpg-system \
  -f services/platform/cnpg-operator/values.yaml
helm template authentik-cnpg helm/cnpg-database-consumer \
  -n authentik \
  -f services/base/authentik/cnpg.yaml
helm template habitsync-cnpg helm/cnpg-database-consumer \
  -n habitsync \
  -f services/app/habitsync/cnpg.yaml
helm template openproject-cnpg helm/cnpg-database-consumer \
  -n openproject \
  -f services/app/openproject/cnpg.yaml
git diff --check
```

Optional live validation after local rendering:

```sh
kubectl apply --dry-run=server -f <rendered-manifests>
```

Server-side dry-run is validation only. It should not be treated as applying or
deploying the migration.

## Rollout Order

1. Sync the CNPG operator upgrade to 1.30.0.
2. Confirm the `DatabaseRole` CRD exists.
3. Sync the new `cnpg-consumer` project and ApplicationSet.
4. Sync one low-risk consumer first, likely `habitsync`.
5. Confirm:
   - `DatabaseRole` reports applied.
   - `Database` remains present.
   - app-facing Secret still exists and has expected keys.
   - app pod reconnects successfully.
6. Migrate `openproject`.
7. Migrate `authentik` last because it is a base service and SSO dependency.
8. After all consumers are stable, remove old per-consumer files from the CNPG
   cluster and app/base requirement lists.

## Open Questions

- Should the consumer Application destination namespace be the target namespace
  or `cnpg-database`? The plan favors explicit manifest namespaces either way,
  but the implementation should verify ArgoCD project enforcement before
  finalizing.
- Should Authentik be included in the same `cnpg-consumer` catalog despite being
  a base service? The plan says yes because the permission boundary is about
  CNPG consumer resources, not app/base classification.
- Should the chart create target namespaces? The plan says no for now. Existing
  app/base namespace ownership should remain where it is.
