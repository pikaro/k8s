# Cross-Service Configuration Ownership Audit

Date: 2026-07-13

## Status

The repository contains several split ownership contracts where a consumer and
its provider must be configured independently. Git stores both halves, but
nothing consistently guarantees that they agree before ArgoCD or another
controller attempts reconciliation.

At commit `c7eb1d7`, the OpenWebUI restic registration has been added to the
object-store gateway. The five active backup consumers now match the gateway
registry. This resolves that specific repository mismatch after ArgoCD syncs,
but it does not remove the underlying drift risk.

## Summary

| Area | Provider-side configuration | Consumer-side configuration | Current state |
| --- | --- | --- | --- |
| Restic backups | Gateway `restic.users` registry | Per-app `backups.yaml` | Sets match; structurally unsafe |
| S3 credentials | Gateway `s3.readers` registry | Filestash and CNPG SecretStores | Sets match |
| PostgreSQL | CNPG roles, passwords, Database CRs, and RBAC | App SecretStores, copied Secrets, and connection values | Sets match; heavily duplicated |
| AWS IAM | OpenTofu trust policies and role outputs | Kubernetes ServiceAccount names and hardcoded role ARNs | Values match; not derived |
| Authentik and OIDC | Catalog consumed by OpenTofu | App Secret names and OIDC settings | Partly derived; separate apply required |
| Durable generated secrets | ESO generators and PushSecrets | App-local Secrets | At least one incomplete recovery path |

## Object-store consumers

Every restic consumer must appear in both:

- its app configuration, such as
  `services/app/openwebui/backups.yaml`; and
- the gateway's central registry in
  `services/platform/object-store-gateway/values.yaml`.

The gateway registry generates all of the following:

- password generators;
- provider-side Secrets;
- htpasswd entries;
- Roles; and
- cross-namespace RoleBindings.

The app-side `helm/volsync-restic-consumer` chart independently creates:

- the consumer ServiceAccount;
- the Kubernetes-provider `SecretStore`;
- the copied credential Secret; and
- the VolSync `ReplicationSource`.

External Secrets Operator exposes a missing authorization during provider
validation, but it does not provision the provider-side Role or RoleBinding.
Forgetting the gateway registry entry therefore produces errors such as:

```text
InvalidProviderConfig: client is not allowed to get secrets
```

The same pattern exists for S3 credentials through `s3.readers`, currently
with Filestash and CNPG as consumers.

### Current namespace duplication

OpenWebUI's requirements create its namespace in
`services/app/openwebui/requirements/namespace.yaml`, while its backup values
leave the consumer chart's `createNamespace` setting at the default of `true`.
Two sources in the same ArgoCD Application therefore render the same Namespace.
OpenProject avoids this by explicitly setting `createNamespace: false`.

## CNPG database consumers

Each database identity is repeated across four ownership surfaces:

1. The central `cluster.roles` list in
   `services/base/cnpg-cluster/values.yaml`.
2. Provider-side password generation, credential Secret, `Database`, Role, and
   RoleBinding resources.
3. App-side ServiceAccount, `SecretStore`, and copied Secret resources.
4. The application's database connection configuration.

The active consumer sets currently agree:

- `authentik`
- `habitsync`
- `openproject`
- `openwebui`

Their layout is not consistent. Authentik owns its password, `Database`,
provider RBAC, and consumer synchronization beneath
`services/base/authentik/requirements`. HabitSync, OpenProject, and OpenWebUI
place their provider-side resources beneath
`services/base/cnpg-cluster/requirements`, while their consumer-side resources
remain with the applications.

This makes generic validation and migration harder and creates ordering
dependencies between independently reconciled Applications.

### Existing CNPG 1.30 plan has drifted

`docs/cnpg-130-database-consumer-plan.md` proposes the correct ownership
direction: use the CNPG `DatabaseRole` CRD and a service-owned database-consumer
chart.

The plan currently omits OpenWebUI from:

- the stated consumer list;
- proposed AppProject destinations;
- per-service values files;
- the central role-removal list;
- migration steps; and
- validation commands.

The installed CNPG operator chart also remains at `0.28.3`, so the planned
migration has not occurred. Following the plan as written would leave
OpenWebUI on the old split configuration.

### Credential recovery hazard

The provider credential Secrets and app-facing copies use
`refreshPolicy: CreatedOnce`. If a provider credential is regenerated after
Secret loss, CNPG can receive the new password while an existing app-facing
Secret retains the old password. The database and application credentials can
then diverge.

