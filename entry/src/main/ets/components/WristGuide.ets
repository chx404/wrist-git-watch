import { DAY_LOOK, Look, NIGHT_LOOK } from '../common/Look';

class GuideStep {
  label: string;
  title: string;
  body: string;
  symbol: string;
  constructor(label: string, title: string, body: string, symbol: string) {
    this.label = label;
    this.title = title;
    this.body = body;
    this.symbol = symbol;
  }
}

const STEPS: GuideStep[] = [
  new GuideStep('快捷面板', '在页首向下滑', '打开当前页面的负一屏。首页的探索、榜单、最新都在里面。', '↓'),
  new GuideStep('横向翻页', '在正文左右滑动', '底部短条会随页面移动，也可点圆点切换。仓库里可以横滑到文档、代码和发布。', '↔'),
  new GuideStep('阅读与外观', '转动表冠滚动', '到边缘继续转动会回弹。负一屏可切换浅色或黑色主题。', '⟳')
];

@Component
export struct WristGuide {
  @Prop dark: boolean = false;
  @State private step: number = 0;
  onFinish: (tryFloor: boolean) => void = (_tryFloor: boolean) => {};

  private theme(): Look { return this.dark ? NIGHT_LOOK : DAY_LOOK; }

  private next(): void {
    if (this.step + 1 >= STEPS.length) { this.onFinish(true); return; }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.step++; });
  }

  build() {
    Scroll() {
      Column({ space: 6 }) {
        Text(`上手引导  ${this.step + 1} / ${STEPS.length}`).fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.theme().blue)
        Stack() {
          Circle().width(42).height(42).fill(this.theme().pale)
          Text(STEPS[this.step].symbol).fontSize(25).fontWeight(FontWeight.Bold).fontColor(this.theme().blue)
        }.width(42).height(42)
        Text(STEPS[this.step].label).fontSize(10).fontColor(this.theme().muted)
        Text(STEPS[this.step].title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.theme().ink).textAlign(TextAlign.Center)
        Text(STEPS[this.step].body).width('100%').fontSize(12).lineHeight(17).fontColor(this.theme().muted).textAlign(TextAlign.Center)
        Row({ space: 4 }) {
          ForEach(STEPS, (item: GuideStep, idx: number) => {
            Blank().width(idx === this.step ? 15 : 5).height(4).borderRadius(2)
              .backgroundColor(idx === this.step ? this.theme().blue : this.theme().border)
          }, (item: GuideStep) => item.label)
        }.margin({ top: 1, bottom: 1 })
        Button(this.step + 1 === STEPS.length ? '试试快捷面板' : '下一步', { type: ButtonType.Capsule })
          .width('75%').height(34).fontSize(12).backgroundColor(this.theme().blue).fontColor(this.theme().accentText)
          .onClick(() => this.next())
        Button('跳过', { type: ButtonType.Capsule }).height(29).width('55%').backgroundColor(this.theme().pale)
          .fontSize(11).fontColor(this.theme().blue).onClick(() => this.onFinish(false))
      }.width('74%').padding({ top: 32, bottom: 40 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
      .backgroundColor(this.theme().bg)
  }
}
