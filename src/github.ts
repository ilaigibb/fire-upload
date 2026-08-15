import type { Asset, AssetDatabase } from './database.js';

type PullResponse = {
  merged_at: string | null;
};

function isPullResponse(value: unknown): value is PullResponse {
  if (typeof value !== 'object' || value === null || !('merged_at' in value)) return false;
  const mergedAt = value.merged_at;
  return typeof mergedAt === 'string' || mergedAt === null;
}

export function parsePullRequestUrl(value: string): { owner: string; pullRequest: number; repo: string } {
  const url = new URL(value);
  if (url.hostname !== 'github.com') throw new Error('PR URL must use github.com');

  const parts = url.pathname.split('/').filter(Boolean);
  if (parts.length !== 4 || parts[2] !== 'pull') throw new Error('invalid GitHub pull request URL');

  const pullRequest = Number(parts[3]);
  if (!Number.isSafeInteger(pullRequest) || pullRequest <= 0 || !parts[0] || !parts[1]) {
    throw new Error('invalid GitHub pull request URL');
  }

  return { owner: parts[0], repo: parts[1], pullRequest };
}

async function fetchPull(asset: Asset, token: string | null): Promise<PullResponse | null> {
  if (!asset.githubOwner || !asset.githubRepo || !asset.githubPr) return null;

  const response = await fetch(
    `https://api.github.com/repos/${encodeURIComponent(asset.githubOwner)}/${encodeURIComponent(asset.githubRepo)}/pulls/${asset.githubPr}`,
    {
      headers: {
        Accept: 'application/vnd.github+json',
        'User-Agent': 'fire-upload',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      signal: AbortSignal.timeout(15_000),
    },
  );

  if (!response.ok) return null;
  const value: unknown = await response.json();
  return isPullResponse(value) ? value : null;
}

export async function pollPullRequests(database: AssetDatabase, token: string | null, intervalMs: number): Promise<void> {
  const before = new Date(Date.now() - intervalMs).toISOString();
  for (const asset of database.pendingGithubChecks(before)) {
    const checkedAt = new Date().toISOString();
    try {
      const pull = await fetchPull(asset, token);
      if (pull?.merged_at && asset.deleteAfterMergeMs !== null) {
        const deleteAt = new Date(new Date(pull.merged_at).getTime() + asset.deleteAfterMergeMs).toISOString();
        database.markMerged(asset.id, pull.merged_at, deleteAt);
      } else {
        database.markGithubChecked(asset.id, checkedAt);
      }
    } catch (error) {
      database.markGithubChecked(asset.id, checkedAt);
      console.error(`GitHub check failed for asset ${asset.id}:`, error);
    }
  }
}
