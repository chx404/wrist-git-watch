import { curves } from '@kit.ArkUI';
import { clampDockSlot, DOCK_HEIGHT, DOCK_LENS_HEIGHT, DOCK_RAIL_THICKNESS, DOCK_TOUCH_HEIGHT, DockGeometry,
  dockDragSlot, dockDragTarget, dockGlassOpacity } from '../common/DockGeometry';

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
  @Prop dark: boolean = false;
  onSelect: (index: number) => void = () => {};

  @State private geometry: DockGeometry = new DockGeometry(0);
  @State private previewSlot: number = 0;
  @State private dragging: boolean = false;
  @State private groupScale: number = 1;
  private family: string = '';
  private morphTimer: number = -1;
  private panOrigin: number = 0;
  private panActive: boolean = false;
  private settleTimer: number = -1;

  aboutToAppear(): void {
    this.previewSlot = this.selectedSlot();
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
    if (!this.dragging && this.previewSlot === slot) { return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.28, 0.86, 0.12) }, () => {
      this.previewSlot = slot;
      this.dragging = false;
    });
  }

  private requestSelection(index: number): void {
    this.panActive = false;
    if (index < 0 || index >= this.tabs.length || index === this.selectedSlot()) {
      this.syncSelection();
      return;
    }
    // The page owns selection. Leave navigation outside the glass animation transaction.
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
      this.previewSlot = dockDragSlot(this.panOrigin, offset, this.geometry.slotWidth(this.tabs.length), this.tabs.length);
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
  }

  @Builder
  railStroke(radiusShift: number, inset: number, thickness: number, color: string) {
    Path({ width: this.geometry.width, height: DOCK_HEIGHT, commands: this.geometry.strokePath(radiusShift, inset) })
      .fill(Color.Transparent).stroke(color).strokeWidth(thickness).strokeLineCap(LineCapStyle.Round)
      .position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None)
  }

  private indexOf(key: string): number {
    return this.tabs.findIndex((tab: DockTab) => tab.key === key);
  }

  private hitBand(index: number, relative: boolean = false): Rectangle {
    const width = this.geometry.slotWidth(this.tabs.length);
    const offset = relative ? this.geometry.cellTop(index, this.tabs.length) : 0;
    return {
      x: relative ? 0 : this.geometry.cellLeft(index, this.tabs.length),
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
  cellGlass(tab: DockTab) {
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
      .linearGradient({ angle: 155, colors: [
        [this.dark ? '#B96CBAF5' : '#F1FFFFFF', 0],
        [this.dark ? '#9C31598D' : '#ABE4F5FF', 0.46],
        [this.dark ? '#C5327899' : '#E2B9E9FF', 1]
      ] })
      .border({ width: 0.8, color: this.dark ? '#C48FD4FF' : '#EAFFFFFF' })
      .shadow({ radius: 4, color: this.dark ? '#7849CBFF' : '#685899D9', offsetX: 0, offsetY: 0 })
      .scale({ x: this.dragging ? 1.06 : 1, y: this.dragging ? 0.93 : 1 })
    }
    .width(this.geometry.lensWidth(this.tabs.length)).height(DOCK_LENS_HEIGHT)
    .opacity(dockGlassOpacity(this.indexOf(tab.key), this.previewSlot))
    .accessibilityLevel('no-hide-descendants')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  dockCell(tab: DockTab) {
    Button({ type: ButtonType.Capsule }) {
      // Glass and text share this native center. Only the whole button is positioned on the rail.
      Stack({ alignContent: Alignment.Center }) {
        this.cellGlass(tab)
        Text(tab.title)
          .fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontWeight(this.indexOf(tab.key) === this.selectedSlot() ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.indexOf(tab.key) === Math.round(this.previewSlot) ? (this.dark ? '#FFFFFF' : '#0C3764') :
            (this.dark ? '#D5E1F1' : '#394F67'))
          .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
      }
      .width('100%').height('100%')
    }
    .width(this.geometry.slotWidth(this.tabs.length)).height(DOCK_RAIL_THICKNESS).padding(0)
    .position({
      x: this.geometry.cellLeft(this.indexOf(tab.key), this.tabs.length),
      y: this.geometry.cellTop(this.indexOf(tab.key), this.tabs.length)
    })
    .backgroundColor(Color.Transparent).stateEffect(false).clip(false)
    .responseRegion(this.hitBand(this.indexOf(tab.key), true))
    .accessibilityText(this.indexOf(tab.key) === this.selectedSlot() ? `${tab.title}，已选中` : tab.title)
    .onClick(() => { this.requestSelection(this.indexOf(tab.key)); })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.geometry.width > 0 && this.tabs.length > 0) {
        this.railStroke(0, 0, DOCK_RAIL_THICKNESS + 1.5, this.dark ? '#506BBCF6' : '#48759AC8')
        this.railStroke(0, 0, DOCK_RAIL_THICKNESS, this.dark ? '#EA223952' : '#E1E2F0FF')
        this.railStroke(-8, 0.035, 1, this.dark ? '#64C7E5FF' : '#F8FFFFFF')
        this.railStroke(8, 0.055, 0.8, this.dark ? '#416FDEF1' : '#949FCFE6')
        ForEach(this.tabs, (tab: DockTab) => { this.dockCell(tab) }, (tab: DockTab) => tab.key)
      }
    }
    .width('100%').height(DOCK_HEIGHT)
    .onAreaChange((_old: Area, next: Area) => { this.measureRail(Number(next.width)); })
    .scale({ x: this.groupScale, y: this.groupScale, centerX: '50%', centerY: '100%' })
    .responseRegion(this.hitBands())
    .priorityGesture(PanGesture({ direction: PanDirection.Horizontal, distance: 5 })
      .onActionStart((event: GestureEvent) => { this.startPan(event.offsetX); })
      .onActionUpdate((event: GestureEvent) => { this.updatePan(event.offsetX); })
      .onActionEnd((event: GestureEvent) => { this.endPan(event.offsetX); })
      .onActionCancel(() => { if (this.panActive) { this.syncSelection(); } }))
  }
}
