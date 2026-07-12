# simple-web-service

An opinionated local Helm chart for HTTP services that do not provide their own
chart. It deploys a namespaced `Deployment` and `ClusterIP` `Service`, with
optional persistence and public ingress.

Ingress traffic is denied by default by an ingress-only `NetworkPolicy`, except
for pods in the service's own namespace. Add every namespace that needs to call
the service to `networkPolicy.ingressNamespaces`. An ingress-enabled service
must therefore include its ingress controller namespace, normally `traefik`.

The chart does not create OIDC credentials. Applications consume the OIDC
Secret generated from their ArgoCD catalog entry through `container.env` or
`container.envFrom`. Services protected by the Authentik proxy can additionally
enable `ingress.authentikOutpost` and configure the Traefik forward-auth
middleware annotation.

```yaml
namespace: example

image:
  repository: ghcr.io/example/service
  tag: sha-0123456

container:
  port: 8080
  env:
    OIDC_ISSUER:
      valueFrom:
        secretKeyRef:
          name: example-sso
          key: issuer

ingress:
  enabled: true
  host: example.d-reis.com
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    external-dns.alpha.kubernetes.io/hostname: example.d-reis.com
    traefik.ingress.kubernetes.io/router.entrypoints: websecure

networkPolicy:
  ingressNamespaces:
    - traefik
    - calling-application
```
