export class DockTab {
  readonly title: string;
  constructor(title: string) { this.title = title; }
}

/** Compact floating navigation for a round canvas; drag or tap to select. */
@Component
export struct GlassDock {
  @Prop tabs: DockTab[] = [];
  @Prop selected: number = 0;
  @State private measured: number = 0;
  @State private drag: number = 0;
  @State private dragging: boolean = false;
  onSelect: (index: number) => void = () => {};

  private segment(): number {
    return Math.max(0, this.measured - 10) / Math.max(1, this.tabs.length);
  }

  private indicatorX(): number {
    const segment = this.segment();
    return 5 + Math.min((this.tabs.length - 1) * segment, Math.max(0, this.selected * segment + this.drag));
  }

  private commit(index: number): void {
    const target: number = Math.max(0, Math.min(this.tabs.length - 1, index));
    this.getUIContext().animateTo({ duration: 210, curve: Curve.EaseOut }, () => {
      this.dragging = false;
      this.drag = 0;
      if (target !== this.selected) { this.onSelect(target); }
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.measured > 10) {
        Blank()
          .width(Math.max(0, this.segment() - 2)).height(this.dragging ? 31 : 32)
          .position({ x: 1 + this.indicatorX(), y: this.dragging ? 5.5 : 5 })
          .linearGradient({ angle: 145, colors: [['#ACD9F6FF', 0], ['#A6CEE5FF', 0.55], ['#D2F2E9FF', 1]] })
          .border({ width: 1, color: '#EEFFFFFF' }).borderRadius(20)
          .shadow({ radius: 6, color: '#304783D4', offsetX: 0, offsetY: 2 })
          .hitTestBehavior(HitTestMode.None)
      }
      Row() {
        ForEach(this.tabs, (tab: DockTab, index: number) => {
          Button(tab.title, { type: ButtonType.Capsule })
            .padding(0).layoutWeight(1).height(38).fontSize(11)
            .fontWeight(index === this.selected ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(index === this.selected ? '#123D9C' : '#354B67')
            .backgroundColor(Color.Transparent).stateEffect(false)
            .accessibilityText(index === this.selected ? `${tab.title}，已选中` : tab.title)
            .onClick(() => this.commit(index))
        }, (tab: DockTab) => tab.title)
      }.width('100%').padding({ left: 5, right: 5 })
    }
    .width('100%').height(42).borderRadius(24)
    .backgroundBlurStyle(BlurStyle.Thin)
    .linearGradient({ angle: 155, colors: [['#E8FFFFFF', 0], ['#C7E9F3FF', 0.45], ['#DEF8F4FF', 1]] })
    .border({ width: 1, color: '#F0FFFFFF' })
    .shadow({ radius: 12, color: '#405075AE', offsetX: 0, offsetY: 3 })
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      if (Number.isFinite(width) && width > 0 && width !== this.measured) { this.measured = width; }
    })
    .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 6 })
      .onActionStart((_event: GestureEvent) => { this.dragging = true; })
      .onActionUpdate((event: GestureEvent) => { this.drag = event.offsetX; })
      .onActionEnd((event: GestureEvent) => {
        if (this.segment() > 0) {
          const slots = event.offsetX / this.segment();
          const fling = Math.abs(slots) < 0.5 && Math.abs(event.offsetX) >= 14 ? Math.sign(event.offsetX) * 0.52 : 0;
          this.commit(this.selected + Math.round(slots + fling));
        } else { this.commit(this.selected); }
      })
      .onActionCancel(() => { this.commit(this.selected); }))
  }
}
