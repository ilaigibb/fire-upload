# Fire Upload

Fire Upload is a tiny personal file host for agent-generated pull-request artifacts. Uploads require a secret token. Returned file URLs are public and stable until their deletion policy removes them.

## Install on Proxmox

The installer runs from the **Proxmox node's root shell** and creates a new unprivileged Debian 13 LXC. Do not create an LXC first, and do not run the installer from inside an existing LXC.

### Requirements

- An amd64 Proxmox VE 8.4-8.9 or 9.0-9.2 host
- A root shell opened from **Proxmox → your node → Shell**, or a root SSH login
- Active Proxmox storage supporting `rootdir` and `vztmpl`
- A free [DuckDNS](https://www.duckdns.org/) subdomain and token
- Router access for forwarding TCP ports 80 and 443
- A public IPv4 address or usable public IPv6; normal port forwarding cannot cross CGNAT
- While this repository is private, a fine-grained GitHub token scoped only to `ilaigibb/fire-upload` with **Contents: Read-only**

If an SSH login starts as a normal user, run `sudo -i` first. The prompt should look like `root@proxmox:~#`. The installer intentionally rejects `sudo bash ...` because a real root login has a more predictable environment.

### Download, inspect, and run

The repository is private, so GitHub must authenticate the initial download. The token is read silently and is not written into shell history:

```bash
read -rsp "GitHub token: " FIRE_UPLOAD_GITHUB_TOKEN; echo
curl -fsSL --retry 3 \
  -H 'Accept: application/vnd.github.raw+json' \
  -H "Authorization: Bearer ${FIRE_UPLOAD_GITHUB_TOKEN}" \
  'https://api.github.com/repos/ilaigibb/fire-upload/contents/deploy/proxmox.sh?ref=v0.2.0' \
  -o /root/install-fire-upload.sh
chmod 700 /root/install-fire-upload.sh
```

Review the downloaded script before giving it root access:

```bash
less /root/install-fire-upload.sh
```

Then run it:

```bash
FIRE_UPLOAD_GITHUB_TOKEN="$FIRE_UPLOAD_GITHUB_TOKEN" bash /root/install-fire-upload.sh
unset FIRE_UPLOAD_GITHUB_TOKEN
```

The same GitHub token is passed to the installer without typing it again. The LXC stores it in a root-only configuration file so it can download private updates. The installer also asks for the DuckDNS subdomain and token. Secret prompts do not echo their contents.

An exact Jellyfin-style unauthenticated one-liner is impossible while the installer is private: the shell must authenticate before it can download the first script. If the repository or a tiny bootstrap script becomes public later, the command becomes:

```bash
bash <(curl -fsSL https://github.com/ilaigibb/fire-upload/releases/latest/download/install-fire-upload.sh)
```

### Default and Advanced installation

Default creates an unprivileged LXC with 1 CPU, 512 MiB RAM, 256 MiB swap, an 8 GiB disk, `vmbr0`, and DHCP. If the node has multiple compatible storage locations, the installer still asks which one to use.

Advanced lets you choose:

- Container ID and hostname
- CPU, RAM, swap, and disk size
- The Proxmox storage holding Fire Upload data
- The separate storage holding the small Debian template
- Network bridge
- DHCP or a static IPv4 address, gateway, and DNS server

Uploaded files and SQLite metadata live under `/var/lib/fire-upload` on the LXC root disk. Choose the desired storage and disk size during Advanced installation. With DHCP, reserve the address printed by the installer in the router afterward.

### What the installer changes

Before creating anything, it validates the root shell, Proxmox version, architecture, cluster quorum, cluster filesystem, storage capabilities and free space, network bridge, static-IP values, and cluster-wide container ID. It downloads the application release and Debian template, checks the archive paths, verifies DuckDNS, and displays the complete plan. Nothing is created until you answer `y` to that plan.

On the Proxmox host it only:

- Downloads the Debian 13 template when it is not already present
- Creates the new LXC ID shown in the confirmation
- Writes a root-only installation log under `/var/log`

It does not install packages onto the Proxmox host, modify existing VMs or LXCs, reconfigure storage, change the router, or automatically delete a failed container. A lock prevents two Fire Upload installations from running simultaneously.

Inside the new LXC it installs Node.js, Caddy, and Fire Upload; creates a restricted `fire-upload` system user; configures HTTPS and DuckDNS; and enables daily update checks. The guest installer refuses to run directly on a Proxmox host.

If installation fails after the LXC is created, it is kept for inspection and the host log path is printed. Inspect it with:

```bash
pct enter CONTAINER_ID
```

Only remove it after deciding it is disposable:

```bash
pct stop CONTAINER_ID
pct destroy CONTAINER_ID
```

Then rerun the installer. It will never reuse an occupied ID without telling you.

### Finish the public connection

Reserve the displayed LXC address in the router if DHCP was selected. Forward router TCP ports **80 and 443** to that address. Do not expose Proxmox port 8006, SSH, or Fire Upload's internal port 8080.

Verify from a device outside the home network:

```bash
curl https://YOUR-NAME.duckdns.org/health
```

## Upload a file

Configure agents with the URL and upload token printed by the installer:

```bash
export FILE_HOST_URL=https://YOUR-NAME.duckdns.org
export FILE_HOST_TOKEN=YOUR_UPLOAD_TOKEN
```

Upload any file:

```bash
curl -sS --fail-with-body -X PUT -T screenshot.png \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  "$FILE_HOST_URL/screenshot.png"
```

The response body is the permanent public URL. Add `Accept: application/json` when the asset ID is needed for lifecycle operations. Set a fixed lifetime with `X-Delete-After: 30d`.

Associate an uploaded asset with a pull request after creating the PR:

```bash
curl -sS --fail-with-body -X POST \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prUrl":"https://github.com/owner/repo/pull/123","deleteAfterMerge":"7d"}' \
  "$FILE_HOST_URL/api/assets/ASSET_ID/github"
```

GitHub Markdown:

```markdown
![Screenshot](PUBLIC_URL)
[🎥 Screen recording](PUBLIC_URL)
```

GitHub displays external images inline and links externally hosted videos. The bundled agent skill documents the optional FFmpeg GIF-preview workflow.

## Updates and data

The LXC checks for releases daily. Run `fire-upload-update` inside it for an immediate update. Application releases live under `/opt/fire-upload`; uploads, SQLite metadata, and configuration remain outside releases under `/var/lib/fire-upload` and `/etc/fire-upload.env`.
