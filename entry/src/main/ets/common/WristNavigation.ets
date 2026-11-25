const NO_FLOOR: string[] = ['saved', 'groups', 'group', 'groupPicker', 'starred', 'deviceAuth'];

export function allowsQuickFloor(kind: string): boolean {
  return !NO_FLOOR.includes(kind);
}

export function rootSwipeTarget(index: number, count: number, x: number, y: number): number {
  if (!Number.isInteger(index) || index < 0 || index >= count || !Number.isFinite(x) || !Number.isFinite(y) ||
    Math.abs(x) < 40 || Math.abs(x) < Math.abs(y) * 1.4) { return -1; }
  const next = index + (x < 0 ? 1 : -1);
  return next >= 0 && next < count ? next : -1;
}
