import { mkdir } from 'node:fs/promises';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { join } from 'node:path';
import { lookup } from 'mime-types';
import { isAuthorized } from './auth.js';
import { deleteExpiredAssets } from './cleanup.js';
import { loadConfig } from './config.js';
import { AssetDatabase, type Asset } from './database.js';
import { parseDuration } from './duration.js';
import { parsePullRequestUrl, pollPullRequests } from './github.js';
import { makeStoredName } from './names.js';
import { removeStoredFile, serveStoredFile, storeUpload, UploadTooLargeError } from './storage.js';

const config = loadConfig();
const filesDir = join(config.dataDir, 'files');
await mkdir(filesDir, { recursive: true });
const database = new AssetDatabase(config.dataDir);

function sendText(response: ServerResponse, status: number, message: string): void {
  response.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': Buffer.byteLength(message),
    'Cache-Control': 'no-store',
  });
  response.end(message);
}

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  response.end(body);
}

function requireAuthorization(request: IncomingMessage, response: ServerResponse): boolean {
  if (isAuthorized(request, config.token)) return true;
  sendText(response, 401, 'upload token is missing or incorrect');
  return false;
}

async function readJson(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > 16 * 1024) throw new Error('request body is too large');
    chunks.push(buffer);
  }

  return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;
}

function isGithubAttachment(value: unknown): value is { deleteAfterMerge: string; prUrl: string } {
  return (
    typeof value === 'object' &&
    value !== null &&
    'prUrl' in value &&
    typeof value.prUrl === 'string' &&
    'deleteAfterMerge' in value &&
    typeof value.deleteAfterMerge === 'string'
  );
}

async function handleUpload(request: IncomingMessage, response: ServerResponse, encodedName: string): Promise<void> {
  if (!requireAuthorization(request, response)) return;

  const contentLength = Number(request.headers['content-length'] ?? 0);
  if (Number.isFinite(contentLength) && contentLength > config.maxBytes) {
    sendText(response, 413, 'file exceeds configured upload limit');
    return;
  }

  const generated = makeStoredName(encodedName);
  const deleteAfter = request.headers['x-delete-after'];
  const deleteAt =
    typeof deleteAfter === 'string'
      ? new Date(Date.now() + parseDuration(deleteAfter)).toISOString()
      : null;

  const stored = await storeUpload(request, filesDir, generated.id, generated.name, config.maxBytes);
  const mimeType = lookup(generated.originalName) || 'application/octet-stream';
  const createdAt = new Date().toISOString();
  const asset: Asset = {
    createdAt,
    deleteAfterMergeMs: null,
    deleteAt,
    filename: generated.name,
    githubOwner: null,
    githubPr: null,
    githubRepo: null,
    id: generated.id,
    lastGithubCheckAt: null,
    mergedAt: null,
    mimeType,
    originalName: generated.originalName,
    relativePath: stored.relativePath,
    size: stored.size,
  };

  try {
    database.insert(asset);
  } catch (error) {
    await removeStoredFile(filesDir, stored.relativePath);
    throw error;
  }

  const url = `${config.publicUrl}/${encodeURIComponent(generated.name)}`;
  if (request.headers.accept?.includes('application/json')) {
    sendJson(response, 201, { id: generated.id, name: generated.name, url });
    return;
  }
  sendText(response, 201, url);
}

async function handleGithubAttachment(
  request: IncomingMessage,
  response: ServerResponse,
  assetId: string,
): Promise<void> {
  if (!requireAuthorization(request, response)) return;

  const body = await readJson(request);
  if (!isGithubAttachment(body)) {
    sendText(response, 400, 'body must contain prUrl and deleteAfterMerge');
    return;
  }

  const pull = parsePullRequestUrl(body.prUrl);
  const delayMs = parseDuration(body.deleteAfterMerge);
  const updated = database.attachGithub(assetId, pull.owner, pull.repo, pull.pullRequest, delayMs);
  if (!updated) {
    sendText(response, 404, 'asset not found');
    return;
  }
  response.writeHead(204, { 'Cache-Control': 'no-store' });
  response.end();
}

async function handleDelete(request: IncomingMessage, response: ServerResponse, assetId: string): Promise<void> {
  if (!requireAuthorization(request, response)) return;

  const asset = database.findById(assetId);
  if (!asset) {
    sendText(response, 404, 'asset not found');
    return;
  }
  await removeStoredFile(filesDir, asset.relativePath);
  database.delete(asset.id);
  response.writeHead(204, { 'Cache-Control': 'no-store' });
  response.end();
}

async function handlePublicFile(request: IncomingMessage, response: ServerResponse, filename: string): Promise<void> {
  const asset = database.findByFilename(filename);
  if (!asset) {
    sendText(response, 404, 'not found');
    return;
  }

  await serveStoredFile(
    request,
    response,
    join(filesDir, asset.relativePath),
    asset.mimeType,
    asset.originalName,
  );
}

async function route(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const requestUrl = new URL(request.url ?? '/', 'http://localhost');
  const parts = requestUrl.pathname.split('/').filter(Boolean);

  if (request.method === 'GET' && requestUrl.pathname === '/health') {
    sendJson(response, 200, { ok: true });
    return;
  }

  if (request.method === 'PUT' && parts.length === 1 && parts[0]) {
    await handleUpload(request, response, parts[0]);
    return;
  }

  if (parts.length === 4 && parts[0] === 'api' && parts[1] === 'assets' && parts[2]) {
    if (request.method === 'POST' && parts[3] === 'github') {
      await handleGithubAttachment(request, response, parts[2]);
      return;
    }
  }

  if (parts.length === 3 && parts[0] === 'api' && parts[1] === 'assets' && parts[2]) {
    if (request.method === 'DELETE') {
      await handleDelete(request, response, parts[2]);
      return;
    }
  }

  if ((request.method === 'GET' || request.method === 'HEAD') && parts.length === 1 && parts[0]) {
    await handlePublicFile(request, response, decodeURIComponent(parts[0]));
    return;
  }

  sendText(response, 404, 'not found');
}

const server = createServer((request, response) => {
  void route(request, response).catch(async (error: unknown) => {
    if (response.headersSent) {
      response.destroy();
      return;
    }

    if (error instanceof UploadTooLargeError) {
      sendText(response, 413, error.message);
      return;
    }
    if (error instanceof URIError || error instanceof SyntaxError) {
      sendText(response, 400, 'invalid request');
      return;
    }
    if (error instanceof Error && error.message.startsWith('duration')) {
      sendText(response, 400, error.message);
      return;
    }

    console.error(error);
    sendText(response, 500, 'internal server error');
  });
});

let maintenanceRunning = false;
async function runMaintenance(): Promise<void> {
  if (maintenanceRunning) return;
  maintenanceRunning = true;
  try {
    await pollPullRequests(database, config.githubToken, config.pollIntervalMs);
    await deleteExpiredAssets(database, filesDir);
  } finally {
    maintenanceRunning = false;
  }
}

const cleanupTimer = setInterval(() => void runMaintenance(), config.cleanupIntervalMs);
cleanupTimer.unref();
void runMaintenance();

server.listen(config.port, '127.0.0.1', () => {
  console.log(`File Upload listening on 127.0.0.1:${config.port}`);
});

function shutdown(): void {
  clearInterval(cleanupTimer);
  server.close(() => {
    database.close();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
