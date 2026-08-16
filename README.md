# Install File Upload on Proxmox

## 1. Create a DuckDNS name

Create a free subdomain at [DuckDNS](https://www.duckdns.org/) and copy its token.

## 2. Open the correct shell

In Proxmox, click **your node → Shell**. Do not open an LXC console. The prompt should start with `root@`.

## 3. Copy and paste this entire block

```bash
(
  set -euo pipefail
  installer="$(mktemp /root/install-file-upload.XXXXXX.sh)"
  trap 'rm -f -- "$installer"' EXIT

  curl -fsSL --retry 3 \
    'https://raw.githubusercontent.com/ilaigibb/file-upload/e68111c0009ccd2e61e42f2cb7640e5ed7c68f73/deploy/proxmox.sh' \
    -o "$installer"

  echo '9f60d9e48e343e25d80320e92c104e928e2d2259a4fea4176b5406f3a85a625b  '"$installer" | sha256sum --check --status
  chmod 700 "$installer"
  bash "$installer"
)
```

The installer is pinned to an immutable commit and verified before it runs as root.

## 4. Answer the installer

1. Choose **Default** for a simple home setup. Choose **Advanced** to place the public LXC on an isolated bridge or VLAN.
2. For **container data**, choose where uploaded files should live. For **Debian template**, choose `local` unless you know you need something else.
3. Enter the DuckDNS name without `.duckdns.org`.
4. Paste the DuckDNS token.
5. Read the final summary and enter `y`.
6. Save the printed **upload token**, **public URL**, and **local address**.

The installer creates the LXC for you. Do not create one manually.

## 5. Configure the router

1. Reserve the printed local address so it does not change.
2. Forward TCP port **80** to that address.
3. Forward TCP port **443** to that address.

Do not forward Proxmox port 8006 or File Upload port 8080.

For stronger isolation, place the LXC on a VLAN or bridge that cannot initiate connections to Proxmox or trusted home devices.

## 6. Verify it

Turn off Wi-Fi on your phone and open:

```text
https://YOUR-DUCKDNS-NAME.duckdns.org/health
```

It should display `{"ok":true}`.

If installation fails, stop. Do not delete anything. Copy the error and the printed log path so it can be inspected safely.