The migration must preserve stable Secrets during resource ownership changes,
but it should also define and test the intended credential-loss and rotation
behavior explicitly.

## AWS IAM and Kubernetes identity

OpenTofu trust policies hardcode Kubernetes identities such as:

```text
system:serviceaccount:cert-manager:cert-manager
system:serviceaccount:external-dns:external-dns
system:serviceaccount:external-secrets:external-secrets
system:serviceaccount:vault:vault
```

The corresponding Helm values independently determine the ServiceAccount
names. The OpenTofu-created role ARNs are also manually repeated, including the
AWS account ID, in:

- `services/platform/cert-manager/values.yaml`;
- `services/platform/external-dns/values.yaml`;
- `services/platform/external-secrets/values.yaml`; and
- `services/platform/vault/values.yaml`.

These values currently agree, but the Kubernetes consumers do not derive the
role ARNs or trusted subjects from the provider-owned values. This violates the
repository contract that mechanically derivable configuration should not be
hardcoded by consumers.

## OpenTofu-managed Kubernetes Secrets

OpenTofu directly creates Kubernetes Secrets for:

- Authentik OIDC clients;
- Authentik service accounts;
- Grafana MCP;
- push/ntfy; and
- Apprise.

The ArgoCD catalog is a useful single source for most Authentik applications,
but reconciliation still requires a separate OpenTofu run. ArgoCD cannot
repair those Authentik resources or Kubernetes Secrets from Git by itself.

Grafana MCP and push/apprise are more directly split between handwritten
OpenTofu resources and Kubernetes workload configuration. Their consumers
hardcode the Secret names created outside ArgoCD.

## Durable generated-secret recovery

Filestash generates `FILESTASH_SECRET_KEY` locally and pushes it to SSM in
`services/app/filestash/externalsecrets.yaml`.

The SSM copy is not used as a restore source. If the Kubernetes Secret is lost:

1. ESO generates a new local encryption key.
2. `PushSecret` does not overwrite the old SSM value because it uses
   `updatePolicy: IfNotExists`.
3. Filestash starts with the new local key.
4. The durable SSM copy still contains the old key, but no resource restores it.

The apparent backup path therefore cannot restore the application's encryption
identity and may make existing encrypted state unreadable.

## Recommended remediation order

### 1. Add repository consistency validation

Add checks that fail before reconciliation when:

- active backup namespaces differ from `restic.users`;
- S3 consumers differ from `s3.readers`;
- CNPG roles, password Secrets, `Database` resources, RBAC subjects, and app
  consumers differ;
- an IAM trusted subject differs from the rendered ServiceAccount identity; or
- multiple sources render the same resource with conflicting configuration.

These checks are an immediate guardrail, not a replacement for correcting
ownership.

### 2. Complete the CNPG 1.30 consumer migration

Update `docs/cnpg-130-database-consumer-plan.md` to include OpenWebUI throughout,
then implement the service-owned `DatabaseRole` and database-consumer chart.

A service's `cnpg.yaml` should become the sole declaration from which the
following are rendered:

- `DatabaseRole`;
- `Database`;
- generated credentials;
- provider-side RBAC;
- consumer `SecretStore`; and
- app-facing Secret.

The narrow `cnpg-consumer` ArgoCD project proposed by the existing plan should
allow only the namespaces and resource kinds required by this chart.

### 3. Introduce an object-storage consumer API

The clean ownership model is a namespaced claim, such as a
`ResticRepositoryClaim`, reconciled by a controller that provisions:

- gateway credentials;
- gateway authorization and htpasswd state;
- the consumer credential Secret; and
- repository connection information.

A narrowly scoped cross-namespace consumer chart can improve repository
locality without a controller, but it cannot safely eliminate the gateway's
aggregate htpasswd registry by itself.

### 4. Derive cloud identity configuration

Establish one authoritative cluster identity definition or generated interface
for:

- AWS account and region;
- role names and ARNs;
- Kubernetes ServiceAccount namespaces and names; and
- OIDC trusted subjects.

Add validation until all consumer values can be mechanically derived from that
source.

### 5. Make durable secret storage authoritative

For application encryption keys and other irreplaceable credentials, SSM must
be the restore source rather than only an export destination. Bootstrap logic
must be idempotent and tested for both an empty cluster and loss of the local
Kubernetes Secret.

## Desired ownership rule

A service should declare each external dependency once, within its own service
configuration. Provider-specific resources may still need to be rendered into
the provider namespace, but they should be derived from that declaration or
reconciled from a namespaced claim. A change should not require remembering a
second provider registry elsewhere in the repository.
