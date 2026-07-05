# GitHub MCP

Personal single-principal GitHub MCP service exposed at
`https://github.mcp.k8s.d-reis.com`.

The service proxies the GitHub Copilot MCP endpoint through `mcp-remote` and
passes a personal access token as the upstream authorization header. Access is
limited through the `personal-mcp-users` Authentik group.

## Credentials

The Argo catalog entry declares the required SSM placeholder:

- `/external-secrets/mcp/github/personal-access-token`

Set this parameter to the personal GitHub token that should back the server.
The token is privileged personal access, so this service should remain
single-principal.

## Toolsets

`GITHUB_TOOLSETS` defaults to `default,actions` in `values.yaml`.
