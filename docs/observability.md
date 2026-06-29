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
- Push notifications: Alertmanager publishes mobile alerts directly to ntfy at
  `push.d-reis.com`. Apprise is deployed for future non-ntfy fanout, but it is
  not in the active Alertmanager route while its destination files are empty.

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
  identified. This repo uses a direct Kustomize app instead of an unrelated
  third-party chart.

## Ownership Boundary

Kubernetes/GitOps owns everything that can be expressed as Kubernetes state:

- the push service Deployment/Service/Ingress/PVC;
- ntfy Deployment/Service/Ingress/PVC and non-secret server configuration,
  including `base-url`, `behind-proxy`, `auth-default-access`, login settings,
  and cache/auth database paths;
- Apprise API Deployment/Service and non-secret runtime configuration;
- Alertmanager routing configuration;
- any Traefik/Auth proxy routes needed for a browser-only surface.

OpenTofu owns generated notification credentials and the Kubernetes Secrets that
carry those credentials into the GitOps-managed apps. The module name is
`terraform/push`. It owns:

- `push-ntfy-config`, containing ntfy provisioned users, ACLs, access tokens,
  and the Alertmanager publisher token mounted by Alertmanager;
- `apprise-config`, containing the Apprise destination files for low, medium,
  high, and critical alert topics. These stay empty until non-ntfy fanout
  destinations are configured, so direct ntfy delivery is not duplicated;
- `push-mobile`, containing the human/mobile subscription endpoint, user,
  password, token, and topic list.

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
9. `terraform/push` writes generated ntfy and Apprise Secrets into
   `observability`. It should be applied after the namespace exists and before
   `push` or Alertmanager are expected to start.
10. The `push` app exposes ntfy at `push.d-reis.com`, with private native ntfy
    auth and four alert topics.
11. The `apprise` app runs internal-only and reads Terraform-created Apprise
    config files from `apprise-config`.
12. Alertmanager routes low, medium, high, and critical alerts directly to the
    matching ntfy topic. Add Apprise receivers only when a real non-ntfy fanout
    destination, such as email, is configured.

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
- `argocd/catalog/platform/push.yaml`
- `services/platform/push/`
- `argocd/catalog/platform/apprise.yaml`
- `services/platform/apprise/`
- `terraform/push/`

These are enough to review the metrics, logging, and notification shape before
pushing.

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
- In this chart, single-binary means `StatefulSet/loki` runs Loki with
  `-target=all`; split `read`, `write`, and `backend` workloads are not the
  active scrape targets.
- Start Alloy as a DaemonSet with Kubernetes pod log discovery.
- Run node-exporter as a standalone app in `node-observability`, not as the
  embedded `kube-prometheus-stack` subchart.
- Run Grafana dashboard and data source sidecars as live watchers, not one-shot
  init containers, so component dashboard ConfigMaps imported after Grafana
  starts are picked up automatically.
- Own local Grafana dashboards as labelled ConfigMaps under the component
  `resourcesPath`. Do not add Grafana Operator CRDs just to import dashboards.
- Give only `node-observability` privileged PodSecurity labels. Node-exporter
  needs host network, host PID, and host filesystem access for real host disk,
  filesystem, CPU, memory, and network metrics.
- Keep node-exporter hostPort disabled. Prometheus scrapes the chart's
  ClusterIP Service through a ServiceMonitor.
- Keep node-exporter from binding all host interfaces. With `hostNetwork: true`
  it still listens in the node network namespace, but the chart binds to the
  node IP rather than `0.0.0.0`.
- Keep Loki labels low-cardinality: namespace, pod, container, app, and node.
- Disable Loki's built-in log-level discovery and set `detected_level` in
  Alloy from explicit severity fields, Kubernetes klog prefixes, or
  delimiter-bounded severity tokens. Do not rely on Loki's raw message
  substring fallback for warning/error dashboards.
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
  `auth-default-access: deny-all`, provisioned users/tokens, ACLs, and
  `require-login` so the web UI does not present anonymous actions that later
  fail with Forbidden.
- ntfy users, ACLs, and tokens are provisioned from the Terraform-created
  `push-ntfy-config` Secret using ntfy's startup config, not by a post-start API
  provider.
- If ntfy's web interface still exposes an unauthenticated browser surface after
  native login is enabled, protect the browser route with Authentik proxy auth.
  Do not put proxy auth in front of API/mobile/web-push paths if it breaks token
  authentication.
- ntfy should use four alert topics: low, medium, high, and critical.
- The four initial topics are literal: `alerts-low`, `alerts-medium`,
  `alerts-high`, and `alerts-critical`. ACLs/tokens are the security boundary.
- The personal/mobile user is read-only on `alerts-*`; publishing to those
  topics is reserved for Alertmanager directly.
- Alertmanager sends alert name as the notification title and the alert
  description as the body. Resolved notifications are explicitly prefixed as
  resolved. The ntfy click target is the public Grafana alerting list, so
  mobile notifications do not expose Prometheus' internal `generatorURL`.
