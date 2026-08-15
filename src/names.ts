import { randomBytes } from 'node:crypto';
import { extname } from 'node:path';

const MAX_BASENAME_LENGTH = 100;

function cleanPart(value: string): string {
  return value
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, MAX_BASENAME_LENGTH);
}

export function makeStoredName(input: string): { id: string; name: string; originalName: string } {
  const originalName = decodeURIComponent(input).split(/[\\/]/).at(-1)?.trim() ?? '';
  if (!originalName || originalName === '.' || originalName === '..') {
    throw new Error('filename is required');
  }

  const extension = extname(originalName).toLowerCase().replace(/[^a-z0-9.]/g, '');
  const stem = originalName.slice(0, originalName.length - extname(originalName).length);
  const safeStem = cleanPart(stem) || 'file';
  const id = randomBytes(8).toString('hex');

  return {
    id,
    name: `${safeStem}-${id}${extension}`,
    originalName,
  };
}
