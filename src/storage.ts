import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, rename, rm, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { dirname, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';

export class UploadTooLargeError extends Error {}

export type StoredUpload = {
  relativePath: string;
  size: number;
};

export async function storeUpload(
  request: IncomingMessage,
  filesDir: string,
  id: string,
  filename: string,
  maxBytes: number,
): Promise<StoredUpload> {
  const relativePath = join(id, filename);
  const destination = join(filesDir, relativePath);
  const temporary = `${destination}.uploading`;
  await mkdir(dirname(destination), { recursive: true });

  let size = 0;
  const limiter = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      size += chunk.length;
      callback(size > maxBytes ? new UploadTooLargeError('upload exceeds configured limit') : null, chunk);
    },
  });

  try {
    await pipeline(request, limiter, createWriteStream(temporary, { flags: 'wx', mode: 0o640 }));
    await rename(temporary, destination);
    return { relativePath, size };
  } catch (error) {
    await rm(temporary, { force: true });
    await rm(dirname(destination), { force: true, recursive: true });
    throw error;
  }
}

export async function removeStoredFile(filesDir: string, relativePath: string): Promise<void> {
  const path = join(filesDir, relativePath);
  await rm(path, { force: true });
  await rm(dirname(path), { force: true, recursive: true });
}

function parseRange(header: string, size: number): { end: number; start: number } | null {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return null;

  const startText = match[1] ?? '';
  const endText = match[2] ?? '';
  if (!startText && !endText) return null;

  let start: number;
  let end: number;
  if (!startText) {
    const suffixLength = Number(endText);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) return null;
    start = Math.max(0, size - suffixLength);
    end = size - 1;
  } else {
    start = Number(startText);
    end = endText ? Number(endText) : size - 1;
  }

  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= size || end < start) {
    return null;
  }

  return { start, end: Math.min(end, size - 1) };
}

export async function serveStoredFile(
  request: IncomingMessage,
  response: ServerResponse,
  absolutePath: string,
  mimeType: string,
  originalName: string,
): Promise<void> {
  const file = await stat(absolutePath);
  const commonHeaders = {
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'public, max-age=31536000, immutable',
    'Content-Disposition': `inline; filename*=UTF-8''${encodeURIComponent(originalName)}`,
    'Content-Type': mimeType,
    'X-Content-Type-Options': 'nosniff',
    ...(mimeType === 'text/html' ? { 'Content-Security-Policy': 'sandbox' } : {}),
  };

  const requestedRange = request.headers.range;
  if (requestedRange) {
    const range = parseRange(requestedRange, file.size);
    if (!range) {
      response.writeHead(416, { ...commonHeaders, 'Content-Range': `bytes */${file.size}` });
      response.end();
      return;
    }

    response.writeHead(206, {
      ...commonHeaders,
      'Content-Length': range.end - range.start + 1,
      'Content-Range': `bytes ${range.start}-${range.end}/${file.size}`,
    });
    if (request.method === 'HEAD') {
      response.end();
      return;
    }
    await pipeline(createReadStream(absolutePath, range), response);
    return;
  }

  response.writeHead(200, { ...commonHeaders, 'Content-Length': file.size });
  if (request.method === 'HEAD') {
    response.end();
    return;
  }
  await pipeline(createReadStream(absolutePath), response);
}
