---
name: fire-upload
description: Upload local screenshots, screen recordings, GIF previews, logs, documents, Markdown, configuration, build artifacts, archives, or other files to the user's Fire Upload host and use the returned public URL in pull requests, issues, Markdown, or messages.
---

# Fire Upload

Require `FILE_HOST_URL` and `FILE_HOST_TOKEN`. If either is unset, report the missing configuration instead of guessing.

## Upload

Use only the file's basename in the request URL:

```bash
curl -sS --fail-with-body -X PUT -T "<path>" \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  "$FILE_HOST_URL/<basename>"
```

Treat the response body as the permanent public URL. On HTTP 401, report that the token is wrong or unset and do not retry. Never construct or predict a URL.

To delete after a fixed duration, add `X-Delete-After` with an `h`, `d`, or `w` value such as `30d`.

## Use in GitHub

- Embed `png`, `jpg`, `jpeg`, `gif`, and `webp` images as `![description](URL)`.
- Link `mp4`, `mov`, and `webm` videos as `[🎥 screen recording](URL)` because GitHub does not inline-play externally hosted video.
- Link other artifacts as `[description](URL)`.

For a useful clip shorter than about 30 seconds, create and upload a GIF preview:

```bash
ffmpeg -i recording.mp4 -vf "fps=10,scale=800:-1" -loop 0 preview.gif
```

Embed the GIF and link the full-quality video below it.

## Delete after a PR merges

When merge-aware cleanup is wanted, request JSON during upload and retain both `id` and `url`:

```bash
curl -sS --fail-with-body -X PUT -T "<path>" \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  -H "Accept: application/json" \
  "$FILE_HOST_URL/<basename>"
```

After the pull request exists, associate the asset:

```bash
curl -sS --fail-with-body -X POST \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prUrl":"<github-pr-url>","deleteAfterMerge":"7d"}' \
  "$FILE_HOST_URL/api/assets/<asset-id>/github"
```

Use the exact `url` from the upload response in the pull request.
