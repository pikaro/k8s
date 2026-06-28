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
| CoreDNS | Managed by `argocd/applications/coredns.yaml` with values in `bootstrap/coredns/values.yaml`. The chart exposes the `9153` metrics port and a ServiceMonitor once Prometheus Operator CRDs are present. | It still uses the `default` ArgoCD project. |
| ArgoCD | Self-managed via `argocd/catalog/platform/argocd.yaml` and `services/platform/argocd/values.yaml`. The chart renders `Ingress` for `argo.d-reis.com` and `argo.k8s.d-reis.com`, plus a cert-manager `Certificate` named `argocd-server`. Authentik OIDC and group RBAC are codified, the local admin account is disabled, and generated catalog Applications use non-default AppProjects. Root and CoreDNS intentionally stay in `project: default`. | Notifications belong with observability. Automated sync is deferred to the final readiness step. |
| AppSets | `argocd/appsets/generate.sh` renders separate `platform`, `base`, and `app` AppProjects and ApplicationSets from templates. Project destinations are generated from catalog namespaces. Generated Applications use their category project by default, create their destination namespace by default, and support catalog project overrides. The ApplicationSet template supports Helm, Kustomize, optional `requirementsPath`, optional `resourcesPath`, and optional server-side apply. | Automated sync is intentionally deferred to the final readiness step. |
| OpenTofu/AWS/Auth | OpenTofu modules under `terraform/` manage the Kubernetes OIDC provider, Route53 access, external-dns DynamoDB registry, IAM roles for external-dns/cert-manager/external-secrets, and Authentik SSO catalog resources. `enable_iam_users = false` and `enable_oidc_roles = true` are checked in. | Restore inputs and the SSO OpenTofu apply path are documented in `docs/restore-contract.md`. The rsync.net-backed object-store gateway uses ESO-generated credentials, not SSM. |
| external-dns | `services/platform/external-dns/values.yaml` uses AWS web identity env vars and a projected service account token. It uses the DynamoDB registry and writes root-domain CNAMEs plus `k8s.d-reis.com` records. | Nothing structural. Keep root-domain names explicit in ingress annotations; do not infer or rewrite them. |
| cert-manager | `services/platform/cert-manager/values.yaml` uses AWS web identity env vars and a projected service account token. `services/platform/cert-manager/resources/issuers.yaml` defines staging and production Route53 DNS01 `ClusterIssuer`s. | Nothing structural. Bootstrap IAM-user comments can stay until README cleanup, but runtime should not depend on those Secrets. |
| external-secrets | Chart and `ClusterSecretStore` are present under `services/platform/external-secrets/`. Store reads AWS SSM Parameter Store via service account JWT and smoke tests have validated normal String and SecureString reads. Authentik uses ESO generators and the Kubernetes provider to copy its CNPG password from `cnpg-database` into the `authentik` namespace. | Readiness-scope secret ownership is documented in `docs/restore-contract.md`. Future non-generated platform secrets should be SSM parameters exposed through External Secrets. |
| OIDC issuer | `services/platform/oidc/` publishes the Kubernetes service-account issuer metadata and JWKS via Kustomize. Terraform trusts `https://oidc.k8s.d-reis.com`. | JWKS refresh is still a manual repo update when service-account signing keys change. |
| Traefik | `services/platform/traefik/values.yaml` runs Traefik on host networking with ports 80/443, publishes `thule.d-reis.com` as the ingress endpoint, sets host-network DNS policy for service-name forward-auth calls, keeps the chart metrics Service enabled, and ships shared Authentik forward-auth, the SSO-protected dashboard resources, and an API-proxy Prometheus ServiceMonitor under `services/platform/traefik/resources/`. | Nothing structural for current readiness. |
| OpenEBS/ZFS | `services/platform/openebs/` enables ZFS LocalPV and defines `zfs`, `zfs-bulk`, `zfs-spof`, and temporary variants. Hostpath LocalPV is disabled; ZFS is the intended local storage engine. | Volume backup tooling is absent. `VolumeSnapshotClass` is defined, but snapshot-controller/CRD ownership needs to be made explicit before relying on snapshots. |
| CNPG operator | Managed by `argocd/catalog/platform/cnpg-operator.yaml` with server-side apply. Operator PodMonitor and Grafana dashboard ConfigMap are enabled. | Operator resources are not tuned. |
| CNPG cluster | Managed by `argocd/catalog/base/cnpg-cluster.yaml`. It creates a 3-instance PostgreSQL 16 cluster on `zfs` with PodMonitor and PrometheusRule monitoring enabled. Because the current CNPG chart does not provide standalone `DatabaseRole`, `services/base/cnpg-cluster/values.yaml` still declares the Authentik managed role inline. | Object-store backups are configured for the rsync.net-backed gateway, but a first manual backup and throwaway restore still need to be proven. Moving app roles to `DatabaseRole` after a chart/operator upgrade is cleanup, not a current readiness blocker. |
| Authentik | Managed by `argocd/catalog/base/authentik.yaml` in the `authentik` namespace. `services/base/authentik/requirements/` creates the namespace, Authentik database, canonical CNPG password Secret in `cnpg-database`, and ESO copies of the app config and CNPG CA into `authentik`. The chart disables bundled PostgreSQL, consumes the copied config Secret, mounts the copied CNPG server CA, uses PostgreSQL `verify-full`, keeps chart service account creation enabled, enables server/worker metrics ServiceMonitors, and exposes `sso.d-reis.com` plus `sso.k8s.d-reis.com` through Traefik/cert-manager/external-dns. OpenTofu codifies users/groups, OIDC apps, proxy apps, and provider attachments from the ArgoCD catalog. | The SSO restore contract is documented in `docs/restore-contract.md`. SMTP is not part of the current readiness gate unless email flows become a gate. |
| Vaultwarden | Managed by `argocd/catalog/app/vaultwarden.yaml`. Uses ZFS PVCs, TLS/DNS annotations, SMTP Secret, Bitwarden installation Secret, and currently `database.type: default` with a FIXME to move off SQLite. | App modernization remains open, but Vaultwarden is not a current readiness blocker. |
| Vikunja | Managed by `argocd/catalog/app/vikunja.yaml`. Uses ZFS PVCs and TLS/DNS annotations. Current values define file and database PVCs, so it is still effectively local-state backed. | App modernization remains open, but Vikunja is not a current readiness blocker. |
| Odoo | `services/app/odoo/values.yaml` exists, but there is no `argocd/catalog/app/odoo.yaml`. | Intentionally parked until the chart/database/security issues are handled. Do not treat this as a readiness blocker for the current app set. |
| Observability | Catalog/value files codify `monitoring-crds`, `monitoring`, `node-exporter`, `loki`, `alloy`, `push`/ntfy, and `apprise`, plus chart-native metrics integrations for current platform/base services, including Authentik. `terraform/push` owns generated ntfy users/tokens/ACL config, Apprise destination config, and the mobile client Secret. Alertmanager routes low/medium/high/critical alerts through Apprise to ntfy. Observability PVCs are disposable readiness state, not backup targets. | Sync and prove notification delivery with one synthetic Alertmanager alert and one ArgoCD failure/degraded condition. |
| Object-store gateway | `argocd/catalog/platform/object-store-gateway.yaml` deploys a cluster-internal rclone S3 gateway backed by rsync.net over SFTP/SCP-compatible SSH. It exposes `object-store-gateway.object-store.svc.cluster.local:9000`. Host and user are checked-in config for `zh3928.rsync.net`/`zh3928`; the SSH key and S3 gateway password are generated by External Secrets; known hosts are populated by an init-time `ssh-keyscan`. | Needs a live sync/test and the generated SSH public key registered on rsync.net. This is a general external object-store endpoint; AWS S3 can still be preferred for workloads that need a real object store. |
| Backups | No backup controller is present. CNPG object-store backups are configured against the rsync.net-backed gateway. Volume backups are absent. The object-store gateway is available as a low-cost target, but backups can also use AWS S3 where that is the better fit. | Needs a proven CNPG backup/restore and PVC backup coverage for workload state. Observability history/cache is intentionally excluded unless that policy changes later. |

