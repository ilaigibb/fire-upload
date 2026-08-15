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

`deploy/proxmox.sh` creates a small unprivileged Debian LXC. `deploy/install.sh` installs a tagged GitHub release inside an existing Debian guest. The scripts do not configure router port forwarding and cannot determine CGNAT from inside the guest; compare the router WAN address with a public-IP lookup before relying on DuckDNS.

Uploaded files, SQLite metadata, and configuration remain outside application releases under `/var/lib/fire-upload` and `/etc/fire-upload.env`.
