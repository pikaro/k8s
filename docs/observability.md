# Observability Implementation Plan

This is the concrete implementation plan for readiness item 5. It is scoped to
cluster observability and alert delivery. It does not include backup policy,
post-readiness app modernization, or automated sync.

## Target Shape

- `monitoring-crds`: Prometheus Operator CRDs in `observability`, installed
  before any chart renders Prometheus Operator custom resources.
- `monitoring`: `kube-prometheus-stack` in `observability`.
- `node-exporter`: standalone `prometheus-node-exporter` in
  `node-observability`.
- `loki`: single-binary Loki in `observability`.
- `alloy`: Alloy DaemonSet in `observability`, shipping pod logs to Loki.
- `authentik`: chart-native server and worker metrics ServiceMonitors.
- Push notifications: Alertmanager to Apprise API to an exposed push service,
  currently expected to be ntfy. Backend choice and credential ownership still
  need to be resolved before manifests are added.

All implemented apps are `platform` apps. Namespace creation stays with the
generated ApplicationSet `CreateNamespace=true` rule unless the namespace needs
exceptional metadata. `node-observability` is such an exception because
node-exporter needs privileged PodSecurity labels for host metrics.

## Source Notes

- `prometheus-operator-crds` owns the Prometheus Operator API types as an early
  bootstrap dependency. This lets component charts always render
  `ServiceMonitor`, `PodMonitor`, `PrometheusRule`, and `Probe` objects without
  depending on whether the runtime observability stack exists yet.
- `kube-prometheus-stack` is the standard chart for Prometheus Operator,
  Prometheus, Alertmanager, Grafana, kube-state-metrics, and node-exporter.
  This repo disables its CRD ownership and embedded node-exporter, and runs the
  standalone `prometheus-node-exporter` chart in a narrower privileged
  namespace.
- The Grafana subchart supports `grafana.ini`, environment variables from
  Secrets, ingress, persistence, sidecar dashboards, and additional data
  sources.
- Loki's Grafana chart supports a single-binary deployment with filesystem
  storage and PVC persistence.
- Alloy's Grafana chart supports a DaemonSet controller and inline River config.
- ntfy documents Kubernetes deployment with plain manifests; its Helm path is
  third-party, so choosing Helm for ntfy would be a separate decision.
- ntfy does not have native OIDC/SSO integration for the server-side API path.
  It supports its own auth database, users, ACLs, and access tokens. Authentik
  forward-auth may be useful for a browser-only web route later, but it is not
  the primary auth model for Alertmanager/Apprise or mobile/API clients.
- ntfy's own docs treat topic names as secret-like on unauthenticated public
  servers. With `auth-default-access: deny-all`, provisioned users, ACLs, and
  access tokens, topic names are not the primary security boundary.
- Apprise API has an official container image, but no upstream Helm chart was
  identified. A direct Kustomize app is likely cleaner than adopting an
  unrelated third-party chart, but that is a decision before files are added.

## Ownership Boundary

Kubernetes/GitOps owns everything that can be expressed as Kubernetes state:

- the push service Deployment/Service/Ingress/PVC;
- ntfy server configuration, including `base-url`, `behind-proxy`,
  `auth-default-access`, login settings, cache/auth/web-push database paths, and
  VAPID key Secret wiring;
- Apprise API Deployment/Service/config;
- Alertmanager routing configuration;
- any Traefik/Auth proxy routes needed for a browser-only surface.

Terraform must only patch API-managed gaps that Kubernetes cannot declaratively
own well. If a provider is used, the module name should be `terraform/push`.
The intended provider use is narrow:

- create or reconcile push-server users/tokens/ACLs after the service exists;
- write app-local `kubernetes_secret_v1` objects for catalog entries that are
  allowed to send notifications.

Terraform should not replace the GitOps deployment or own service config that
belongs in Kubernetes manifests/Helm values.

## Dependency Walkthrough

1. ArgoCD AppProject already allows generated platform apps to target catalog
   namespaces. Adding `monitoring`, `loki`, and `alloy` with
   `namespace: observability` makes the generated project include
   `observability`; adding `node-exporter` with
   `namespace: node-observability` makes the generated project include the
   privileged node metrics namespace.
2. The `monitoring-crds` app installs Prometheus Operator CRDs before any
   component app renders Prometheus Operator custom resources.
3. The `monitoring` app installs Prometheus, Alertmanager, Grafana,
   kube-state-metrics, and the Prometheus Operator with chart CRD ownership
   disabled.
