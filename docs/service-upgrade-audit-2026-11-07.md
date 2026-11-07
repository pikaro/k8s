# Service upgrade audit 2026 11 07

Prepared for review only. No cluster resources were changed, and nothing was
committed or pushed. Kubernetes MCP and Grafana MCP supplied the live inventory;
all 38 Argo Applications were Healthy and Synced. The node runs Kubernetes
1.34.1 and Talos 1.13.5.

The changes update 21 remote chart pins and the existing shared MCP chart
dependency. Application versions follow their charts. Authentik and Vikunja's
conflicting image overrides are removed. The redundant OpenProject memcached
tag is removed while retaining its required `bitnamilegacy` repository override.

## Chart versions prepared

Versions were checked against the configured Helm repositories on November 7.
The proposed version is the latest published chart unless the last column says
otherwise. Application versions below are the **rendered images**, not just
`Chart.yaml` metadata. Values and pins remain in the existing
[`argocd/catalog`](../argocd/catalog) and [`services`](../services) directories;
CoreDNS is pinned in [`argocd/applications/coredns.yaml`](../argocd/applications/coredns.yaml).

| Service | Installed chart → proposed chart | Live application → proposed application | Assessment |
| --- | --- | --- | --- |
| [Argo CD](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd) | 9.7.0 → 10.14.0 | 3.4.4 → 3.6.1 | Small values change; Helm 4 rendering checked. |
| [Authentik](https://docs.goauthentik.io/releases/2026.8/) | 2026.5.3 → 2026.8.5 | **2026.5.8 override** → 2026.8.5 | Remove override; configure trusted proxy. |
| [cert-manager](https://cert-manager.io/docs/installation/upgrade/) | v1.19.1 → **v1.20.5** | 1.19.1 → 1.20.5 | First minor step; latest is **v1.21.3**. |
| [CNPG operator](https://cloudnative-pg.io/docs/1.30/release_notes/v1.30/) | 0.28.3 → 0.29.1 | 1.29.1 → 1.30.1 | Compatible; backup migration required before 1.31. |
| [CNPG cluster](https://github.com/cloudnative-pg/charts/tree/main/charts/cluster) | 0.7.0 → 0.9.0 | PostgreSQL 16.14; major 16 retained | Preserve roles, storage and native Barman backup; no database image change. |
| [CoreDNS](https://github.com/coredns/helm) | 1.45.0 → 1.50.2 | 1.13.1 → 1.14.7 | Existing Corefile and Service IP preserved. |
| [ExternalDNS](https://github.com/kubernetes-sigs/external-dns/releases/tag/v0.23.0) | 1.19.0 → 1.23.0 | 0.19.0 → 0.23.0 | Preserve existing annotation prefix explicitly. |
| [External Secrets](https://github.com/external-secrets/external-secrets/releases/tag/v2.14.0) | 2.6.0 → 2.14.0 | 2.6.0 → 2.14.0 | Existing Vault, AWS and Kubernetes stores retained. |
| [Grafana Alloy](https://github.com/grafana/alloy/releases/tag/v1.21.3) | 1.10.0 → 1.15.0 | 1.17.0 → 1.21.3 | Existing Kubernetes log pipeline retained. |
| [Loki](https://github.com/grafana/loki/blob/main/production/helm/loki/CHANGELOG.md) | 7.0.0 → **7.5.0, existing repository** | 3.6.7 → **3.6.11** | Interim update; maintained OSS chart is **community 21.0.0 / Loki 3.7.9**. See migration below. |
| [Monitoring stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) | 87.2.1 → 92.22.0 | Operator 0.92.0 → 0.94.2 | Bundled components detailed below. |
| [Monitoring CRDs](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-operator-crds) | 30.0.0 → **32.0.2** | Operator schema 0.92.0 → 0.94.2 | Match the stack's operator; latest **33.0.1 / 0.95.1** is ahead of it. |
| [Node exporter](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-node-exporter) | 4.55.0 → 5.0.0 | 1.11.1 → 1.12.1 | New security defaults fit the configured collectors. |
| [OpenEBS](https://github.com/openebs/openebs/releases/tag/v4.6.2) | 4.5.1 → 4.6.2 | ZFS driver 2.10.1 → 2.11.2 | Only ZFS enabled; storage classes and encryption mounts preserved. |
| [OpenProject](https://github.com/opf/helm-charts) | 13.8.1 → 13.17.1 | 17.5.1 → 17.9.6 | Same application major; existing database and custom model mount preserved. |
| [Open WebUI](https://github.com/open-webui/open-webui/releases/tag/v0.13.0) | 15.2.0 → 18.0.0 | 0.10.2 → 0.13.0 | Automatic DB migrations; single-instance maintenance window required. |
| [Traefik](https://github.com/traefik/traefik-helm-chart) | 37.4.0 → 42.3.1 | 3.6.2 → 3.7.17 | Two values paths migrated; existing ingress setup preserved. |
| [Vault](https://github.com/hashicorp/vault-helm/releases/tag/v0.34.1) | 0.34.0 → 0.34.1 | 2.0.3 → 2.0.4 | Patch update; existing OnDelete strategy requires an interactive restart. |
| [Vaultwarden](https://github.com/guerzon/vaultwarden) | 0.46.1 → 0.46.4 | 1.37.2 → 1.37.5 | Patch/security update. |
| [Vikunja](https://vikunja.io/changelog/vikunja-2.8.0-was-released/) | v2.0.2 → 2.6.0 | **2.5.0 override** → 2.8.0 | Remove override; retain SQLite volumes and Authentik OIDC. |
| [VolSync](https://github.com/backube/volsync/releases/tag/v0.17.0) | 0.16.0 → 0.17.0 | 0.16.0 → 0.17.0 | Restic/Snapshot mode retained; rsync-ssh privilege changes do not apply. |
| [Shared MCP dependency](https://github.com/javdet/mcp-helm-chart) | 0.4.1 → **0.5.1** | GitHub/Spotify gateway packages unchanged | Last release before gateway replacement in 0.6. Latest chart: **0.7.0**. |

The monitoring stack also upgrades Grafana **13.1.0 → 13.3.0**, Prometheus
**3.12.0 → 3.16.0**, Alertmanager **0.33.0 → 0.34.2**, kube-state-metrics
**2.19.1 → 2.20.0**, and the dashboard/datasource sidecar **2.8.0 → 2.14.3**.
Grafana's dependency is chart **14.4.0**. Its distroless image and read-only root
filesystem fit the current Secret-backed environment configuration and PVC.
No custom shell startup or file-based environment expansion is configured.
The new Linux node selectors match this cluster. See the
[stack upgrade guide](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md).

Latest charts do not always contain the latest applications. ExternalDNS has
[0.24.0](https://github.com/kubernetes-sigs/external-dns/releases/tag/v0.24.0),
CoreDNS has [1.15.0](https://github.com/coredns/coredns/releases/tag/v1.15.0), and
Vault has [2.2.1](https://github.com/hashicorp/vault/releases/tag/v2.2.1).
These are **not** reached by the selected charts. No image version was forced
past a chart default. Vault 2.2.1 includes additional security fixes, so the
chart lag warrants follow-up rather than treating 2.0.4 as fully current.

Grafana's database metrics report **PostgreSQL 16.14** on all three CNPG pods.
The current patch for that major is **16.15**; the latest stable major is
**18.6** (19 is still a release candidate). The floating `postgresql:16`
reference is unchanged, so a cluster-chart bump does not establish that the
database patch has been applied. Plan a controlled minor update separately;
moving to 18 requires a database migration. PostgreSQL itself permits skipping
intermediate majors with `pg_upgrade` or dump/restore, subject to CNPG and
extension compatibility.
[PostgreSQL versioning and upgrade policy](https://www.postgresql.org/support/versioning/).

## Compatibility changes included

- **Authentik:** remove `global.image.tag`. Version 2026.8 restricts forwarded
  headers to trusted proxies. Traefik runs on the host network, so add the
  observed node address `95.217.36.114/32` alongside Authentik's default trusted
  ranges. Set this through `global.env` because configuration comes from an
  existing Secret. Update the address if the proxy moves to another node.
  [Reverse-proxy configuration](https://docs.goauthentik.io/install-config/reverse-proxy/).
- **Traefik:** move `ports.web.redirections` under `ports.web.http`, and
  `logs.general.level` to `log.level`. Preserve ports, host networking, TLS
  redirection, metrics, permissions and Recreate strategy. Kubernetes 1.34.1
  meets the chart's minimum of 1.30. The new chart stops bundling several
  Gateway API CRDs; Gateway API is unused here, and Argo's `prune: false`
  retains those old CRDs. Review any later manual pruning separately.
  [Chart history](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/Changelog.md),
  [application migration notes](https://github.com/traefik/traefik/blob/v3.7.17/docs/content/migrate/v3.md).
- **ExternalDNS:** explicitly keep `external-dns.alpha.kubernetes.io/`.
  Otherwise the 0.22 annotation-default change would stop recognizing the
  annotations used throughout this repository. Existing AWS/DynamoDB ownership
  and `policy: sync` are unchanged.
  [0.22 release](https://github.com/kubernetes-sigs/external-dns/releases/tag/v0.22.0).
- **Argo CD:** explicitly retain `global.networkPolicy.create: false` because
  chart 10 enables policies by default. Network isolation can be reviewed
  separately. The new controller headless Service does not conflict with an
  existing live Service. Argo 3.5 introduces Helm 4; 3.6 uses server-side diff
  for SSA applications. The charts were rendered with local Helm 4.2.3.
  [3.5 migration](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.4-3.5/),
  [3.6 migration](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.5-3.6/).
- **Image ownership:** Authentik now renders 2026.8.5 and Vikunja 2.8.0 from
  their charts. OpenProject's memcached still renders the same archived
  1.6.24 image after removal of its redundant tag; replacing that dependency
  needs separate work. The upstream OpenProject model replaced by the local
  ConfigMap is identical between 17.5.1 and 17.9.6.

## Deferred migrations and interactive steps

1. **cert-manager:** deploy and verify 1.20.5, then prepare a separate chart
   bump to 1.21.3. Upstream recommends one minor release at a time. Check
   issuance, renewal and Route53 access between steps. The current configuration
   does not use the removed 1.21 self-TokenRequest RBAC pattern.
   [Upgrade procedure](https://cert-manager.io/docs/installation/upgrade/).
2. **Loki community chart migration:** the configured `grafana` chart switched
   to Enterprise Logs maintenance at chart 7.0. Its 7.5.0 `appVersion: 3.6.16`
   describes GEL; the OSS default actually renders **3.6.11**. Keep that default
   for this interim update. The maintained OSS target is
   `https://grafana-community.github.io/helm-charts`, chart **21.0.0**, app
   **3.7.9**. That migration renames the deployment mode to Monolithic, removes
   obsolete values, changes monitoring labels (`cluster` to `app_instance`),
   recording rules and dashboard resources, and separates alert configuration.
   It needs a coordinated metrics/dashboard review and cleanup of superseded
   resources because Argo does not prune automatically. Local trial rendering
   preserved the data claim and StatefulSet selector, but that alone does not
   validate the monitoring migration. The pre-18 community release **17.4.11**
   preserves the old ServiceMonitor and recording rules, but already replaces
   the two dashboard ConfigMaps with individual dashboard resources. That
   intermediate migration also needs explicit ownership/cleanup work; it is
   not a safe way to avoid the transition. Do not clear the OSS tag to adopt
   GEL's `appVersion`.
   [Repository split](https://github.com/grafana/loki/blob/main/production/helm/loki/CHANGELOG.md),
   [community upgrade guide](https://github.com/grafana-community/helm-charts/tree/main/charts/loki#upgrading).
3. **GitHub and Spotify MCP:** chart **0.5.1** is the last compatible release
   before **0.6.0** switches from `@michlyn/mcpgateway` to `supergateway`.
   Both services explicitly pin the former. New templates change transport
   spelling and CLI flags, so a chart-only bump to 0.7 would break those commands.
   Migrate the gateway deliberately and test initialization, tool calls,
   session persistence, OAuth forwarding and Spotify token refresh.
   The Helm dependency, lock and vendored package are updated together.
   [Migration instructions](https://github.com/javdet/mcp-helm-chart#migrating-from-05x).
4. **CNPG before 1.31:** 1.30.1 remains compatible with native
   `barmanObjectStore`. Before 1.31, install the Barman Cloud plugin, create its
   ObjectStore configuration, move cluster WAL archiving and ScheduledBackup to
   the plugin, and verify backup/restore before upgrading the operator again.
   Keep PostgreSQL major upgrades separate. The
   [existing DatabaseRole plan](cnpg-130-database-consumer-plan.md) now refers
   to the staged 1.30.1 operator; its consumer-resource refactor is not implemented.
   [CNPG 1.30 release notes](https://cloudnative-pg.io/docs/1.30/release_notes/v1.30/).
5. **Vault:** chart sync changes the StatefulSet template but does not replace
   the single `vault-0` pod under `OnDelete`. Take a Raft snapshot, arrange the
   restart interactively, then verify unseal, Kubernetes login and ESO reads.
   Do not switch to automatic rolling updates as part of this version bump.
6. **Open WebUI:** take a database/data backup and update the single StatefulSet
   instance during a maintenance window. 0.13 has schema migrations and forbids
   mixed-version rolling deployments. The current one-replica StatefulSet
   avoids that overlap. A chart rollback alone is not a database rollback.
   [0.13 upgrade notes](https://github.com/open-webui/open-webui/releases/tag/v0.13.0).

For rollout, first back up stateful applications and verify restoration paths.
Apply monitoring CRDs **32.0.2 before monitoring 92.22.0**, and CNPG operator/CRDs
before the cluster chart. Verify the new monitoring token Secret and scrape
targets after the stack update. Upgrade Argo CD separately and verify Helm 4
rendering in its repo-server before syncing the remaining applications. Check
Traefik/Authentik login and forwarded scheme handling together; confirm the
ExternalDNS plan before allowing its existing sync policy to change DNS.
Keep storage and database operator rollouts separate from application rollouts
on this single-node cluster. Review automated sync before eventually publishing
the commit: the catalog normally follows `main` with self-healing enabled.

## Installed workloads without a chart-controlled application version

These remain unchanged under the requested no-image-tag-bumps rule. A floating
`latest` image is not proof that the running digest contains the newest release.
Custom application builds cannot be ranked against a public upstream version.

| Workload | Installed reference | Current upstream release or required follow-up |
| --- | --- | --- |
| ntfy / push | `binwiederhier/ntfy:latest` | [2.37.2](https://github.com/binwiederhier/ntfy/releases/tag/v2.37.2); resolve deployed digest before comparing application versions. |
| Apprise | `caronc/apprise:latest` | [Apprise API 2.0.2](https://github.com/caronc/apprise-api/releases/tag/v2.0.2); API image version differs from the library version. |
| Filestash | `machines/filestash:latest` | No stable release number established from the public releases endpoint; needs digest/build comparison. |
| HabitSync | `ghcr.io/jofoerster/habitsync:latest` | [0.19.3](https://github.com/jofoerster/habitsync/releases/tag/v0.19.3); local chart hardcodes an explicit image value. |
| Object-store gateways | `rclone/rclone:latest` | [1.76.0](https://github.com/rclone/rclone/releases/tag/v1.76.0); local chart, digest/version verification needed. |
| Mail relay | Maddy 0.9.5; custom PGP gateway 0.1.1 | [Maddy 0.9.7](https://github.com/foxcpp/maddy/releases/tag/v0.9.7), including security fixes; custom gateway requires its own build/release review. |
| Mail test | smtp4dev 3.9.0 | [3.16.1](https://github.com/rnwood/smtp4dev/releases/tag/3.16.1); standalone Deployment. |
| llama-server | `server-b9976` | [llama.cpp v0.9.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.9.0); validate model/CLI/API compatibility separately. |
| Assistant, NeMo ASR, Pocket TTS | Custom `sha-68ec995` builds | Repository-specific releases; retained. |
| OIDC document server | nginx-unprivileged `1.27-alpine` | NGINX [stable 1.30.6 / mainline 1.31.8](https://nginx.org/en/download.html); review wrapper image and configuration together. |
| SSO debug | whoami 1.11.0 | [1.12.0](https://github.com/traefik/whoami/releases/tag/v1.12.0); standalone manifest. |
| Odoo, outside the Argo catalog | Odoo 15.0, archived PostgreSQL 16.2.0, nginx `latest` | [Odoo 20](https://github.com/odoo/documentation/blob/20.0/content/administration/standard_extended_support.rst) requires a planned database and custom-module migration. Do not replace its image in place. |
| Default-namespace nginx, outside the catalog | nginx-unprivileged `latest` | Establish ownership and deployed build before upgrading. |
| GitHub/Spotify runtime dependencies | Node 20; mcpgateway 4.0.4; GitHub mcp-remote 0.1.38; Spotify fork `master` | mcpgateway 4.0.4 is current; mcp-remote is 0.16.5. Review alongside gateway migration. [Node 20 is EOL](https://nodejs.org/en/about/previous-releases); move runtimes to supported LTS images in that work. |

Kubernetes, Talos and Flannel are also outside Helm application upgrades:
live **1.34.1 / 1.13.5 / 0.27.4** versus latest
[Kubernetes 1.37.2](https://github.com/kubernetes/kubernetes/releases/tag/v1.37.2),
[Talos 1.14.5](https://github.com/siderolabs/talos/releases/tag/v1.14.5), and
[Flannel 0.28.10](https://github.com/flannel-io/flannel/releases/tag/v0.28.10).
Plan Kubernetes minor steps **1.34 → 1.35 → 1.36 → 1.37**, with the supported
Talos/Kubernetes matrix and ZFS system extension checked at each step. Kubernetes
1.34 is outside the current three supported minor branches.
[Version skew and upgrade order](https://kubernetes.io/releases/version-skew-policy/).
The root and mcp-access Applications contain orchestration/RBAC, not separate
application binaries to version.

## Optional features and simplifications

- **CNPG DatabaseRole:** can replace centrally maintained consumer roles with
  per-service declarative resources. This directly supports the existing
  [consumer migration plan](cnpg-130-database-consumer-plan.md).
- **Authentik 2026.8:** dynamic client registration and OAuth token exchange /
  on-behalf-of flows may simplify the custom agent/MCP authentication setup.
  This is a candidate redesign, not an automatic replacement for the existing
  scopes and identity forwarding. User switching is another opt-in feature.
  [Release notes](https://docs.goauthentik.io/releases/2026.8/).
- **Vikunja:** 2.7 adds native MCP access and scoped read-only tokens; consider
  using it instead of an external adapter. 2.8 adds recoverable trash and
  explicit OIDC account linking. Standard `groups` claim support may simplify
  future group mapping; the current OIDC scope does not request group sync.
  [2.7](https://vikunja.io/changelog/vikunja-2.7.0-was-released/),
  [2.8](https://vikunja.io/changelog/vikunja-2.8.0-was-released/).
- **Open WebUI:** tool search can reduce MCP tool-definition context usage;
  newer releases add multi-file skills, realtime voice, and MCP Apps. Realtime
  voice needs a compatible Realtime API and does not directly replace the
  current NeMo/Pocket TTS pair. Desktop/browser tabs require an Open Terminal
  connection, currently disabled. The single WebUI replica can also run without
  its dedicated Redis websocket manager; that is an existing simplification
  opportunity, not a new requirement. Leave Redis in place until reconnect and
  chat-stream behavior are tested.
  [0.12](https://github.com/open-webui/open-webui/releases/tag/v0.12.0),
  [0.13](https://github.com/open-webui/open-webui/releases/tag/v0.13.0),
  [chart history](https://github.com/open-webui/helm-charts/blob/main/charts/open-webui/CHANGELOG.md).
- **MCP chart 0.5:** native ConfigMap mounting and checksum-triggered restarts
  could replace part of the wrapper's script ConfigMap code. Executable mode
  and interpreter invocation need checking; the wrapper still owns Authentik,
  NetworkPolicy, extra Secrets and PVCs.
  [Chart documentation](https://github.com/javdet/mcp-helm-chart).
- **Grafana:** Git Sync/provisioning improvements could replace some dashboard
  sidecar management if adopted deliberately; compare permissions and dashboard
  ownership before changing the current ConfigMap workflow. View-panel controls
  and improved query-variable editing are also available. Saved queries are
  Enterprise/Cloud features, not an OSS simplification here.
  [13.2 features](https://grafana.com/docs/grafana/latest/whatsnew/whats-new-in-v13/whats-new-in-v13-2/),
  [13.3 changes](https://github.com/grafana/grafana/releases/tag/v13.3.0).
- **Traefik:** wildcard Host matching can simplify suitable route rules.
  Consider `aliasHeadersStrategy` hardening for Authentik/forward-auth routes,
  `strictTLSOptions`, and restricting default TLS resources to an operator-owned
  namespace. These are opt-in and were not silently enabled. Enabling safe
  naming requires migrating cross-provider middleware references.
  [Migration and security options](https://github.com/traefik/traefik/blob/v3.7.17/docs/content/migrate/v3.md).
- **VolSync/OpenEBS:** VolSync adds sparse restores and keep-within retention;
  OpenEBS adds optional snapshot-controller ownership and ZFS `atime`/`logbias`
  tuning. The existing controller is still needed, so it was not disabled.
  [VolSync 0.17](https://github.com/backube/volsync/releases/tag/v0.17.0),
  [OpenEBS 4.6](https://github.com/openebs/openebs/releases/tag/v4.6.0).

The Alloy log classifier, Loki log-level setting, kubelet API-proxy scrape
configuration, object-store gateway and OpenProject custom model mount remain
necessary under the reviewed configuration; no demonstrated replacement was
found. Alertmanager's custom-payload parsing fix improves ntfy delivery, but the
existing `toJson` escaping is still appropriate.
[Payload fix](https://github.com/prometheus/alertmanager/pull/5304).

## Validation

- Rendered all **21 proposed remote charts** against Kubernetes 1.34.1 with
  the configured values and monitoring APIs. Compared existing resource names,
  workload selectors, PVC specs, StatefulSet claim templates/service names and
  Service IPs: no changes to those invariants in the prepared upgrades.
- Rendered and strictly linted all **8 local Helm application configurations**
  with Helm 4.2.3, including both MCP consumers. Dependency status is `ok`.
- **19 remote charts pass strict Helm lint.** cert-manager's upstream `v`
  prefix produces a SemVer warning; the CRD-only monitoring chart warns that it
  has no `templates/` directory. Both render and pass ordinary lint. No chart
  packaging was patched or diagnostics suppressed to hide these warnings.
- Changed YAML passes the repository's relaxed yamllint configuration.
  ApplicationSet/project regeneration produces no additional changes;
  `git diff --check` and the repository's `prek` hooks pass on the changed files.
- Large CRDs retain server-side apply via existing application settings or
  chart-provided annotations. The monitoring CRDs match the selected operator.
- These are local compatibility checks, not a deployed upgrade or restore test.
  The interactive rollout checks above remain necessary.
