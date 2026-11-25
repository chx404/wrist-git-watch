export class WatchTab {
  readonly title: string;
  readonly key: string;
  constructor(title: string, key: string) {
    this.title = title;
    this.key = key;
  }
}

// Native Swiper reports each child's position in page widths, relative to its viewport.
// A child arriving from either side produces the same continuous viewport coordinate.
export function watchPageProgress(index: number, position: number, count: number): number {
  if (!Number.isFinite(index) || !Number.isFinite(position) || !Number.isInteger(count) || count <= 0) { return 0; }
  return Math.max(0, Math.min(count - 1, index - position));
}
