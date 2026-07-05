# Spotify MCP

Personal single-principal Spotify MCP service exposed at
`https://spotify.mcp.k8s.d-reis.com`.

The service uses `gupta-kush/spotify-mcp`. It is installed from the GitHub
repository archive at container startup because the current PyPI `spotify-mcp`
package name resolves to a different older implementation. Access is limited
through the `personal-mcp-users` Authentik group.

## Credentials

The Argo catalog entry declares the required SSM placeholder:

- `/external-secrets/mcp/spotify/client-id`

Set this parameter to the Spotify developer app client ID. No Spotify client
secret is used; `gupta-kush/spotify-mcp` uses PKCE auth.

Register this redirect URI on the Spotify developer app:

```text
http://127.0.0.1:8888/callback
```

The same redirect URI is configured in the cluster so the locally generated
OAuth grant can refresh server-side.

## Token Cache

The Spotify token cache is the Spotipy `.spotify_token_cache` JSON content for
the personal account. It contains the user OAuth grant, including the refresh
token and access-token expiry metadata.

The cache is mutable refresh state. It is stored on the `spotify-mcp-cache` PVC
mounted at `/spotify-cache`, not in SSM. The pod startup script fails until
`/spotify-cache/.spotify_token_cache` exists and passes a lightweight
`current_user()` auth preflight.

Generate the cache with a clean environment that does not set
`SPOTIFY_CLIENT_SECRET` and does not load a local `.env` file. A cache generated
through the traditional client-secret OAuth flow may fail to refresh when the
cluster uses PKCE-only auth.

If the SSM parameter is still `undefined`, set it first:

```sh
set -eu

printf "Spotify client ID: "
IFS= read -r SPOTIFY_CLIENT_ID

aws ssm put-parameter \
  --name /external-secrets/mcp/spotify/client-id \
  --type SecureString \
  --value "$SPOTIFY_CLIENT_ID" \
  --overwrite
```

Run this from a local shell with AWS credentials and a browser available. It
generates a PKCE token cache without using a Spotify client secret:

```sh
set -eu

SPOTIFY_CLIENT_ID="$(
  aws ssm get-parameter \
    --name /external-secrets/mcp/spotify/client-id \
    --with-decryption \
    --query Parameter.Value \
    --output text
)"

if [ -z "$SPOTIFY_CLIENT_ID" ] || [ "$SPOTIFY_CLIENT_ID" = "undefined" ]; then
  echo "Set /external-secrets/mcp/spotify/client-id before bootstrapping." >&2
  exit 1
fi

SPOTIFY_BOOTSTRAP_DIR="$(mktemp -d)"
python3 -m venv "$SPOTIFY_BOOTSTRAP_DIR/venv"
"$SPOTIFY_BOOTSTRAP_DIR/venv/bin/python" -m pip install --upgrade pip
"$SPOTIFY_BOOTSTRAP_DIR/venv/bin/pip" install \
  "https://github.com/gupta-kush/spotify-mcp/archive/refs/heads/master.zip"

env -i \
  HOME="$SPOTIFY_BOOTSTRAP_DIR" \
  PATH="$SPOTIFY_BOOTSTRAP_DIR/venv/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
  SPOTIFY_CLIENT_ID="$SPOTIFY_CLIENT_ID" \
  SPOTIFY_REDIRECT_URI="http://127.0.0.1:8888/callback" \
  SPOTIFY_CACHE_DIR="$SPOTIFY_BOOTSTRAP_DIR" \
  "$SPOTIFY_BOOTSTRAP_DIR/venv/bin/python" \
    -c 'from spotify_mcp.auth import get_spotify_client; print(get_spotify_client().current_user()["id"])'

test -s "$SPOTIFY_BOOTSTRAP_DIR/.spotify_token_cache"
printf "Token cache generated at: %s/.spotify_token_cache\n" "$SPOTIFY_BOOTSTRAP_DIR"
```

Complete the Spotify browser login when prompted. Keep the same shell open so
`SPOTIFY_BOOTSTRAP_DIR` is still set, then copy the generated cache into the
cluster PVC:

```sh
set -eu

test -s "$SPOTIFY_BOOTSTRAP_DIR/.spotify_token_cache"

until kubectl -n mcp-personal get pvc spotify-mcp-cache >/dev/null 2>&1; do
  echo "Waiting for spotify-mcp-cache PVC to exist..."
  sleep 2
done

until [ "$(kubectl -n mcp-personal get pvc spotify-mcp-cache -o jsonpath='{.status.phase}')" = "Bound" ]; do
  echo "Waiting for spotify-mcp-cache PVC to be Bound..."
  sleep 2
done

kubectl -n mcp-personal delete pod spotify-mcp-cache-bootstrap --ignore-not-found=true
while kubectl -n mcp-personal get pod spotify-mcp-cache-bootstrap >/dev/null 2>&1; do
  echo "Waiting for old spotify-mcp-cache-bootstrap pod to be deleted..."
  sleep 1
done

kubectl -n mcp-personal apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: spotify-mcp-cache-bootstrap
spec:
  restartPolicy: Never
  volumes:
    - name: spotify-cache
      persistentVolumeClaim:
        claimName: spotify-mcp-cache
  containers:
    - name: bootstrap
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: spotify-cache
          mountPath: /spotify-cache
EOF

kubectl -n mcp-personal wait --for=condition=Ready pod/spotify-mcp-cache-bootstrap --timeout=120s
kubectl -n mcp-personal cp "$SPOTIFY_BOOTSTRAP_DIR/.spotify_token_cache" spotify-mcp-cache-bootstrap:/spotify-cache/.spotify_token_cache
kubectl -n mcp-personal exec spotify-mcp-cache-bootstrap -- chmod 0600 /spotify-cache/.spotify_token_cache
kubectl -n mcp-personal exec spotify-mcp-cache-bootstrap -- ls -l /spotify-cache/.spotify_token_cache
kubectl -n mcp-personal delete pod spotify-mcp-cache-bootstrap
kubectl -n mcp-personal rollout restart deployment/spotify-mcp
kubectl -n mcp-personal rollout status deployment/spotify-mcp --timeout=180s
```

The old `spotify-mcp-token-cache` ExternalSecret and Secret are no longer used.
Because ArgoCD pruning is disabled for appsets, remove those live objects
manually after the PVC-backed pod is healthy:

```sh
kubectl -n mcp-personal delete externalsecret spotify-mcp-token-cache --ignore-not-found=true
kubectl -n mcp-personal delete secret spotify-mcp-token-cache --ignore-not-found=true
```