4. The `monitoring` catalog entry declares the Grafana Authentik app. The
   `terraform/sso` module must be applied after that catalog entry exists and
   before Grafana is expected to start, because the chart reads the
   Terraform-created `grafana-sso` Secret for client credentials and OIDC
   endpoint URLs.
5. The `node-exporter` app depends on the Prometheus Operator CRDs for its
   ServiceMonitor. Its own requirements create the `node-observability`
   namespace with privileged PodSecurity labels.
6. The `loki` app provides the in-cluster write endpoint used by Alloy and the
   Grafana Loki data source.
7. The `alloy` app can start after Loki exists. Its values point at
   `http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push`.
8. Component chart metrics integrations are enabled in the owning chart values.
   They rely on `monitoring-crds`, not on the runtime observability stack.
9. Notifications depend on Alertmanager and should be added after the
   Apprise/ntfy branch is decided.

## Drafted Configuration

The following files are intentionally created as normal repo files:

- `argocd/catalog/platform/monitoring.yaml`
- `argocd/catalog/platform/monitoring-crds.yaml`
- `services/platform/monitoring/values.yaml`
- `services/platform/monitoring-crds/values.yaml`
- `argocd/catalog/platform/node-exporter.yaml`
- `services/platform/node-exporter/requirements/namespace.yaml`
- `services/platform/node-exporter/values.yaml`
- `argocd/catalog/platform/loki.yaml`
- `services/platform/loki/values.yaml`
- `argocd/catalog/platform/alloy.yaml`
- `services/platform/alloy/values.yaml`

These are enough to review the standard metrics/logging shape before pushing.

## Standard Decisions Already Encoded

- Use `observability` as the shared namespace.
- Keep monitoring-crds, monitoring, node-exporter, Loki, and Alloy as separate
  platform apps.
- Use native Grafana OAuth against Authentik, not forward-auth.
- Expose only Grafana and the push web/API surface through Traefik initially.
- Keep Prometheus, Alertmanager, Loki, and Alloy internal-only.
- Use `o11y.d-reis.com` as the external Grafana hostname.
- Use `grafana.k8s.d-reis.com` as the internal Grafana hostname.
- Use `global-users`, `global-admins`, `grafana-users`, and `grafana-admins`
  for Grafana access. Global groups always imply the matching user/admin app
  role; app-specific groups are additional narrower grants.
- Use `zfs` for Prometheus, Grafana, and Alertmanager.
- Use `zfs-bulk` for Loki if the chart accepts it cleanly.
- Treat all observability PVCs as disposable readiness state.
- Use single-node replicas for the first pass, matching the current one-node
  Talos cluster.
- Start Loki as single-binary filesystem storage, not object storage or a
  distributed deployment.
- Start Alloy as a DaemonSet with Kubernetes pod log discovery.
- Run node-exporter as a standalone app in `node-observability`, not as the
  embedded `kube-prometheus-stack` subchart.
- Give only `node-observability` privileged PodSecurity labels. Node-exporter
  needs host network, host PID, and host filesystem access for real host disk,
  filesystem, CPU, memory, and network metrics.
- Keep node-exporter hostPort disabled. Prometheus scrapes the chart's
  ClusterIP Service through a ServiceMonitor.
- Keep node-exporter from binding all host interfaces. With `hostNetwork: true`
  it still listens in the node network namespace, but the chart binds to the
  node IP rather than `0.0.0.0`.
- Keep Loki labels low-cardinality: namespace, pod, container, app, and node.
- Treat Prometheus Operator CRDs as baseline API state. Component monitor
  objects should render unconditionally once those CRDs are in the bootstrap
  flow.

## Clarified Decisions

- Grafana uses native Authentik OIDC with the established catalog-driven SSO
  pattern.
- Grafana is exposed at both `o11y.d-reis.com` and
  `grafana.k8s.d-reis.com`.
- Grafana uses global plus app-specific groups: `global-users` and
  `grafana-users` map to Viewer, while `global-admins` and `grafana-admins`
  map to Admin. No editor group is added for the first pass.
- The push service should use `push` naming for the user-facing domain and for
  any Terraform module. Do not expose implementation names such as `ntfy` in
  the public URL.
- ntfy should be exposed, but not anonymously.
- ntfy should use native auth for API/mobile/web-push clients:
  `auth-default-access: deny-all`, provisioned users/tokens, and ACLs.
