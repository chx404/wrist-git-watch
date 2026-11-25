import { curves } from '@kit.ArkUI';
import { clampDockSlot, DOCK_HEIGHT, DOCK_LENS_HEIGHT, DOCK_RAIL_THICKNESS, DOCK_TOUCH_HEIGHT, DockGeometry,
  dockDragSlot, dockDragTarget } from '../common/DockGeometry';

export class DockTab {
  readonly title: string;
  readonly key: string;

  constructor(title: string, key: string = '') {
    this.title = title;
    this.key = key || title;
  }
}

/** Place at bottom center of the round viewport: 62% of diameter × 46 vp, bottom inset 5 vp. */
@Component
export struct GlassDock {
  @Prop @Watch('syncSelection') tabs: DockTab[] = [];
  @Prop @Watch('syncSelection') selected: number = 0;
  @Prop @Watch('paintRail') dark: boolean = false;
  onSelect: (index: number) => void = () => {};

  @State private geometry: DockGeometry = new DockGeometry(0);
  @State private lensSlot: number = 0;
  @State private dragging: boolean = false;
  @State private groupScale: number = 1;
  private family: string = '';
  private morphTimer: number = -1;
  private readonly rail: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private panOrigin: number = 0;
  private panActive: boolean = false;
  private settleTimer: number = -1;

  aboutToAppear(): void {
    this.lensSlot = this.selectedSlot();
    this.family = this.tabs[0]?.key ?? '';
  }

  aboutToDisappear(): void {
    this.clearSettleTimer();
    if (this.morphTimer >= 0) { clearTimeout(this.morphTimer); }
    this.morphTimer = -1;
  }

  private morphFamily(): void {
    const family = this.tabs[0]?.key ?? '';
    if (family === this.family) { return; }
    this.family = family;
    // Home and repository tabs can have identical selected indices. A tiny
    // compression-and-spring keeps their transition visible without faking a move to another tab.
    if (this.morphTimer >= 0) { clearTimeout(this.morphTimer); }
    this.getUIContext().animateTo({ duration: 85, curve: Curve.EaseOut }, () => { this.groupScale = 0.94; });
    this.morphTimer = setTimeout(() => {
      this.morphTimer = -1;
      this.getUIContext().animateTo({ curve: curves.springMotion(0.27, 0.82, 0.1) }, () => { this.groupScale = 1; });
    }, 80);
  }

  private selectedSlot(): number {
    return clampDockSlot(this.selected, this.tabs.length);
  }

  private clearSettleTimer(): void {
    if (this.settleTimer >= 0) { clearTimeout(this.settleTimer); }
    this.settleTimer = -1;
  }

