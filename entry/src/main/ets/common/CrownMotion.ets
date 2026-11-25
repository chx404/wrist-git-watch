// API 18+ wearable wiring (vertical Scroll):
// 1. Attach .id('page-scroll').focusable(true).defaultFocus(true) and
//    .onDigitalCrown(...) to the actual Scroll bound to the page Scroller. Do
//    not put the callback on a sibling or on an ancestor of a native Scroll:
//    input follows the focus path and a child can consume it first. On the
//    same Scroll, the custom callback replaces its native crown handler;
//    leaving propagation enabled does not fall back to native Scroll physics.
// 2. Default focus only initializes the focus view. In a page that explicitly
//    clears focus on navigation, use getUIContext().getFocusController()
//    .requestFocus('page-scroll') after the node is mounted, on initial entry
//    and after that intentional clear when returning to non-editing content.
//    Catch a missing/unfocusable target. Don't retry on a loop, request on
//    every blur, or make the Scroll .focusOnTouch(true) around text fields.
//    Cancel queued requests while an editor, overlay, or different page owns
//    focus. The Scroll stays a scope so its focusable descendants still work.
// 3. Construct CrownMotion with a bounded, nonanimated Scroller.scrollTo
//    callback and two callbacks to set/animate an @State translation on the
//    padded content Column (not the Scroll viewport, dock, or floor). Pass
//    content height minus viewport height, floored at zero, in vp. Measure
//    both in onAreaChange; don't treat as short until both are measured.
//    For each claimed BEGIN/UPDATE/END, stopPropagation, apply any nonzero
//    relative event.degree using scroller.currentOffset().yOffset, and call
//    settle() on END (even if degree is zero). While editing/touch-dragging,
//    skip crown motion and do not claim it from a child handling its own input.
// 4. reset() on actual Scroll blur, touch-down, content/range replacement,
//    edit focus, overlay open and page hide. Keep the floor gesture gated by
//    actual touch events: the native crown backend can also report DRAG.
// Native-only alternative: remove onDigitalCrown and use .digitalCrownSensitivity
// (CrownSensitivity.MEDIUM) with the same focus policy. That mode uses native
// inertia and EdgeEffect.Spring, not the isolated spring implemented here.

export interface CrownStep {
  targetY: number;
  pull: number;
  translationY: number;
}

export const CROWN_EDGE_LIMIT_VP: number = 24;
export const CROWN_STEP_LIMIT_VP: number = 64;
const EDGE_RESISTANCE_VP: number = 24;
const MAX_PULL_VP: number = 96;
const CROWN_IDLE_MS: number = 120;
const CROWN_END_HOLD_MS: number = 42;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

export function crownScrollRange(viewportHeight: number, contentHeight: number): number {
  if (!Number.isFinite(viewportHeight) || !Number.isFinite(contentHeight) || viewportHeight <= 0 || contentHeight < 0) {
    return -1; // Unmeasured, not an intentionally short list.
  }
  return Math.max(0, contentHeight - viewportHeight);
}

export function crownDelta(degree: number, vpPerDegree: number = 1.3, direction: number = 1): number {
  if (!Number.isFinite(degree) || !Number.isFinite(vpPerDegree) || vpPerDegree <= 0 ||
    (direction !== 1 && direction !== -1) || degree === 0) {
    return 0;
  }
  return clamp(clamp(degree, -360, 360) * vpPerDegree * direction, -CROWN_STEP_LIMIT_VP, CROWN_STEP_LIMIT_VP);
}

// Positive scroll Y reveals later content. Positive visual Y instead pushes
// content down, so start overscroll is positive and end overscroll is negative.
// Only the portion that the native scroll range cannot absorb feeds the edge.
export function crownStep(currentY: number, maximumY: number, deltaY: number, previousPull: number = 0): CrownStep {
  const maximum = Number.isFinite(maximumY) ? Math.max(0, maximumY) : 0;
  const boundedY = Number.isFinite(currentY) ? clamp(currentY, 0, maximum) : 0;
  const delta = Number.isFinite(deltaY) ? deltaY : 0;
  const used = clamp(delta, -boundedY, maximum - boundedY);
  const remaining = delta - used;
  // On reversal scroll immediately, rather than first spending many ticks
  // unwinding a hidden overscroll distance. Don't keep a stale edge after a
  // change in bounds or after the native Scroller handled part of the delta.
  const prior = clamp(Number.isFinite(previousPull) ? previousPull : 0, -MAX_PULL_VP, MAX_PULL_VP);
  const stillAtSameEdge = used === 0 && prior !== 0 && Math.sign(prior) === Math.sign(remaining);
  const pull = clamp(remaining + (stillAtSameEdge ? prior : 0), -MAX_PULL_VP, MAX_PULL_VP);
  const translationY = pull === 0 ? 0 : -CROWN_EDGE_LIMIT_VP * pull / (EDGE_RESISTANCE_VP + Math.abs(pull));
  return { targetY: clamp(boundedY + used, 0, maximum), pull, translationY };
}

// Owns only ephemeral crown state. The caller owns focus, layout, the native
// Scroller and animation context. Reuse one instance per visible scroll view.
export class CrownMotion {
  private pull: number = 0;
  private idleTimer: number = -1;
  private readonly scrollToY: (y: number) => void;
  private readonly setTranslationY: (y: number) => void;
  private readonly springToRest: () => void;
  private readonly vpPerDegree: number;
  private readonly direction: number;

  constructor(scrollToY: (y: number) => void, setTranslationY: (y: number) => void, springToRest: () => void,
    vpPerDegree: number = 1.3, direction: number = 1) {
    this.scrollToY = scrollToY;
    this.setTranslationY = setTranslationY;
    this.springToRest = springToRest;
    this.vpPerDegree = vpPerDegree;
    this.direction = direction;
  }

  apply(degree: number, currentY: number, maximumY: number): void {
    const delta = crownDelta(degree, this.vpPerDegree, this.direction);
    if (delta === 0 || !Number.isFinite(currentY) || !Number.isFinite(maximumY) || maximumY < 0) {
      return;
    }
    const next = crownStep(currentY, maximumY, delta, this.pull);
    if (next.targetY !== currentY) {
      this.scrollToY(next.targetY);
    }
    if (next.pull !== this.pull) {
      this.pull = next.pull;
      this.setTranslationY(next.translationY);
    }
    this.clearTimer();
    if (this.pull !== 0) {
      this.scheduleRest(CROWN_IDLE_MS); // The terminal event may be lost.
    }
  }

  settle(): void {
    if (this.pull !== 0) {
      this.clearTimer();
      // A platform can bundle the only nonzero delta into END. Give the
      // displaced frame time to render before starting the return spring.
      this.scheduleRest(CROWN_END_HOLD_MS);
    }
  }

  reset(): void {
    this.clearTimer();
    this.pull = 0;
    this.setTranslationY(0);
  }

  private clearTimer(): void {
    if (this.idleTimer !== -1) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
  }

  private scheduleRest(delayMs: number): void {
    this.idleTimer = setTimeout(() => {
      this.idleTimer = -1;
      this.pull = 0;
      this.springToRest();
    }, delayMs);
  }
}