## Prioritized Readiness Work

This order is based on impact versus implementation effort, not criticality or
data-loss risk. For this cluster, impact means how much the work improves
repeatable convergence, day-to-day iteration, or debugging.

| Order | Status | Work | Impact | Effort | Rationale |
| --- | --- | --- | --- | --- | --- |
| 1 | Done | Add repo validation | High | Low | Catches chart value, YAML, Kustomize, and generated-manifest regressions before they reach ArgoCD. |
| 2 | Done | Define restore inputs and secret ownership | High | Low | Turns the current implicit restore knowledge into a repeatable checklist without changing live workloads. |
| 3 | Done | Disable ArgoCD local admin | Low | Low | ArgoCD is last in the bootstrap flow, so disabling the built-in local admin now fits the current SSO path. |
| 4 | Done | Codify ArgoCD Projects and namespace ownership | High | Medium | Makes app categories and empty-cluster namespace creation real, while leaving root and CoreDNS in `default`. |
| 5 | Open | Prove observability notifications | Medium | Low | Metrics, logs, and the shared Apprise/ntfy notification path are codified; live delivery still needs a synthetic alert test after sync. |
| 6 | Open | Add backups | Low | Medium/High | Useful for full rebuilds, but current irreplaceable data is small and easily exported; implementation spans AWS, CNPG, and PVC tooling. |
| 7 | Open | Enable automated sync | Low | Low | Make pruning/self-healing explicit only after projects, namespaces, observability, and backups are in place. |

