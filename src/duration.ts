const DURATION_PATTERN = /^(\d+)([hdw])$/i;
const UNITS: Readonly<Record<string, number>> = {
  h: 60 * 60 * 1000,
  d: 24 * 60 * 60 * 1000,
  w: 7 * 24 * 60 * 60 * 1000,
};

export function parseDuration(value: string): number {
  const match = DURATION_PATTERN.exec(value.trim());
  if (!match) throw new Error('duration must use h, d, or w, for example 12h, 7d, or 4w');

  const amount = Number(match[1]);
  const multiplier = UNITS[match[2]?.toLowerCase() ?? ''];
  if (!Number.isSafeInteger(amount) || amount <= 0 || multiplier === undefined) {
    throw new Error('duration must be positive');
  }

  const result = amount * multiplier;
  if (!Number.isSafeInteger(result)) throw new Error('duration is too large');
  return result;
}
