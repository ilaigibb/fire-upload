import { resolve } from 'node:path';

export type Config = {
  cleanupIntervalMs: number;
  dataDir: string;
  githubToken: string | null;
  maxBytes: number;
  pollIntervalMs: number;
  port: number;
  publicUrl: string;
  token: string;
};

function positiveInteger(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;

  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }

  return value;
}

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

export function loadConfig(): Config {
  const publicUrl = required('FIRE_UPLOAD_PUBLIC_URL').replace(/\/+$/, '');
  const parsedUrl = new URL(publicUrl);
  if (!['http:', 'https:'].includes(parsedUrl.protocol)) {
    throw new Error('FIRE_UPLOAD_PUBLIC_URL must use http or https');
  }
  if (
    !parsedUrl.hostname ||
    parsedUrl.username ||
    parsedUrl.password ||
    parsedUrl.pathname !== '/' ||
    parsedUrl.search ||
    parsedUrl.hash
  ) {
    throw new Error('FIRE_UPLOAD_PUBLIC_URL must be an origin without credentials, a path, query, or hash');
  }

  const token = required('FIRE_UPLOAD_TOKEN');
  if (token.length < 32) throw new Error('FIRE_UPLOAD_TOKEN must contain at least 32 characters');

  return {
    cleanupIntervalMs: positiveInteger('FIRE_UPLOAD_CLEANUP_MINUTES', 10) * 60_000,
    dataDir: resolve(process.env.FIRE_UPLOAD_DATA_DIR ?? './data'),
    githubToken: process.env.FIRE_UPLOAD_GITHUB_TOKEN?.trim() || null,
    maxBytes: positiveInteger('FIRE_UPLOAD_MAX_BYTES', 500 * 1024 * 1024),
    pollIntervalMs: positiveInteger('FIRE_UPLOAD_PR_POLL_MINUTES', 60) * 60_000,
    port: positiveInteger('FIRE_UPLOAD_PORT', 8080),
    publicUrl,
    token,
  };
}
