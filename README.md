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

- `cd bootstrap/talos`

- Edit `image.yaml` to add extensions if needed

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

- From the repository root, `tools/shell.sh` opens an admin shell with
    privileges
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
- `tools/shell.sh`, and use `gdisk` again to verify everything worked
- `tools/shell.sh start`
- You can use `tools/shell.sh run bash` to run commands in the shell
- `tools/shell.sh run zfs zpool create -m legacy tank_single nvme1n1p1`. This is
    the *leading* partition on the *secondary* disk. If will serve as an
    unmirrored pool for non-critical data.
- Note the device of the last partition on the system disk. Ex. `nvme0n1p6`.
- `tools/shell.sh run zfs zpool create -m legacy -f tank_mirror mirror nvme0n1p6 nvme1n1p2`.
    This is the *trailing* partition on *both* disks. It will serve as a
    mirrored pool for critical data.
- `tools/shell.sh run zfs zpool status` to verify both pools are healthy.

## Initial services

### CoreDNS

- `cd bootstrap/coredns`
- `helm repo add coredns https://coredns.github.io/helm`
- `helm repo update`
- `helm upgrade --install coredns --namespace kube-system coredns/coredns --values values.yaml`
- `kubectl run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools`
    and use `dig` to verify DNS resolution works and uses the configured DNS IP

### ArgoCD

- `cd bootstrap/argocd`
- `helm repo add argo https://argoproj.github.io/argo-helm`
- `helm repo update`
- `./install.sh`
- Open the web interface and log in per instructions output from the install
    process.
- `helm list -n kube-system` and find the `coredns` chart version.
- Update `argocd/applications/coredns.yaml` to use the same version.
- Ensure repo is committed and pushed.
- `kubectl apply -f root.yaml` to create the root application

### Adopting CoreDNS

- In the web interface, observe the root application. All child applications
    should be healthy and OutOfSync.
- Find the CoreDNS child application and click "Sync" to bring it up to date.
- In the main ArgoCD application list, you should now have a new CoreDNS
    application that is healthy and OutOfSync.
- Validate the diff. You should only see ArgoCD annotations being added.
- Sync the CoreDNS application to bring it up to date. It should now be healthy
    and InSync.

## Deploying additional services

### Prerequisites

- In `argocd/catalog`, check the versions for the individual charts. Update any
    versions that are out of date and modify the corresponding `values.yaml`
    files as needed.
- Deploy the base `aws` Terraform repository, then deploy this repository's
    Terraform with OIDC roles disabled:
    `tofu -chdir=terraform apply -var enable_oidc_roles=false`
- Terraform creates scoped Route53 credentials for the DNS controllers.
    Published DNS names are controlled by the Kubernetes manifests.
- external-dns uses a DynamoDB registry managed by Terraform, not Route53 TXT
    ownership records.
- Sync the `platform` ApplicationSet.

#### external-dns

- Checked-in values use the `external_dns_role_arn` role. Before OIDC is live,
    temporarily use the commented bootstrapping credentials in
    `services/platform/external-dns/values.yaml`.
- Use the `external_dns_access_key` Terraform output for the bootstrap
    `credentials` file:
    ```
    [default]
    aws_access_key_id = <access-key-id>
    aws_secret_access_key = <secret-access-key>
    ```
- `kubectl create namespace external-dns`
- `kubectl create secret generic -n external-dns external-dns --from-file credentials`

#### cert-manager

- Checked-in values use the `cert_manager_role_arn` role. Before OIDC is live,
    temporarily use the commented bootstrapping credentials in
    `services/platform/cert-manager/values.yaml`.
- Use the `cert_manager_access_key` Terraform output for the bootstrap
    `credentials` file:
    ```
    [default]
    aws_access_key_id = <access-key-id>
    aws_secret_access_key = <secret-access-key>
    ```
- `kubectl create namespace cert-manager`
- `kubectl create secret generic -n cert-manager cert-manager --from-file credentials`

#### OIDC issuer

- In `bootstrap/talos`, run `./patch.sh oidc` to generate the OIDC issuer config
    patch.
- Refresh the public JWKS document:
    `kubectl get --raw /openid/v1/jwks > services/platform/oidc/jwks.json`
- Verify the issuer endpoints under `https://oidc.k8s.d-reis.com`, then run
    `tofu -chdir=terraform apply`.
- Revert the temporary bootstrapping credential values and sync external-dns and
    cert-manager. After they work with roles, set `enable_iam_users = false`,
    run `tofu -chdir=terraform apply`, and delete the `external-dns` and
    `cert-manager` AWS credential Secrets.

#### Vaultwarden

- `kubectl create namespace vaultwarden`
- `openssl rand -base64 32 | tee /dev/stderr | tr -d '\n' | argon2 $(openssl rand -base64 32)`
    (first line is the password)
- `kubectl create secret generic -n vaultwarden vaultwarden-smtp --from-literal username='vaultwarden@d-reis.com' --from-literal token='<token>'`
- Go to bitwarden.com/host, request an installation ID and key (no account
    required)
- `kubectl create secret generic -n vaultwarden vaultwarden-installation --from-literal installation_id="<uuid>" --from-literal installation_key="<key>"`

### Initial deployment

Sync the Applications in the `platform` ApplicationSet one by one, in the
following order:

- OpenEBS
- external-dns
- cert-manager
- Traefik
- OIDC issuer
- CNPG Operator
- external-secrets

Sync the Applications in the `base` ApplicationSet one by one, in the
following order:

- CNPG database cluster

Go back to the `platform` ApplicationSet and sync the `argocd` Application.

This will bring up ArgoCD with its ingress, so you can terminate your local
port-forward and use the web interface.

It will auto enable auto-syncing and self-healing, so you can just let it run
while it brings up the rest of the applications.

## Testing

### OpenEBS

- `kubectl apply -f services/platform/openebs/test/test.yaml` to create test
    pods
    - `cat /mnt/std/testfile.txt` should show only `openebs-test-pod-1`
    - `cat /mnt/bulk/testfile.txt` should show both pods
    - Same for `spof` and `spof-bulk`
    - `tools/shell.sh run zfs list` to see the created datasets
- `kubectl delete -f services/platform/openebs/test/test.yaml` to clean up test
    pods
- `kubectl -A get pv` to see created persistent volumes
- `kubectl delete <pv-name>` to delete persistent volume
- `tools/shell.sh run zfs list` to see datasets removed except for the
    persistent volume
- `tools/shell.sh run zfs destroy <dataset>` to remove dataset manually

### Kubernetes OIDC issuer

- Verify the published endpoints:
    `curl -fsS https://oidc.k8s.d-reis.com/.well-known/openid-configuration`
- Verify the published JWKS:
    `curl -fsS https://oidc.k8s.d-reis.com/openid/v1/jwks`

### external-secrets

- `services/platform/external-secrets/test/test.yaml` reads
    `/external-secrets/smoke`
- `services/platform/external-secrets/test/test-securestring.yaml` reads
    `/external-secrets/smoke-secure`

### PostgreSQL cluster

- `services/base/cnpg-cluster/test.yaml` executes a ping to the database
    cluster.

<!---

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

-->
