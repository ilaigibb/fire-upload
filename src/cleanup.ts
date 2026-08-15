import { join } from 'node:path';
import type { AssetDatabase } from './database.js';
import { removeStoredFile } from './storage.js';

export async function deleteExpiredAssets(database: AssetDatabase, filesDir: string): Promise<void> {
  for (const asset of database.expired(new Date().toISOString())) {
    try {
      await removeStoredFile(filesDir, asset.relativePath);
      database.delete(asset.id);
    } catch (error) {
      console.error(`Failed to delete expired asset ${asset.id} at ${join(filesDir, asset.relativePath)}:`, error);
    }
  }
}
