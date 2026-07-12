# k8s

This repo is the GitOps and OpenTofu source for the Thule Kubernetes cluster.

## Deployment Pattern

1. Render and validate local state before pushing:

   ```sh
   argocd/appsets/generate.sh
   ```

2. Sync early GitOps apps that create namespaces or CRDs without generated
   Secret dependencies. For observability, sync `monitoring-crds` first; it
   creates the `observability` namespace and installs Prometheus Operator API
   types.

3. Apply OpenTofu modules that produce consumer Secrets before syncing apps
   that require those Secrets. Run each module only after its target namespace
   and upstream service dependencies exist. Current readiness modules are:

   ```sh
   tofu -chdir=terraform/aws apply
   tofu -chdir=terraform/sso apply
   tofu -chdir=terraform/push apply
   ```

   `terraform/aws` also owns the shared VolSync Restic repository password in
   SSM Parameter Store. Apply it before syncing app backup resources.
   External Secrets may export cluster-generated encryption keys as encrypted
   parameters beneath `/external-secrets/exports/`; its IAM write access is
   restricted to that subtree.
   It also owns the Vault auto-unseal IAM role and KMS alias. Apply it before
   syncing the `vault` Application.

   After Vault is initialized and `terraform/sso` has created `vault-sso`,
   apply `~/src/dre/vault`. That configuration owns Vault's API state,
   including the namespace-isolated `k8s/` KV mount and Kubernetes auth role.
   Apply it before syncing applications that create Vault-backed
   `SecretStore` or `PushSecret` resources.

   `terraform/push` owns generated ntfy users, tokens, ACL config, Apprise
   destination config, and the mobile client Secret. The push and Apprise
   Deployments stay in Kubernetes/GitOps; OpenTofu only writes the generated
   Secret inputs they consume.

4. Sync ArgoCD apps. For observability notifications, sync or resync:

   - `push`
   - `apprise`
   - `monitoring`

   For PVC backups, sync `object-store-gateway`, then `volsync`, then resync
   the backed-up app Applications. Current VolSync backup declarations live
   with the owning apps and use Restic retention of 7 daily, 4 weekly, and 12
   monthly snapshots. The mover uses Snapshot copy mode through the
   `zfs-snapshot` VolumeSnapshotClass so live RWO PVCs are not mounted directly.
   It uses Restic's REST backend against the `object-store-gateway` Restic
   endpoint. That endpoint is backed by rsync.net over the gateway's single SSH
   key and uses per-namespace private-repository credentials generated in
   `object-store`; app namespaces pull only their own connection Secret through
   External Secrets.

Observability PVCs are disposable readiness/debugging state. Do not treat
Prometheus, Loki, Grafana, Alertmanager, Apprise, or ntfy local state as backup
targets unless the backup policy changes explicitly.
