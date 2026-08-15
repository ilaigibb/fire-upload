import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

export type Asset = {
  createdAt: string;
  deleteAfterMergeMs: number | null;
  deleteAt: string | null;
  filename: string;
  githubOwner: string | null;
  githubPr: number | null;
  githubRepo: string | null;
  id: string;
  lastGithubCheckAt: string | null;
  mergedAt: string | null;
  mimeType: string;
  originalName: string;
  relativePath: string;
  size: number;
};

type AssetRow = {
  created_at: string;
  delete_after_merge_ms: number | null;
  delete_at: string | null;
  filename: string;
  github_owner: string | null;
  github_pr: number | null;
  github_repo: string | null;
  id: string;
  last_github_check_at: string | null;
  merged_at: string | null;
  mime_type: string;
  original_name: string;
  relative_path: string;
  size: number;
};

function toAsset(row: AssetRow): Asset {
  return {
    createdAt: row.created_at,
    deleteAfterMergeMs: row.delete_after_merge_ms,
    deleteAt: row.delete_at,
    filename: row.filename,
    githubOwner: row.github_owner,
    githubPr: row.github_pr,
    githubRepo: row.github_repo,
    id: row.id,
    lastGithubCheckAt: row.last_github_check_at,
    mergedAt: row.merged_at,
    mimeType: row.mime_type,
    originalName: row.original_name,
    relativePath: row.relative_path,
    size: row.size,
  };
}

export class AssetDatabase {
  readonly #database: DatabaseSync;

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true });
    this.#database = new DatabaseSync(join(dataDir, 'metadata.sqlite'));
    this.#database.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
    this.#database.exec(`
      CREATE TABLE IF NOT EXISTS assets (
        id TEXT PRIMARY KEY,
        filename TEXT NOT NULL UNIQUE,
        original_name TEXT NOT NULL,
        relative_path TEXT NOT NULL UNIQUE,
        mime_type TEXT NOT NULL,
        size INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        delete_at TEXT,
        github_owner TEXT,
        github_repo TEXT,
        github_pr INTEGER,
        delete_after_merge_ms INTEGER,
        merged_at TEXT,
        last_github_check_at TEXT
      );
      CREATE INDEX IF NOT EXISTS assets_delete_at_idx ON assets(delete_at);
      CREATE INDEX IF NOT EXISTS assets_github_idx ON assets(github_owner, github_repo, github_pr);
    `);
  }

  insert(asset: Asset): void {
    this.#database
      .prepare(`
        INSERT INTO assets (
          id, filename, original_name, relative_path, mime_type, size, created_at, delete_at,
          github_owner, github_repo, github_pr, delete_after_merge_ms, merged_at, last_github_check_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `)
      .run(
        asset.id,
        asset.filename,
        asset.originalName,
        asset.relativePath,
        asset.mimeType,
        asset.size,
        asset.createdAt,
        asset.deleteAt,
        asset.githubOwner,
        asset.githubRepo,
        asset.githubPr,
        asset.deleteAfterMergeMs,
        asset.mergedAt,
        asset.lastGithubCheckAt,
      );
  }

  findByFilename(filename: string): Asset | null {
    const row = this.#database.prepare('SELECT * FROM assets WHERE filename = ?').get(filename);
    return row ? toAsset(row as AssetRow) : null;
  }

  findById(id: string): Asset | null {
    const row = this.#database.prepare('SELECT * FROM assets WHERE id = ?').get(id);
    return row ? toAsset(row as AssetRow) : null;
  }

  expired(now: string): Asset[] {
    const rows = this.#database
      .prepare('SELECT * FROM assets WHERE delete_at IS NOT NULL AND delete_at <= ?')
      .all(now);
    return rows.map((row) => toAsset(row as AssetRow));
  }

  pendingGithubChecks(before: string): Asset[] {
    const rows = this.#database
      .prepare(`
        SELECT * FROM assets
        WHERE github_owner IS NOT NULL
          AND github_repo IS NOT NULL
          AND github_pr IS NOT NULL
          AND merged_at IS NULL
          AND (last_github_check_at IS NULL OR last_github_check_at <= ?)
      `)
      .all(before);
    return rows.map((row) => toAsset(row as AssetRow));
  }

  attachGithub(id: string, owner: string, repo: string, pullRequest: number, delayMs: number): boolean {
    const result = this.#database
      .prepare(`
        UPDATE assets SET
          github_owner = ?, github_repo = ?, github_pr = ?, delete_after_merge_ms = ?,
          merged_at = NULL, last_github_check_at = NULL
        WHERE id = ?
      `)
      .run(owner, repo, pullRequest, delayMs, id);
    return result.changes === 1;
  }

  markGithubChecked(id: string, checkedAt: string): void {
    this.#database.prepare('UPDATE assets SET last_github_check_at = ? WHERE id = ?').run(checkedAt, id);
  }

  markMerged(id: string, mergedAt: string, deleteAt: string): void {
    this.#database
      .prepare('UPDATE assets SET merged_at = ?, delete_at = ?, last_github_check_at = ? WHERE id = ?')
      .run(mergedAt, deleteAt, new Date().toISOString(), id);
  }

  delete(id: string): void {
    this.#database.prepare('DELETE FROM assets WHERE id = ?').run(id);
  }

  close(): void {
    this.#database.close();
  }
}
