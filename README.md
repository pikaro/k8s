# Hetzner server Talos installation

Best guide but very outdated:
[here](https://datavirke.dk/posts/bare-metal-kubernetes-part-1-talos-on-hetzner/)

> [NOTE]\
> Use `bash` -> `unset HISTFILE` -> `...` -> `exit` when entering any secrets

> [WARNING]\
> Server seemed to change `nvme0` and `nvme1` between reboots?! Triple check
> which is which before messing with partitions.

## Install Talos

> [WARNING]\
> Activating the firewall (incoming rule to allow only admin IP on ALL ports)
> blocked outgoing requests and thus boot for some reason.

> [WARNING]\
> Hetzner does NOT support SecureBoot! Do not use a SecureBoot image.

- Install `talosctl` on local machine (Nix or brew)

- Activate rescue system

- `curl ident.me`

- Block the following ports:

    - 6443
    - 50000-50001
    - 2379-2380
    - 10250
    - 10259
    - 10257

- Allow your own IP on ALL ports

- Reboot

- Connect via SSH

- `lsblk`

- Check if `md*` are present

    - If so, `mdadm --stop /dev/md* /dev/md/*`
    - `mdadm --zero-superblock /dev/nvme0n1` etc. for RAID members (depends on
        layout)
    - `sfdisk --delete /dev/nvme0n1` etc.
    - `wipefs -a /dev/nvme0n1` etc.

- Look up latest Talos version
    [here](https://github.com/siderolabs/talos/releases) (may be out of order)

- Edit `image.yml` to add extensions if needed

- `./image.sh` and note the generated ID

- `wget https://factory.talos.dev/image/<id>/v<version>/metal-amd64.raw.zst`

- `unzstd metal-amd64.raw.zst`

- `dd if=metal-amd64.raw of=/dev/nvme0n1 bs=4M oflag=direct status=progress`

- `reboot`

- `nmap -p 50000 <server-ip>` until port is open

## Configure Talos

> [WARNING]\
> Do not use hostname unless IPv6 is available - `talosctl` seems to prefer
> IPv6.

> [WARNING]\
> The generated config files contain secrets!

> [WARNING]\
> If anything goes wrong / you missed a config step, before `bootstrap`, you can
> just `talosctl -n <ip> reset` and start over - no need to re-flash Talos. This
> turns the server off - you need to power it on again via Hetzner console or
> API.

- Prepare autocomplete with `talosctl completion zsh > ...`

- `talosctl gen secrets --output-file build/secrets.yaml` and back up securely

- Review `patches/controlplane.yaml` for needed changes

- Create `.env`:

    ```
    export IMAGE_ID=4dd8e3a8b6203d3c14f049da8db4d3bb0d6d3e70c5e89dfcc1e709e81914f63
    export TALOS_VERSION=1.11.5
    export CLUSTER_NAME=hyperborea
    export NODE_IP=95.217.36.114
    ```

- Generate the config:

    ```
    ./build.sh firewall controlplane
    ```

- `talosctl apply-config --insecure -n <ip> --file build/thule.yaml `

- Generate `talosconfig`:

    ```
    talosctl gen config \
        --with-secrets build/secrets.yaml \
        --output-types talosconfig \
        --output build/talosconfig \
        <cluster-name> \
        https://<node-ip>:6443
    ```

- `cat build/talosconfig > ~/.talos/config` (preserves permissions)

- `talosctl config endpoint <ip>` and `talosctl config node <ip>`

- `talosctl bootstrap`

- `talosctl dashboard` and watch k8s bootstrapping

- `talosctl kubeconfig`

> [INFO]\
> Various "connection refused" and authentication errors seem to be normal
> during this process as components come online.

- Change machine config after setup:

    - `talosctl get machineconfig -o yaml | yq .spec > machineconfig.yaml`
    - **IMPORTANT**: Change `machine.install.wipe` back to `false`!
    - Edit as needed
    - `talosctl apply-config --insecure -n <ip> --file machineconfig.yaml `

## Storage

- `./shell.sh` opens an admin shell with privileges
- `apt update && apt install gdisk`
- Use `bf01` partition type for ZFS partitions
- `gdisk /dev/nvme0n1`
    - `p` to print partitions
    - Inspect partitions - there should be space AFTER the `EPHEMERAL` partition
    - `n` to create a new partition, accept defaults to use all remaining space
    - `w` to write changes
    - `p`
- `gdisk /dev/nvme1n1`
    - `d` to delete all partitions
    - `n` to create a new partition.
        - Take END sector of the above `EPHEMERAL` partition as end sector of the
            new partition here to align them.
    - `n` to create another new partition, accept defaults to use all remaining
        space
    - `p`. Compare that start and end sectors of the trailing partitions are
        EXACTLY the same on both disks.
    - `w` to write changes
- Exit shell and `talosctl reboot`
- `./shell.sh`, and use `gdisk` again to verify everything worked
- `./shell.sh start`
- You can use `./shell.sh run bash` to run commands in the shell
- `./shell.sh run zfs zpool create -m legacy tank_single nvme1n1p1`. This is the
    *leading* partition on the *secondary* disk. If will serve as an unmirrored
    pool for non-critical data.
- Note the device of the last partition on the system disk. Ex. `nvme0n1p6`.
- `./shell.sh run zfs zpool create -m legacy -f tank_mirror mirror nvme0n1p6 nvme1n1p2`.
    This is the *trailing* partition on *both* disks. It will serve as a
    mirrored pool for critical data.
- `./shell.sh run zfs zpool status` to verify both pools are healthy.

## Initial services

### CoreDNS

- `cd bootstrap/coredns`
- `helm repo add coredns https://coredns.github.io/helm`
- `helm repo update`
- `helm upgrade --install coredns --namespace kube-system coredns/coredns --values values.yml`
- `kubectl run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools`
    and use `dig` to verify DNS resolution works and uses the configured DNS IP

### ArgoCD

- `cd bootstrap/argocd`
- `helm repo add argo https://argoproj.github.io/argo-helm`
- `helm repo update`
- `./install.sh`
- Commit and push GitOps manifests before applying Applications that reference
  this repository. ArgoCD reads from the remote Git branch, not the local
  checkout.
- Apply the CoreDNS adoption Application after the commit is visible on the
  remote branch:
    `kubectl apply -f gitops/argocd/applications/coredns.yaml`

### OpenEBS

- `cd bootstrap/helm/openebs`
- `helm repo add openebs https://openebs.github.io/openebs`
- `helm repo update`
- `helm upgrade --install openebs --namespace openebs openebs/openebs --create-namespace --values values.yml`
- `kubectl -n openebs get pods` to verify everything is running
- `kubectl apply -f classes.yml` to create storage classes
- `kubectl apply -f test.yml` to create test pods
    - `cat /mnt/std/testfile.txt` should show only `openebs-test-pod-1`
    - `cat /mnt/bulk/testfile.txt` should show both pods
    - Same for `spof` and `spof-bulk`
    - `./shell.sh run zfs list` to see the created datasets
- `kubectl delete -f test.yml` to clean up test pods
- `kubectl -A get pv` to see created persistent volumes
- `kubectl delete <pv-name>` to delete persistent volume
- `./shell.sh run zfs list` to see datasets removed except for the persistent
    volume
- `./shell.sh run zfs destroy <dataset>` to remove dataset manually

### cert-manager

- `aws route53 create-hosted-zone --name 'k8s.example.com' --caller-reference "externaldns-$(date +%s)"`
    to create a hosted zone
- Create `credentials` file using a temporary IAM key that has permissions to
    manage the hosted zone:
    ```
    [default]
    aws_access_key_id = <access-key-id>
    aws_secret_access_key = <secret-access-key>
    ```
- `cd bootstrap/helm/cert-manager`
- `helm repo add cert-manager https://charts.jetstack.io`
- `helm repo update`
- `kubectl create namespace cert-manager`
- `kubectl create secret generic -n cert-manager cert-manager --from-file credentials`
- `helm upgrade --install -n cert-manager cert-manager cert-manager/cert-manager --values values.yml`
- `kubectl apply -f resources.yml`

Validation is only possible after all components are done.

### external-dns

- `kubectl create namespace external-dns`
- `kubectl create secret generic -n external-dns external-dns --from-file credentials`
- `cd bootstrap/helm/externaldns`
- `helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/`
- `helm repo update`
- `helm upgrade --install external-dns --namespace external-dns external-dns/external-dns --values values.yml`

Validation is only possible after all components are done.

### Traefik

- `cd bootstrap/helm/traefik`
- `helm repo add traefik https://traefik.github.io/charts`
- `helm repo update`
- `helm -n traefik upgrade --install --create-namespace traefik traefik/traefik -f values.yml`
- `kubectl -n traefik apply -f classes.yml`

### Kubernetes OIDC issuer

AWS IAM, KMS and SSM permissions for this integration are managed in the
`aws-main` repository.

- From the repository root: `./patch.sh oidc`
- Refresh the public JWKS document:
    `kubectl get --raw /openid/v1/jwks > bootstrap/oidc/jwks.json`
- Publish the issuer discovery endpoints: `kubectl apply -k bootstrap/oidc`
- Verify the published endpoints:
    `curl -fsS https://oidc.k8s.d-reis.com/.well-known/openid-configuration`
- Verify the published JWKS:
    `curl -fsS https://oidc.k8s.d-reis.com/openid/v1/jwks`

### external-secrets

- `cd bootstrap/helm/external-secrets`
- `helm repo add external-secrets https://charts.external-secrets.io`
- `helm repo update`
- `./install.sh`

For GitOps, manage these as separate units:

- Helm chart: `bootstrap/helm/external-secrets/values.yml`
- Post-CRD resources: `bootstrap/helm/external-secrets/resources/`

Smoke test manifests are kept in this directory as one-off checks:

- `test.yml` reads `/external-secrets/smoke`
- `test-securestring.yml` reads `/external-secrets/smoke-secure`

### CloudNativePG

- `cd bootstrap/helm/cpng`
- `helm repo add cnpg https://cloudnative-pg.github.io/charts`
- `helm repo update`
- `./install.sh`

### PostgreSQL cluster

- `cd bootstrap/helm/postgres`
- `./install.sh`
- `kubectl apply -f test.yaml` to run `psql ping`
- `kubectl -n cnpg-database get pods` / `logs` to verify the test succeeded

### Vikunja

- `cd bootstrap/helm/vikunja`
- `./install.sh`
- `kubectl exec -n vikunja vikunja-<id> -- /app/vikunja/vikunja index`
- Import data

### Vaultwarden

- `cd bootstrap/helm/vaultwarden`
- `helm repo add vaultwarden https://guerzon.github.io/vaultwarden`
- `helm repo update`
- `kubectl create namespace vaultwarden`
- `openssl rand -base64 32 | tee /dev/stderr | tr -d '\n' | argon2 $(openssl rand -base64 32)`
    (first line is the password)
- `kubectl create secret generic -n vaultwarden vaultwarden-smtp --from-literal username='vaultwarden@d-reis.com' --from-literal token='<token>'`
- Go to bitwarden.com/host, request an installation ID and key (no account
    required)
- `kubectl create secret generic -n vaultwarden vaultwarden-installation --from-literal installation_id="<uuid>" --from-literal installation_key="<key>"`
- `helm -n vaultwarden upgrade --install vaultwarden vaultwarden/vaultwarden -f values.yml`

### Odoo

- `cd bootstrap/helm/odoo`
- `helm repo add imio https://imio.github.io/helm-charts`
- `helm repo update`
- Set `odoo.list_db` in `values.yml` to `True`
- `helm -n odoo upgrade --install --create-namespace odoo imio/odoo -f values.yml`

#### Temporary: Without external-secrets

- Must use Chrome!
- `kubectl -n odoo edit secret odoo-odoo-conf -o yaml | yq '.data["odoo.conf"]' | base64 -d > odoo.conf`
- Edit `odoo.conf` to set `admin_passwd` and re-encode:
    `cat odoo.conf | base64 -w0`
- `kubectl -n odoo edit secret odoo-odoo-conf` to update `odoo.conf` data
- `kubectl -n odoo rollout restart deployment odoo`
- `<odoo>/web/database/manager`, do NOT delete existing DB!
- Restore, "database was moved"
