# Personal External MCP

Repo-local wrapper for personal, single-principal MCP services backed by
external SaaS credentials.

The chart depends on `javdet/mcp` for the MCP Deployment, Service, Ingress, and
primary ExternalSecret. This wrapper adds the cluster conventions that are not
specific to that generic chart:

- Authentik embedded outpost `IngressRoute`
- ingress-only `NetworkPolicy`
- optional script ConfigMap for gateway stdio commands
- optional extra ExternalSecrets for mounted files

Each service supplies its backend-specific configuration through the `mcp:`
values block and is expected to use an Authentik catalog entry with
`authentik.accessGroups`.

The Spotify service uses `gupta-kush/spotify-mcp`. It is installed from the
GitHub repository archive at runtime because the current PyPI `spotify-mcp`
package name resolves to a different older implementation.

## Catalog-backed SSM parameters

Services declare required SSM placeholders in their Argo catalog entry under
`externalSecrets.ssmParameters`. `terraform/aws` creates each one at
`/${external_secrets_ssm_prefix}/<path>` as a `SecureString` with the initial
value `undefined` and then ignores future value changes.

The matching Helm values still reference the concrete ExternalSecret
`remoteRef.key` values because ArgoCD and Terraform render independently. The
catalog declaration is authoritative for creating the backing SSM parameter.

Current catalog-backed parameters:

- `/external-secrets/mcp/github/personal-access-token`
- `/external-secrets/mcp/spotify/client-id`
- `/external-secrets/mcp/spotify/token-cache`

## Spotify token cache

The Spotify token cache value is the Spotipy `.spotify_token_cache` JSON content
for the personal account. It contains the user OAuth grant, including the
refresh token and access-token expiry metadata.

The Spotify client ID identifies the Spotify application, but it does not
authorize access to personal playback, library, or listening-history data on its
own. The selected `gupta-kush/spotify-mcp` server uses PKCE auth, so no Spotify
client secret is required. The MCP pod is not expected to run an interactive
browser OAuth callback, so the account authorization is seeded through this
cache file. The startup script copies it into a writable `emptyDir` before
launching the stdio server so access-token refresh can update the runtime cache
without mutating the Kubernetes Secret.