Vaultwarden and Vikunja modernization is useful, but it is not part of the
current readiness gate.

### 1. Add Repo Validation

Status: done.

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

Status: done. Documented in `docs/restore-contract.md`.

Make the restore contract explicit for the platform/base parts that are not
purely Kubernetes manifests. This excludes post-readiness app-specific secrets
and data.

- Document that Authentik catalog applications, providers, users/groups, OIDC client Secrets, and proxy outpost attachments are owned by the OpenTofu SSO module under `terraform/sso`.
- Document the order of operations for restoring Authentik: CNPG/ESO prerequisites, Authentik chart, then OpenTofu SSO apply.
- Inventory readiness-scope non-generated secrets and pick one owner for each.
  Current readiness-scope manifests do not require any non-generated SSM-backed
  Kubernetes Secret.
- Put non-generated readiness-scope Kubernetes Secrets behind ExternalSecrets from SSM where possible.
- Document the service-account OIDC issuer/JWKS rotation path, including how `services/platform/oidc/oidc.json` and `jwks.json` are refreshed when signing keys change.

Acceptance checks:

- A reader can identify which secrets are generated locally, which come from SSM, and which are produced by OpenTofu.
- No platform secret needed for restore exists only as an undocumented manual `kubectl` command.
- The Authentik SSO restore path is documented well enough to recreate ArgoCD and Traefik dashboard login.

### 3. Disable ArgoCD Local Admin

Status: done.

The local `admin` account is disabled in `services/platform/argocd/values.yaml`.
ArgoCD is the last bootstrap README item, so SSO is expected to exist before the
self-managed ArgoCD application takes over this setting.

Acceptance checks:

- `configs.cm.admin.enabled` is set to `"false"` in `services/platform/argocd/values.yaml`.
- Browser login through Authentik still works after ArgoCD syncs the value.

### 4. Codify ArgoCD Projects and Namespace Ownership

Status: done.

Add concrete ownership boundaries before treating the repo as an empty-cluster
source of truth.

- Add `argocd/projects/platform.yaml`, `argocd/projects/base.yaml`, and `argocd/projects/app.yaml`.
- Change `argocd/appsets/template.yaml.tpl` so generated Applications use `project: platform`, `project: base`, or `project: app`, with an explicit catalog override if needed.
- Generate each AppProject's destination namespaces from its catalog entries.
- Keep the root and CoreDNS Applications in `default`.
- Set `CreateNamespace=true` in the ApplicationSet template so namespace creation is the default rule for generated Applications.
- Keep `requirementsPath` and `resourcesPath` for exceptions that need real extra manifests, not for namespace-only boilerplate.