- If ntfy's web interface still exposes an unauthenticated browser surface after
  native login is enabled, protect the browser route with Authentik proxy auth.
  Do not put proxy auth in front of API/mobile/web-push paths if it breaks token
  authentication.
- ntfy should use four alert topics: low, medium, high, and critical.
- Topic names do not need to be the main secret when ACLs/tokens are
  provisioned. Use non-obvious topic names if it is cheap, but treat that as
  defense-in-depth.
- Alert source metadata should be carried as notification metadata/tags rather
  than by multiplying topics.
- Apprise API should be a direct Kustomize Deployment/Service using the
  official container, not a third-party Helm chart.
- Alertmanager repeat timing starts as low `24h`, medium `12h`, high `4h`, and
  critical `30m`.
- CoreDNS metrics are enabled through the CoreDNS chart once `monitoring-crds`
  exists.

## Remaining Blockers

These should be answered before the notification app and final alert routing are
added.

1. Confirm backend choice after evaluating the Terraform providers. Current
   leaning remains ntfy because its topic/priority/web-push model fits the
   alerting use case better than Gotify's application/channel model.
2. Confirm the public hostname. Proposed default: `push.d-reis.com`.
3. Choose ntfy credential ownership:
   - Kubernetes config for bootstrap/server config, plus `terraform/push` for
     API-managed users/tokens/ACLs and app-local Secrets; or
   - only Kubernetes-provisioned users/tokens/ACLs in ntfy config, accepting
     that client tokens are either static Secret inputs or regenerated by a
     manual process.
4. Choose the initial ntfy users and ACLs. Proposed default:
   - `alertmanager`: write-only to `alerts-*`;
   - one personal/user credential: read-only to `alerts-*`;
   - anonymous access denied with `auth-default-access: deny-all`.
5. Decide whether the four alert topics should be literal names
   (`alerts-low`, `alerts-medium`, `alerts-high`, `alerts-critical`) or
   generated/non-obvious names stored in Secrets. ACLs/tokens are still the real
   security control either way.

## Monitoring App Plan

1. Add `prometheus-operator-crds` as `monitoring-crds` in `observability`.
   This app should sync before CoreDNS adoption and before platform/base/app
   charts that render Prometheus Operator custom resources. On clusters that
   previously installed the CRDs through `monitoring`, sync `monitoring-crds`
   before syncing or pruning `monitoring` so ArgoCD resource tracking moves to
   the CRD-only Application.
2. Add `kube-prometheus-stack` as `monitoring` in `observability`, with
   `crds.enabled: false` because CRD ownership belongs to `monitoring-crds`.
3. Enable Grafana with:
   - ingress through Traefik;
   - cert-manager certificate;
   - external-dns target to `thule.d-reis.com`;
   - Authentik generic OAuth using the Terraform-created `grafana-sso` Secret
     for client credentials and OIDC endpoint URLs;
   - Viewer access for `global-users` and `grafana-users`;
   - Admin access for `global-admins` and `grafana-admins`;
   - `2Gi` PVC on `zfs`;
   - `Recreate` deployment strategy because the single Grafana pod uses an RWO
     ZFS PVC;
   - Loki data source pointing to the in-cluster Loki gateway.
4. Enable Prometheus with:
   - `10Gi` PVC on `zfs`;
   - `14d` retention;
   - `8GB` retention size;
   - namespace-wide `ServiceMonitor`, `PodMonitor`, `Probe`, and
     `PrometheusRule` discovery.
5. Enable Alertmanager with a `1Gi` PVC on `zfs`.
6. Disable the embedded node-exporter subchart; host metrics are provided by the
   standalone `node-exporter` app.
7. Disable first-pass scrape configurations that are likely to be wrong in the
   current Talos shape:
   - controller-manager;
   - scheduler;
   - etcd;
   - kube-proxy;

   CoreDNS is handled by the CoreDNS chart's own metrics ServiceMonitor.
8. Leave Alertmanager notification routing as the chart default until Apprise
   API and ntfy are defined.

## Node-Exporter App Plan

1. Add the standalone `prometheus-node-exporter` chart as `node-exporter` in
   `node-observability`.
2. Use a `requirementsPath` only because this namespace needs exceptional
   PodSecurity labels.
3. Label `node-observability` as privileged for enforce, audit, and warn.
4. Keep host network, host PID, and host filesystem mounts enabled so
   node-exporter reports host-level CPU, memory, filesystem, disk, and network
   metrics.
5. Keep hostPort disabled. A ClusterIP Service plus ServiceMonitor is enough for
   Prometheus to scrape it.