  private syncSelection(): void {
    this.morphFamily();
    this.clearSettleTimer();
    // Any external update (including Back) takes precedence over an in-flight scrub.
    this.panActive = false;
    const slot = this.selectedSlot();
    if (!this.dragging && this.lensSlot === slot) { return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.28, 0.86, 0.12) }, () => {
      this.lensSlot = slot;
      this.dragging = false;
    });
  }

  private requestSelection(index: number): void {
    this.panActive = false;
    if (index < 0 || index >= this.tabs.length || index === this.selectedSlot()) {
      this.syncSelection();
      return;
    }
    // The page owns selection. Leave navigation outside the lens animation transaction.
    this.onSelect(index);
    if (this.dragging && this.settleTimer < 0) {
      // If the host declines a swipe, spring back to the accepted prop instead of hanging mid-rail.
      this.settleTimer = setTimeout(() => this.syncSelection(), 40);
    }
  }

  private startPan(offset: number): void {
    if (this.tabs.length < 2 || this.geometry.width <= 0) { return; }
    this.clearSettleTimer();
    this.panOrigin = this.selectedSlot();
    this.panActive = true;
    this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => { this.dragging = true; });
    this.updatePan(offset);
  }

  private updatePan(offset: number): void {
    if (this.panActive) {
      this.lensSlot = dockDragSlot(this.panOrigin, offset, this.geometry.slotWidth(this.tabs.length), this.tabs.length);
    }
  }

  private endPan(offset: number): void {
    if (this.panActive) {
      this.requestSelection(dockDragTarget(this.panOrigin, offset, this.geometry.slotWidth(this.tabs.length), this.tabs.length));
    }
  }

  private measureRail(width: number): void {
    if (Number.isFinite(width) && width > 0 && width !== this.geometry.width) {
      this.geometry = new DockGeometry(width);
    }
    this.paintRail();
  }

  private railStroke(radius: number, halfAngle: number, thickness: number, color: string | CanvasGradient): void {
    const ctx = this.rail;
    ctx.strokeStyle = color;
    ctx.lineWidth = thickness;
    ctx.beginPath();
    ctx.arc(this.geometry.centerX, this.geometry.centerY, radius, Math.PI / 2 - halfAngle, Math.PI / 2 + halfAngle);
    ctx.stroke();
  }

  private paintRail(): void {
    const arc = this.geometry;
    const ctx = this.rail;
    if (ctx.width <= 0 || arc.halfAngle <= 0.06) { return; }
    ctx.clearRect(0, 0, arc.width, DOCK_HEIGHT);
    ctx.lineCap = 'round';
    const tint = ctx.createLinearGradient(arc.width * 0.25, 5, arc.width * 0.7, 44);
    tint.addColorStop(0, this.dark ? 'rgba(61,87,116,0.89)' : 'rgba(255,255,255,0.92)');
    tint.addColorStop(0.52, this.dark ? 'rgba(24,40,61,0.92)' : 'rgba(232,243,255,0.88)');
    tint.addColorStop(1, this.dark ? 'rgba(19,37,55,0.95)' : 'rgba(200,223,248,0.9)');
    this.railStroke(arc.radius, arc.halfAngle, DOCK_RAIL_THICKNESS + 1.5,
      this.dark ? 'rgba(107,187,246,0.25)' : 'rgba(117,154,200,0.27)');
    this.railStroke(arc.radius, arc.halfAngle, DOCK_RAIL_THICKNESS, tint);

    // Offset the highlights radially, so they remain on the edges even at the tips.
    const glint = ctx.createLinearGradient(0, 0, arc.width, 0);
    glint.addColorStop(0, 'rgba(255,255,255,0)');
    glint.addColorStop(0.3, this.dark ? 'rgba(199,229,255,0.45)' : 'rgba(255,255,255,0.98)');
    glint.addColorStop(0.62, this.dark ? 'rgba(164,215,251,0.24)' : 'rgba(255,255,255,0.82)');
    glint.addColorStop(1, 'rgba(255,255,255,0)');
    this.railStroke(Math.max(1, arc.radius - 8), arc.halfAngle - 0.035, 1, glint);
    this.railStroke(arc.radius + 8, arc.halfAngle - 0.055, 0.8,
      this.dark ? 'rgba(111,222,241,0.23)' : 'rgba(159,207,230,0.58)');
  }

  private indexOf(key: string): number {
    return this.tabs.findIndex((tab: DockTab) => tab.key === key);
  }

  private hitBand(index: number, relative: boolean = false): Rectangle {
    const width = this.geometry.slotWidth(this.tabs.length);
    const offset = relative ? this.geometry.slotY(index, this.tabs.length) - DOCK_RAIL_THICKNESS / 2 : 0;
    return {
      x: relative ? 0 : this.geometry.slotX(index, this.tabs.length) - width / 2,
      y: this.geometry.touchTop(index, this.tabs.length) - offset,
      width,
      height: DOCK_TOUCH_HEIGHT
    };
  }

  private hitBands(): Rectangle[] {
    const bands: Rectangle[] = [];
    if (this.geometry.width > 0) {
      for (let index = 0; index < this.tabs.length; index++) { bands.push(this.hitBand(index)); }
    }
    return bands.length > 0 ? bands : [{ x: 0, y: 0, width: 0, height: 0 }];
  }

  @Builder
  lens() {
    Stack() {
      Stack({ alignContent: Alignment.Top }) {
        Row()
          .width('77%').height(1.3).borderRadius(1).margin({ top: 1.4 })
          .linearGradient({ angle: 90, colors: [[Color.Transparent, 0], ['#EFFFFFFF', 0.42], [Color.Transparent, 1]] })
        Row()
          .width('74%').height(1).borderRadius(1).margin({ top: DOCK_LENS_HEIGHT - 2.5 })
          .linearGradient({ angle: 90, colors: [[Color.Transparent, 0], [this.dark ? '#D28DF5FF' : '#AF3CB6EA', 0.6],
            [Color.Transparent, 1]] })
      }
      .width('100%').height('100%').borderRadius(DOCK_LENS_HEIGHT / 2)
      .backgroundBlurStyle(BlurStyle.Thin, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT, scale: 0.65 })
      .linearGradient({ angle: 155, colors: [
        [this.dark ? '#B96CBAF5' : '#F1FFFFFF', 0],
        [this.dark ? '#9C31598D' : '#ABE4F5FF', 0.46],
        [this.dark ? '#C5327899' : '#E2B9E9FF', 1]
      ] })
      .border({ width: 0.8, color: this.dark ? '#C48FD4FF' : '#EAFFFFFF' })
      .clip(true)
      .shadow({ radius: 4, color: this.dark ? '#7849CBFF' : '#685899D9', offsetX: 0, offsetY: 0 })
      .scale({ x: this.dragging ? 1.06 : 1, y: this.dragging ? 0.93 : 1 })
    }
    .width(this.geometry.lensWidth(this.tabs.length)).height(DOCK_LENS_HEIGHT)
    .position({
      x: this.geometry.centerX - this.geometry.lensWidth(this.tabs.length) / 2,
      y: this.geometry.centerY + this.geometry.radius - DOCK_LENS_HEIGHT / 2
    })
    // Tween a single native transform about the face center; x/y tweens would cut across the arc.
    .rotate({ z: 1, centerX: '50%', centerY: DOCK_LENS_HEIGHT / 2 - this.geometry.radius,
      angle: -this.geometry.slotAngle(this.lensSlot, this.tabs.length) * 180 / Math.PI })
    .accessibilityLevel('no-hide-descendants')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  dockButton(tab: DockTab) {
    Button(tab.title, { type: ButtonType.Capsule })
      .width(this.geometry.slotWidth(this.tabs.length)).height(DOCK_RAIL_THICKNESS).padding(0).fontSize(11)
      .fontWeight(this.indexOf(tab.key) === this.selectedSlot() ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.indexOf(tab.key) === Math.round(this.lensSlot) ? (this.dark ? '#FFFFFF' : '#0C3764') :
        (this.dark ? '#D5E1F1' : '#394F67'))
      .position({
        x: this.geometry.slotX(this.indexOf(tab.key), this.tabs.length) - this.geometry.slotWidth(this.tabs.length) / 2,
        y: this.geometry.slotY(this.indexOf(tab.key), this.tabs.length) - DOCK_RAIL_THICKNESS / 2
      })
      .backgroundColor(Color.Transparent).stateEffect(false)
      .responseRegion(this.hitBand(this.indexOf(tab.key), true))
      .accessibilitySelected(this.indexOf(tab.key) === this.selectedSlot())
      .onClick(() => { this.requestSelection(this.indexOf(tab.key)); })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.rail).width('100%').height(DOCK_HEIGHT)
        .onReady(() => { this.measureRail(this.rail.width); })
        .onSizeChange((_old: SizeOptions, next: SizeOptions) => { this.measureRail(Number(next.width)); })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
      if (this.geometry.width > 0 && this.tabs.length > 0) {
        this.lens()
        ForEach(this.tabs, (tab: DockTab) => { this.dockButton(tab) }, (tab: DockTab) => tab.key)
      }
    }
    .width('100%').height(DOCK_HEIGHT)
    .scale({ x: this.groupScale, y: this.groupScale, centerX: '50%', centerY: '100%' })
    .responseRegion(this.hitBands())
    .priorityGesture(PanGesture({ direction: PanDirection.Horizontal, distance: 5 })
      .onActionStart((event: GestureEvent) => { this.startPan(event.offsetX); })
      .onActionUpdate((event: GestureEvent) => { this.updatePan(event.offsetX); })
      .onActionEnd((event: GestureEvent) => { this.endPan(event.offsetX); })
      .onActionCancel(() => { if (this.panActive) { this.syncSelection(); } }))
  }
}
