import { timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';

export function isAuthorized(request: IncomingMessage, expected: string): boolean {
  const actual = request.headers['x-upload-token'];
  if (typeof actual !== 'string') return false;

  const actualBuffer = Buffer.from(actual);
  const expectedBuffer = Buffer.from(expected);
  return actualBuffer.length === expectedBuffer.length && timingSafeEqual(actualBuffer, expectedBuffer);
}
