import { MarkdownBlock, MarkdownCell, MarkdownDocument, MarkdownRun, parseMarkdown } from '../common/Markdown';

const INK: string = '#142238';
const MUTED: string = '#50627A';
const BLUE: string = '#1759E8';
const BORDER: string = '#DEE6F1';
const TINT: string = '#EDF2FA';
const TABLE_CELL_WIDTH: number = 110;

// Use embedded:true inside a parent Scroll. The parent may scroll to the rendered
// heading ID after layout; otherwise this component scrolls its own List.
@Component
export struct MarkdownView {
  @Prop @Watch('resetMarkdown') markdown: string = '';
  @Prop embedded: boolean = false;
  @Prop viewportHeight: number = 236;
  @Prop anchorIdPrefix: string = 'markdown-anchor-';
  onAnchor: (anchor: string, page: number) => void = (_anchor: string, _page: number): void => {};
  onPageChange: (page: number) => void = (_page: number): void => {};

  @State private document: MarkdownDocument = new MarkdownDocument();
  @State private page: number = 0;
  @State private revision: number = 0;
  private listScroller: Scroller = new Scroller();
  private scrollTicket: number = 0;

  aboutToAppear(): void {
    this.resetMarkdown();
  }

  aboutToDisappear(): void {
    this.scrollTicket++;
  }

  private resetMarkdown(): void {
    this.document = parseMarkdown(this.markdown);
    this.page = 0;
    this.revision++;
    if (!this.embedded) {
      this.scrollToBlock(0);
    }
  }

  private scrollToBlock(block: number): void {
    const ticket = ++this.scrollTicket;
    // Changing pages replaces the ListItems. Let ArkUI lay them out first.
    setTimeout(() => {
      if (ticket === this.scrollTicket) {
        this.listScroller.scrollToIndex(block, false, ScrollAlign.START);
      }
    }, 40);
  }

  private changePage(page: number): void {
    if (page < 0 || page >= this.document.pages.length || page === this.page) {
      return;
    }
    this.page = page;
    if (!this.embedded) {
      this.scrollToBlock(0);
    }
    this.onPageChange(page);
  }

  private jump(anchor: string): void {
    const position = this.document.anchors.get(anchor);
    if (position === undefined) {
      return;
    }
    // Anchor jumps have their own notification; ordinary pager clicks use onPageChange.
    this.page = position.page;
    if (!this.embedded) {
      this.scrollToBlock(position.block);
    }
    this.onAnchor(anchor, position.page);
  }

  private headingSize(level: number): number {
    switch (level) {
      case 1: return 20;
      case 2: return 18;
      case 3: return 16;
      default: return 14;
    }
  }

  private alignment(value: string): TextAlign {
    return value === 'center' ? TextAlign.Center : (value === 'right' ? TextAlign.End : TextAlign.Start);
  }