- Apprise API should be a direct Kustomize Deployment/Service using the
  official container, not a third-party Helm chart.
- Apprise is the generic fanout path, not the ntfy adapter. Do not point
  Apprise back at ntfy while Alertmanager publishes to ntfy directly.
- Alertmanager repeat timing starts as low `24h`, medium `12h`, high `4h`, and
  critical `30m`.
- CoreDNS metrics are enabled through the CoreDNS chart once `monitoring-crds`
  exists.

## Remaining Work

The notification manifests and Terraform module are present. The remaining work
is operational validation after sync:

1. Apply `terraform/push` once the `observability` namespace exists.
2. Sync `push`, `apprise`, and `monitoring`.
3. Confirm the ntfy mobile client can connect to `push.d-reis.com` with the
   `push-mobile` Secret values.
4. Fire one synthetic Alertmanager alert and one deliberately failed ArgoCD sync
   or degraded app condition to prove direct ntfy delivery.
5. Improve notification body formatting if the sparse first-pass payload is too
   thin in daily use.

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
8. Configure Alertmanager to route low, medium, high, and critical alerts to
   direct ntfy webhooks. Add Apprise fanout routes only after a non-ntfy
   destination exists.

## Push App Plan

1. Add `push` as a Kustomize platform app in `observability`.
2. Run ntfy with native auth enabled and anonymous access denied.
3. Expose ntfy at `push.d-reis.com` through Traefik, cert-manager, and
   external-dns.
4. Persist ntfy cache/auth data on a `1Gi` `zfs` PVC.
5. Read provisioned users, ACLs, and tokens from the Terraform-created
   `push-ntfy-config` Secret.

## Apprise App Plan

1. Add `apprise` as a Kustomize platform app in `observability`.
2. Keep Apprise internal-only.
3. Run in simple stateful mode with API-only access and locked config.
4. Mount Terraform-created destination config from `apprise-config` at
   `/config`.
5. Disable Apprise's separate persistent execution store with an empty
   `APPRISE_STORAGE_DIR`; notification history is not restore-critical and a
   read-only Secret-backed `/config` would otherwise fail `/status`.
6. Keep Apprise destination files empty until a non-ntfy fanout destination is
   added. `APPRISE_ALLOW_SERVICES` permits `mailto` only so stale ntfy
   destinations cannot turn Apprise into a second ntfy publisher.

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
  server, ApplicationSet controller, and notifications. Dex is disabled because
  ArgoCD uses Authentik OIDC directly.
- Traefik: Prometheus metrics Service plus an explicit ServiceMonitor that
  scrapes through the Kubernetes API service proxy, keeping Talos' host firewall
  closed on the metrics port.
- cert-manager: ServiceMonitor for controller, cainjector, and webhook.
- external-dns: metrics ServiceMonitor.
- external-secrets: ServiceMonitors and Grafana dashboard ConfigMap.
- CNPG operator: PodMonitor and dashboard ConfigMap sidecar labels.
- CNPG cluster: PodMonitor and PrometheusRule values.
- Authentik: server and worker metrics Services and ServiceMonitors.
- CoreDNS: expose the `9153` metrics port and enable the chart ServiceMonitor.
- Loki: ServiceMonitor, dashboards, and non-alerting rules.
- Loki log overview: local dashboard ConfigMap showing log, warning, and
  error-rate trends by namespace and by pod using Loki `detected_level`
  metadata.
- Alloy: ServiceMonitor for controller health and scrape status.
- VolSync: chart ServiceMonitor, local backup alerts, and a Grafana dashboard
  for backup freshness, missed intervals, out-of-sync state, and duration.

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
4. Sync `monitoring-crds` first and confirm Prometheus Operator CRDs exist.
   This also creates the `observability` namespace for Terraform-created
   Secrets.
5. Apply `terraform/sso` so `grafana-sso` exists in `observability`.
6. Apply `terraform/push` so `push-ntfy-config`, `apprise-config`, and
   `push-mobile` exist in `observability`.
7. Sync `push` and `apprise`.
8. Sync `monitoring`.
9. Sync `node-exporter` and confirm its DaemonSet is admitted in
   `node-observability`.
10. Sync `loki`.
11. Sync `alloy` and confirm logs arrive in Loki.
12. Confirm Grafana login through Authentik.
13. Confirm Prometheus targets for kube-state-metrics, node-exporter, kubelet,
   Prometheus, Alertmanager, Grafana, and enabled component ServiceMonitors.
14. Confirm ntfy login/subscription using the `push-mobile` Secret.
15. Fire one synthetic Alertmanager alert and one deliberately failed ArgoCD
    sync to prove direct ntfy delivery.

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
- Losing the ntfy PVC loses notification cache and auth/cache database state.
  The provisioned users, ACLs, and tokens are restored by `terraform/push`, but
  runtime subscription/cache history is disposable.
- These PVCs are intentionally excluded from backup scope by default.
