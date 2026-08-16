# Install File Upload on Proxmox

## 1. Get these two things

1. Create a free subdomain at [DuckDNS](https://www.duckdns.org/) and copy its token.
2. Create a [fine-grained GitHub token](https://github.com/settings/personal-access-tokens/new):
   - Repository access: **Only select repositories → `file-upload`**
   - Repository permission: **Contents → Read-only**

## 2. Open the correct shell

In Proxmox, click **your node → Shell**. Do not open an LXC console. The prompt should start with `root@`.

## 3. Copy and paste this entire block

```bash
(
  set -e
  installer="$(mktemp /root/install-file-upload.XXXXXX.sh)"
  trap 'rm -f -- "$installer"' EXIT

  read -rsp "Paste GitHub token: " FILE_UPLOAD_GITHUB_TOKEN
  echo

  curl -fsSL --retry 3 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H "Authorization: Bearer ${FILE_UPLOAD_GITHUB_TOKEN}" \
    'https://api.github.com/repos/ilaigibb/file-upload/contents/deploy/proxmox.sh?ref=v0.3.0' \
    -o "$installer"

  chmod 700 "$installer"
  FILE_UPLOAD_GITHUB_TOKEN="$FILE_UPLOAD_GITHUB_TOKEN" bash "$installer"
)
```

Paste the token and press Enter. Nothing will appear while you type or paste it.

## 4. Answer the installer

1. Choose **Default** unless you specifically want to choose the disk, storage, or IP address.
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

## 6. Verify it

Turn off Wi-Fi on your phone and open:

```text
https://YOUR-DUCKDNS-NAME.duckdns.org/health
```

It should display `{"ok":true}`.

If installation fails, stop. Do not delete anything. Copy the error and the printed log path so it can be inspected safely.
