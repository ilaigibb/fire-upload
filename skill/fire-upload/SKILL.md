---
name: fire-upload
description: Upload any local file—such as a screenshot, screen recording, log, document, Markdown file, config, build artifact, or archive—to the user's Fire Upload host and return a permanent public URL. Use when the user asks to upload a file or when a public file URL is needed for a pull request description.
---

# Fire Upload

Upload files to `FILE_HOST_URL` and return the permanent public URL from the response body. Authenticate with `FILE_HOST_TOKEN`. If either is unset, tell the user instead of guessing.

## Upload

```bash
curl -sS --fail-with-body -X PUT -T <path-to-file> \
  -H "X-Upload-Token: $FILE_HOST_TOKEN" \
  "$FILE_HOST_URL/<filename>"
```

- Use only the file's basename for `<filename>`, such as `login-flow.mp4`. The server slugifies it and adds a random suffix, so names do not need to be unique.
- Treat the response body as the permanent public URL and use it directly.
- On HTTP 401, report that the token is wrong or unset. Do not retry.

## Use the URL in GitHub

- Embed images (`png`, `jpg`, `gif`, `webp`) as `![description](URL)`.
- Link videos (`mp4`, `mov`, `webm`) as `[🎥 screen recording](URL)` because GitHub does not inline-play externally hosted video.
- When an inline preview genuinely helps and the clip is shorter than about 30 seconds, also upload a GIF preview:

```bash
ffmpeg -i recording.mp4 -vf "fps=10,scale=800:-1" -loop 0 preview.gif
```

Embed the GIF and link the full-quality video below it.