  @Builder
  private Rich(runs: MarkdownRun[], size: number, strong: boolean, alignment: TextAlign) {
    Text() {
      ForEach(runs, (run: MarkdownRun) => {
        if (run.anchor !== '') {
          Span(run.text)
            .fontColor(BLUE)
            .fontWeight(strong || run.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontFamily(run.code ? 'monospace' : 'HarmonyOS Sans')
            .textBackgroundStyle({ color: run.code ? TINT : Color.Transparent, radius: 3 })
            .decoration({ type: run.strike ? TextDecorationType.LineThrough : TextDecorationType.Underline })
            .onClick(() => this.jump(run.anchor))
        } else {
          Span(run.text)
            .fontColor(run.link || run.image ? MUTED : INK)
            .fontWeight(strong || run.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontFamily(run.code ? 'monospace' : 'HarmonyOS Sans')
            .textBackgroundStyle({ color: run.code ? TINT : Color.Transparent, radius: 3 })
            .decoration({ type: run.strike ? TextDecorationType.LineThrough : TextDecorationType.None })
        }
      }, (_run: MarkdownRun, index: number) => index.toString())
    }
    .width('100%')
    .fontSize(size)
    .lineHeight(size + 6)
    .textAlign(alignment)
    .wordBreak(WordBreak.BREAK_WORD)
  }

  @Builder
  private Code(block: MarkdownBlock) {
    Column({ space: 3 }) {
      if (block.language !== '') {
        Text(block.language)
          .fontSize(10)
          .fontColor(MUTED)
          .padding({ left: 8, top: 5 })
      }
      Scroll() {
        Text(block.code.length > 0 ? block.code : ' ')
          .width(Math.max(42, block.codeColumns * 8 + 18))
          .fontSize(11)
          .fontFamily('monospace')
          .lineHeight(16)
          .fontColor(INK)
          .padding({ left: 8, right: 8, top: 4, bottom: 6 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .backgroundColor(TINT)
    .borderRadius(7)
  }

  @Builder
  private TableRow(row: MarkdownCell[], alignments: string[], header: boolean) {
    Row() {
      ForEach(row, (cell: MarkdownCell, column: number) => {
        Column() {
          this.Rich(cell.runs, 11, header, this.alignment(alignments[column]))
        }
        .width(TABLE_CELL_WIDTH)
        .padding({ left: 6, right: 6, top: 5, bottom: 5 })
        .border({ width: { right: 1 }, color: BORDER })
      }, (_cell: MarkdownCell, index: number) => index.toString())
    }
    .width(row.length * TABLE_CELL_WIDTH)
    .alignItems(VerticalAlign.Top)
    .backgroundColor(header ? TINT : Color.Transparent)
    .border({ width: { bottom: 1 }, color: BORDER })
  }

  @Builder
  private Table(block: MarkdownBlock) {
    Scroll() {
      Column() {
        this.TableRow(block.headers, block.alignments, true)
        ForEach(block.rows, (row: MarkdownCell[]) => {
          this.TableRow(row, block.alignments, false)
        }, (_row: MarkdownCell[], index: number) => index.toString())
      }
      .width(block.headers.length * TABLE_CELL_WIDTH)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .align(Alignment.TopStart)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .border({ width: 1, color: BORDER, radius: 6 })
  }

  @Builder
  private Block(block: MarkdownBlock) {
    Column() {
      if (block.kind === 'heading') {
        if (block.anchor !== '') {
          Column() {
            this.Rich(block.runs, this.headingSize(block.level), true, TextAlign.Start)
          }
          .width('100%')
          .id(this.anchorIdPrefix + block.anchor)
        } else {
          this.Rich(block.runs, this.headingSize(block.level), true, TextAlign.Start)
        }
      } else if (block.kind === 'item') {
        Row({ space: 5 }) {
          Text(block.marker)
            .fontSize(13)
            .fontColor(MUTED)
          Column() {
            this.Rich(block.runs, 13, false, TextAlign.Start)
          }.layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ left: block.level * 9 })
      } else if (block.kind === 'code') {
        this.Code(block)
      } else if (block.kind === 'table') {
        this.Table(block)
      } else if (block.kind === 'quote') {
        Column() {
          this.Rich(block.runs, 13, false, TextAlign.Start)
        }
        .width('100%')
        .padding({ left: 7 })
        .border({ width: { left: 2 }, color: BORDER })
      } else if (block.kind === 'rule') {
        Divider().color(BORDER).margin({ top: 3, bottom: 3 })
      } else {
        this.Rich(block.runs, 13, false, TextAlign.Start)
      }
    }.width('100%')
  }

  @Builder
  private Pager() {
    Row({ space: 5 }) {
      Button('上一页', { type: ButtonType.Capsule })
        .height(27)
        .fontSize(11)
        .fontColor(BLUE)
        .backgroundColor(TINT)
        .enabled(this.page > 0)
        .onClick(() => this.changePage(this.page - 1))
      Text(`${this.page + 1} / ${this.document.pages.length}`)
        .fontSize(11)
        .fontColor(MUTED)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Button('下一页', { type: ButtonType.Capsule })
        .height(27)
        .fontSize(11)
        .fontColor(BLUE)
        .backgroundColor(TINT)
        .enabled(this.page + 1 < this.document.pages.length)
        .onClick(() => this.changePage(this.page + 1))
    }.width('100%')
  }

  build() {
    Column({ space: 7 }) {
      if (this.document.pages.length > 1) {
        this.Pager()
      }
      if (this.document.pages.length === 0 || this.document.pages[this.page].blocks.length === 0) {
        Text('暂无文字内容')
          .fontSize(13)
          .fontColor(MUTED)
      } else if (this.embedded) {
        Column({ space: 7 }) {
          ForEach(this.document.pages[this.page].blocks, (block: MarkdownBlock) => {
            this.Block(block)
          }, (_block: MarkdownBlock, index: number) => `${this.revision}-${this.page}-${index}`)
        }.width('100%')
        if (this.document.pages.length > 1) {
          this.Pager()
        }
      } else {
        List({ scroller: this.listScroller, space: 7 }) {
          ForEach(this.document.pages[this.page].blocks, (block: MarkdownBlock) => {
            ListItem() {
              this.Block(block)
            }.width('100%')
          }, (_block: MarkdownBlock, index: number) => `${this.revision}-${this.page}-${index}`)
        }
        .width('100%')
        .height(this.viewportHeight)
        .scrollBar(BarState.Auto)
      }
      if (this.document.truncated) {
        Text('内容受手表预览上限限制')
          .fontSize(11)
          .fontColor(MUTED)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
