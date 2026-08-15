# Fire Upload

Fire Upload is a small personal file host for agent-generated pull-request artifacts. Uploads are authenticated; returned file URLs are public and stable until their configured deletion policy removes them.

## Upload

```bash
curl -sS --fail-with-body -X PUT -T screenshot.png \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  "https://your-name.duckdns.org/screenshot.png"
```

The response body is the public URL. Add `Accept: application/json` when the asset ID is needed for lifecycle operations.

Set a fixed lifetime with `X-Delete-After: 30d`. Associate an uploaded asset with a pull request after creating the PR:

```bash
curl -sS --fail-with-body -X POST \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prUrl":"https://github.com/owner/repo/pull/123","deleteAfterMerge":"7d"}' \
  "https://your-name.duckdns.org/api/assets/ASSET_ID/github"
```

## GitHub Markdown

```markdown
![Screenshot](PUBLIC_URL)
[🎥 Screen recording](PUBLIC_URL)
```

GitHub displays external images inline but links externally hosted videos. The bundled skill documents the optional FFmpeg GIF-preview workflow.

## Local configuration

Copy `.env.example` into the service environment. `FIRE_UPLOAD_TOKEN` and `FIRE_UPLOAD_PUBLIC_URL` are required. Run `pnpm install`, `pnpm build`, then `pnpm start`.

## Proxmox

Fire Upload installs like a Proxmox community helper script: paste one command into the **Proxmox host shell**, choose Default or Advanced, and the installer creates and configures the LXC. Do not create an LXC first.

Create a tagged GitHub release before installing. For a public repository:

```bash
bash -c "$(curl -fsSL https://github.com/OWNER/fire-upload/releases/latest/download/fire-upload-proxmox.sh)"
```

For a private repository, authenticate the initial download without putting the token in shell history:

```bash
export FIRE_UPLOAD_REPO=OWNER/fire-upload
read -rsp "GitHub token: " FIRE_UPLOAD_GITHUB_TOKEN; echo
export FIRE_UPLOAD_GITHUB_TOKEN
bash -c "$(curl -fsSL \
  -H 'Accept: application/vnd.github.raw+json' \
  -H "Authorization: Bearer $FIRE_UPLOAD_GITHUB_TOKEN" \
  "https://api.github.com/repos/$FIRE_UPLOAD_REPO/contents/deploy/proxmox.sh")"
unset FIRE_UPLOAD_GITHUB_TOKEN
```

The installer asks for the DuckDNS subdomain and token, creates a 1-core/512-MiB unprivileged Debian LXC by default, installs the latest release, configures HTTPS, and prints the upload token. It also enables daily update checks; run `fire-upload-update` inside the LXC to update immediately.

After installation, reserve the displayed LXC address in the router and forward TCP ports 80 and 443 to it. The installer cannot change the router or determine CGNAT; compare the router WAN address with a public-IP lookup before relying on DuckDNS.

Uploaded files, SQLite metadata, and configuration remain outside application releases under `/var/lib/fire-upload` and `/etc/fire-upload.env`.
