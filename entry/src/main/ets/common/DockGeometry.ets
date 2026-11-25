// The dock is centered over a circular viewport of diameter D. Use width = .62D,
// height = 46 vp, bottom inset = 5 vp (absolute top = D - 51 vp).
export const DOCK_WIDTH_FRACTION: number = 0.62;
export const DOCK_HEIGHT: number = 46;
export const DOCK_BOTTOM_INSET: number = 5;
export const DOCK_RAIL_THICKNESS: number = 20;
export const DOCK_LENS_HEIGHT: number = 20;
export const DOCK_TOUCH_HEIGHT: number = 34;
const RAIL_INSET: number = 16;

export class DockGeometry {
  readonly width: number;
  readonly centerX: number;
  readonly centerY: number;
  readonly radius: number;
  readonly halfAngle: number;
  readonly tabSpan: number;

  constructor(width: number) {
    this.width = Math.max(0, width);
    const faceRadius = this.width / (2 * DOCK_WIDTH_FRACTION);
    this.centerX = this.width / 2;
    this.centerY = DOCK_HEIGHT + DOCK_BOTTOM_INSET - faceRadius;
    this.radius = Math.max(1, faceRadius - RAIL_INSET);
    // Leave room for rounded caps; limit the rise so the arc fits its 46 vp overlay on larger watches.
    const rise = Math.min(22, this.radius);
    const halfSpan = Math.max(0, Math.min(this.centerX - 12, Math.sqrt(rise * (2 * this.radius - rise))));
    this.halfAngle = Math.asin(halfSpan / this.radius);
    this.tabSpan = Math.min(this.width, 2 * (halfSpan + 8));
  }

  strokePath(radiusShift: number = 0, inset: number = 0): string {
    const radius = Math.max(1, this.radius + radiusShift);
    const halfAngle = Math.max(0, this.halfAngle - inset);
    if (this.width <= 0 || halfAngle === 0) { return 'M 0 0'; }
    const half = radius * Math.sin(halfAngle);
    const y = this.centerY + radius * Math.cos(halfAngle);
    return `M ${(this.centerX - half).toFixed(3)} ${y.toFixed(3)} A ${radius.toFixed(3)} ${radius.toFixed(3)} 0 0 0 ${(this.centerX + half).toFixed(3)} ${y.toFixed(3)}`;
  }

  slotWidth(count: number): number {
    return this.tabSpan / Math.max(1, count);
  }

  slotX(slot: number, count: number): number {
    return this.centerX + (slot - (count - 1) / 2) * this.slotWidth(count);
  }

  slotAngle(slot: number, count: number): number {
    const ratio = (this.slotX(slot, count) - this.centerX) / this.radius;
    return Math.asin(Math.max(-1, Math.min(1, ratio)));
  }

  slotY(slot: number, count: number): number {
    return this.centerY + this.radius * Math.cos(this.slotAngle(slot, count));
  }

  cellLeft(slot: number, count: number): number {
    return this.slotX(slot, count) - this.slotWidth(count) / 2;
  }

  cellTop(slot: number, count: number): number {
    return this.slotY(slot, count) - DOCK_RAIL_THICKNESS / 2;
  }

  touchTop(slot: number, count: number): number {
    return Math.max(0, Math.min(DOCK_HEIGHT - DOCK_TOUCH_HEIGHT, this.slotY(slot, count) - DOCK_TOUCH_HEIGHT / 2));
  }

  lensWidth(count: number): number {
    return Math.min(46, Math.max(1, this.slotWidth(count) - 2));
  }
}

export function clampDockSlot(slot: number, count: number): number {
  return Math.max(0, Math.min(count - 1, slot));
}

export function dockDragSlot(origin: number, offset: number, width: number, count: number): number {
  return clampDockSlot(width > 0 ? origin + offset / width : origin, count);
}

// A fractional preview blends only its two adjacent, stationary glass cells.
export function dockGlassOpacity(slot: number, previewSlot: number): number {
  return Math.max(0, 1 - Math.abs(slot - previewSlot));
}

export function dockDragTarget(origin: number, offset: number, width: number, count: number): number {
  if (width <= 0) { return clampDockSlot(origin, count); }
  const distance = Math.abs(offset);
  const steps = distance < 14 ? Math.round(distance / width) : Math.max(1, Math.round(distance / width));
  return clampDockSlot(origin + Math.sign(offset) * steps, count);
}