Acceptance checks:

- Generated Applications use non-default projects unless a specific exception is documented.
- Generated AppProjects allow only their catalog-derived destination namespaces.
- Generated Applications include `CreateNamespace=true`.
- Existing Kustomize paths render locally.

### 5. Add Observability And Notifications

Status: open pending live delivery proof. Metrics, log collection, and
notification routing are codified through `monitoring-crds`, `monitoring`,
`node-exporter`, Loki, Alloy, `push`, Apprise, chart-native component monitoring
integrations, and `terraform/push`.

Target stack:

- Prometheus, Alertmanager, Grafana, kube-state-metrics, and the Prometheus
  Operator via `kube-prometheus-stack`.
- Prometheus Operator CRDs via a separate early `monitoring-crds` app, so
  component charts can always render monitor resources without bootstrap
  toggles.
- Standalone node-exporter in `node-observability`, with that namespace
  explicitly labeled for privileged PodSecurity because host metrics require
  host network, host PID, and host filesystem access.
- Loki for log storage, with modest retention and no restore-critical data
  assumption.
- Alloy for Kubernetes log collection into Loki.
- Apprise API as the notification adapter.
- ntfy as the human notification endpoint.

Implementation scope:

- Add the stack under the `platform` ArgoCD project.
- Use an `observability` namespace unless a chart requires a narrower split.
- Add `argocd/catalog/platform/monitoring-crds.yaml` for
  `prometheus-operator-crds` and sync it before apps that render
  `ServiceMonitor`, `PodMonitor`, `PrometheusRule`, or `Probe` objects.
- Add `argocd/catalog/platform/monitoring.yaml` for `kube-prometheus-stack`.
- Add `services/platform/monitoring/values.yaml` with Grafana ingress, TLS,
  Authentik OIDC, and persistent storage on `zfs`.
- Add `argocd/catalog/platform/node-exporter.yaml` and
  `services/platform/node-exporter/` with a privileged namespace requirement and
  a ServiceMonitor-enabled `prometheus-node-exporter` chart.
- Add Loki and Alloy as platform apps, either as separate catalog entries or as
  one observability entry if the chart boundaries stay clean.
- Add Apprise API and ntfy as part of the observability notification path.
- Route Alertmanager notifications through Apprise API to ntfy.
- Configure ArgoCD notifications for sync failures and degraded applications to
  use the same Apprise/ntfy path instead of creating a separate notification
  channel.
- Use initial storage and retention defaults:
  - Prometheus: `10Gi` on `zfs`, `14d` retention, and about `8Gi`
    retention-size.
  - Loki: `10Gi` on `zfs-bulk` if supported cleanly by the chart, otherwise
    `zfs`; `7d` retention.
  - Grafana: `2Gi` on `zfs`.
  - Alertmanager: `1Gi` on `zfs`.
  - ntfy: `1Gi` on `zfs`.
  - Apprise API and Alloy: no durable PVC by default.
- Treat observability PVCs as disposable. Losing them loses metrics history,
  log history, Grafana local state, Alertmanager silences, and ntfy cached
  messages, but not workload data.
- Enable metrics integrations in existing values:
  - ArgoCD metrics and ServiceMonitors
  - Traefik metrics API-proxy ServiceMonitor
  - cert-manager ServiceMonitor
  - external-dns ServiceMonitor
  - external-secrets ServiceMonitor
  - CNPG operator monitoring
  - CNPG cluster monitoring
  - Authentik server/worker ServiceMonitors
  - CoreDNS ServiceMonitor
  - Alloy ServiceMonitor
  - Loki ServiceMonitor and dashboards

Initial alerts to codify as PrometheusRules:

- ArgoCD app degraded or sync failed.
- Certificate expires soon or cert-manager challenge failing.
- CNPG backup failed or too old.
- PostgreSQL cluster not healthy.
- PVC free space low for app volumes.
- Pod crash-looping in managed namespaces.
- ArgoCD sync failures and degraded applications.

Acceptance checks:

- Grafana is reachable through Traefik with a cert-manager certificate.
- Prometheus has targets for ArgoCD, Traefik, cert-manager, external-dns, external-secrets, CNPG, and app pods where applicable.
- One synthetic Alertmanager alert reaches ntfy through Apprise API.
- A deliberately failed ArgoCD sync sends one notification through that same
  path.

### 6. Add Backups

Do this when the cluster state is worth preserving automatically rather than by
manual export.

Object-store target:

- Use the existing rsync.net account as a general off-cluster object-store
  target when a cheap internal S3-compatible endpoint is useful.
- Expose it inside the cluster with `services/platform/object-store-gateway/`.
- Treat `object-store-gateway.object-store.svc.cluster.local:9000` as an
  internal protocol bridge only. The rsync.net path is the durable storage
  boundary.
- Keep `zh3928.rsync.net` and `zh3928` in checked-in config; they are not
  secret material.
- Generate the rsync.net SSH key with ESO's `SSHKey` generator and register the
  generated public key on rsync.net.
  Retrieve it after first sync with:
  `kubectl -n object-store get secret object-store-gateway-rsyncnet-ssh -o jsonpath='{.data.publicKey}' | base64 -d`.
- Generate the gateway's S3 access key Secret with ESO's `Password` generator.
- Populate `known_hosts` at pod start with an init-time `ssh-keyscan`, not SSM.
- Treat rclone `serve s3` as a pragmatic compatibility layer, not a proven S3
  service. It is experimental and its multipart upload path can hold upload
  parts in memory, so prove CNPG base backups before enabling a schedule.

PostgreSQL:

- Enable `backups.enabled` in `services/base/cnpg-cluster/values.yaml`.
- Set the S3 endpoint, bucket/path, credentials, and retention.
- Do not enable S3 server-side encryption unless the rclone S3 endpoint is
  proven to accept the headers CNPG sends.
- If the S3-compatible endpoint rejects newer boto3 checksum headers, set the
  documented CNPG environment workaround for `AWS_REQUEST_CHECKSUM_CALCULATION`
  and `AWS_RESPONSE_CHECKSUM_VALIDATION`.
- Keep the daily scheduled backup unless there is a concrete reason to change it.

Volumes:

- Add a platform backup controller, preferably VolSync with Restic for first implementation.
- Add per-PVC backup manifests for:
  - Vaultwarden attachments/files
  - Vikunja files
  - Authentik media, if applicable
- Make snapshot-controller/VolumeSnapshot CRD ownership explicit if using CSI snapshots.
- Do not back up Prometheus, Loki, Grafana, Alertmanager, ntfy, or other
  observability PVCs by default; they are readiness debugging state, not
  restore-critical workload data.

Acceptance checks:

- The `object-store-gateway` application syncs, the generated public key is
  accepted by rsync.net, and rclone can list/create a test object through the
  cluster-internal S3 endpoint.
- A CNPG-sized object upload does not OOM the rclone gateway or fail on S3
  compatibility headers.
- A manual CNPG backup completes and appears in the bucket.
- A VolSync backup completes for one non-critical PVC.
- One throwaway restore is performed into a temporary namespace before trusting the setup.

### 7. Enable Automated Sync

Do this last in readiness, after projects, namespace ownership, observability,
and backups are in place.

- Decide which root, ApplicationSet, and generated Applications should enable:
  - automated sync
  - pruning
  - self-healing
- Update `argocd/appsets/template.yaml.tpl` and generated ApplicationSets.
- Keep exceptions explicit in catalog YAML when a workload should stay manual.

Acceptance checks:

- Automated sync behavior is explicit rather than inherited from defaults.
- A non-critical generated Application self-heals a harmless drift.
- Prune behavior is tested on a non-critical managed resource before enabling
  it broadly.

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