6. Bind node-exporter to the node IP rather than all host interfaces.
7. Enable the chart's ServiceMonitor because `monitoring-crds` owns the required
   Prometheus Operator API types.

## Loki App Plan

1. Add Grafana's `loki` chart as `loki` in `observability`.
2. Use single-binary deployment mode with one replica.
3. Use filesystem storage and TSDB schema.
4. Persist data on a `10Gi` PVC.
5. Set `7d` retention and enable compactor retention.
6. Keep gateway enabled so Alloy and Grafana have a stable in-cluster service.
7. Disable distributed read/write/backend replicas for the initial shape.

## Alloy App Plan

1. Add Grafana's `alloy` chart as `alloy` in `observability`.
2. Run Alloy as a DaemonSet.
3. Discover Kubernetes pods and ship logs to Loki.
4. Keep labels low-cardinality.
5. Do not persist Alloy state.
6. Enable Alloy's own ServiceMonitor for controller health and scrape status.

## Existing Service Integration Plan

These are enabled in the owning chart values and rely on `monitoring-crds`:

- ArgoCD: metrics and ServiceMonitors for Redis, controller, repo-server,
  server, Dex, ApplicationSet controller, and notifications.
- Traefik: Prometheus metrics Service and ServiceMonitor.
- cert-manager: ServiceMonitor for controller, cainjector, and webhook.
- external-dns: metrics ServiceMonitor.
- external-secrets: ServiceMonitors and Grafana dashboard ConfigMap.
- CNPG operator: PodMonitor and dashboard ConfigMap sidecar labels.
- CNPG cluster: PodMonitor and PrometheusRule values.
- Authentik: server and worker metrics Services and ServiceMonitors.
- CoreDNS: expose the `9153` metrics port and enable the chart ServiceMonitor.
- Loki: ServiceMonitor, dashboards, and non-alerting rules.
- Alloy: ServiceMonitor for controller health and scrape status.

## Alerting Baseline

Use the chart's default Kubernetes rules as the first baseline, then add local
rules once notification delivery works.

Initial local rules after notifications:

- ArgoCD app degraded or sync failed: medium by default, high for platform/base
  if the label data allows clean routing.
- Certificate expires soon: medium; renewal/challenge failing or very near
  expiry: high.
- PostgreSQL cluster unhealthy: high; primary unavailable: critical.
- CNPG backup failed or too old: high after backups exist.
- PVC free space low: medium; very low: high.
- Pod crash-looping: medium; platform/base repeated crash-loop: high.

Severity labels should normalize to `low`, `medium`, `high`, and `critical`.
Imported chart rules that use `warning` should route as `medium`.

## Validation Sequence

1. Run YAML parsing over new files.
2. Run `argocd/appsets/generate.sh` and review generated project destinations.
3. Render `monitoring-crds`, `monitoring`, `node-exporter`, `loki`, and `alloy`
   charts locally once chart repos are reachable.
4. Apply `terraform/sso` so `grafana-sso` exists in `observability`.
5. Sync `monitoring-crds` first and confirm Prometheus Operator CRDs exist.
6. Sync `monitoring`.
7. Sync `node-exporter` and confirm its DaemonSet is admitted in
   `node-observability`.
8. Sync `loki`.
9. Sync `alloy` and confirm logs arrive in Loki.
10. Confirm Grafana login through Authentik.
11. Confirm Prometheus targets for kube-state-metrics, node-exporter, kubelet,
   Prometheus, Alertmanager, Grafana, and enabled component ServiceMonitors.
12. Add Apprise API and exposed authenticated ntfy after the remaining ntfy
    blockers are resolved.
13. Add Alertmanager routing.
14. Fire one synthetic Alertmanager alert and one deliberately failed ArgoCD
    sync to prove the shared notification path.

## Data-Loss Expectations

Adding the drafted files has no live effect until pushed and synced.

When eventually synced:

- Creating the observability apps should not delete workload data.
- Creating the `node-observability` namespace and node-exporter DaemonSet should
  not delete workload data. It does grant node-exporter privileged host access in
  that namespace, and node-exporter listens in the node network namespace on
  port `9100`.
- Losing the Prometheus PVC loses metrics history.
- Losing the Loki PVC loses log history.
- Losing the Grafana PVC loses local Grafana state not represented in chart
  values, ConfigMaps, or dashboards.
- Losing the Alertmanager PVC loses silences and notification history.
- These PVCs are intentionally excluded from backup scope by default.
