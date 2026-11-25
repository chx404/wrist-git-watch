// A bounded GitHub-flavoured Markdown preview, not an HTML renderer. Only local
// fragments survive in the model; images, HTML and external links never fetch data.
export const MARKDOWN_SOURCE_LIMIT: number = 64000;
export const MARKDOWN_BLOCK_LIMIT: number = 384;
export const MARKDOWN_PAGE_BLOCKS: number = 8;
const PAGE_COST: number = 1900;
const LINE_LIMIT: number = 900;
const CODE_WIDTH: number = 360;
const CODE_LINES: number = 9;
const TABLE_COLUMNS: number = 12;
const TABLE_ROWS: number = 4;
const TABLE_CELL: number = 140;
const INLINE_RUNS: number = 32;
const CELL_RUNS: number = 9;
const REFERENCES_LIMIT: number = 160;
const DEPTH_LIMIT: number = 4;
const BOLD: number = 1;
const ITALIC: number = 2;
const STRIKE: number = 4;
const CODE: number = 8;
const IMAGE: number = 16;
const LINK: number = 32;
const slugPunctuation: RegExp = new RegExp('[^\\p{L}\\p{N}\\p{M}_ -]', 'gu');
const wordCharacter: RegExp = new RegExp('[\\p{L}\\p{N}\\p{M}]', 'u');

export class MarkdownRun {
  text: string;
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  image: boolean;
  link: boolean;
  anchor: string;

  constructor(text: string, style: number, anchor: string) {
    this.text = text;
    this.bold = (style & BOLD) !== 0;
    this.italic = (style & ITALIC) !== 0;
    this.strike = (style & STRIKE) !== 0;
    this.code = (style & CODE) !== 0;
    this.image = (style & IMAGE) !== 0;
    this.link = (style & LINK) !== 0;
    this.anchor = anchor;
  }
}

export class MarkdownCell {
  runs: MarkdownRun[];

  constructor(runs: MarkdownRun[]) {
    this.runs = runs;
  }
}

export class MarkdownBlock {
  kind: string;
  runs: MarkdownRun[] = [];
  level: number = 0;
  marker: string = '';
  anchor: string = '';
  language: string = '';
  code: string = '';
  codeColumns: number = 0;
  headers: MarkdownCell[] = [];
  rows: MarkdownCell[][] = [];
  alignments: string[] = [];
  cost: number = 0;

  constructor(kind: string) {
    this.kind = kind;
  }
}

export class MarkdownPage {
  blocks: MarkdownBlock[] = [];
}

export class MarkdownPosition {
  page: number;
  block: number;

  constructor(page: number, block: number) {
    this.page = page;
    this.block = block;
  }
}

export class MarkdownDocument {
  pages: MarkdownPage[] = [];
  anchors: Map<string, MarkdownPosition> = new Map<string, MarkdownPosition>();
  truncated: boolean = false;
}

// Prevent a preview boundary from cutting a UTF-16 surrogate pair.
function prefix(value: string, size: number): string {
  if (value.length <= size) {
    return value;
  }
  const last = value.charCodeAt(size - 1);
  return value.slice(0, last >= 0xD800 && last <= 0xDBFF ? size - 1 : size);
}

function clipped(value: string, size: number): string {
  return value.length <= size ? value : `${prefix(value, size - 1)}…`;
}

function char(value: string, index: number): string {
  return value.charAt(index);
}

function white(value: string): boolean {
  return value === '' || /\s/.test(value);
}

function entity(value: string): string {
  switch (value.toLowerCase()) {
    case '&amp;': return '&';
    case '&lt;': return '<';
    case '&gt;': return '>';
    case '&quot;': return '"';
    case '&apos;': return "'";
    case '&nbsp;': return '\u00A0';
    default:
      if (value.charAt(1) !== '#') {
        return value;
      }
      const hex = value.charAt(2).toLowerCase() === 'x';
      const point = parseInt(value.slice(hex ? 3 : 2, -1), hex ? 16 : 10);
      return point > 0 && point <= 0x10FFFF && !(point >= 0xD800 && point <= 0xDFFF)
        ? String.fromCodePoint(point) : '\uFFFD';
  }
}

function decodeEntities(value: string): string {
  return value.replace(/&(?:#[0-9]{1,8}|#x[0-9a-f]{1,8}|amp|lt|gt|quot|apos|nbsp);/gi,
    (match: string) => entity(match));
}

function fragment(value: string): string {
  if (!value.startsWith('#') || value.length < 2 || value.length > 1000) {
    return '';
  }
  try {
    const decoded = decodeURIComponent(value.slice(1));
    return /[\u0000-\u001F\u007F]/.test(decoded) ? '' : decoded;
  } catch (_) {
    return '';
  }
}

function labelKey(value: string): string {
  return value.trim().replace(/\s+/g, ' ').toLowerCase();
}

class Destination {
  url: string;
  end: number;

  constructor(url: string, end: number) {
    this.url = url;
    this.end = end;
  }
}

// A destination may contain balanced parentheses, angle brackets or an optional
// title. We parse it to find the closing delimiter, but keep only local fragments.
function destination(text: string, start: number, inline: boolean): Destination | undefined {
  let at = start;
  while (white(char(text, at)) && at < text.length) {
    at++;
  }
  const angled = char(text, at) === '<';
  if (angled) {
    at++;
  }
  const urlStart = at;
  let depth = 0;
  while (at < text.length) {
    const c = char(text, at);
    if (c === '\\' && at + 1 < text.length) {
      at += 2;
      continue;
    }
    if (angled) {
      if (c === '>') {
        break;
      }
      if (c === '\n' || c === '<') {
        return undefined;
      }
    } else if (white(c)) {
      break;
    } else if (c === '(') {
      if (++depth > 8) {
        return undefined;
      }
    } else if (c === ')') {
      if (depth === 0) {
        break;
      }
      depth--;
    }
    at++;
  }
  if ((angled && char(text, at) !== '>') || depth !== 0) {
    return undefined;
  }
  const url = decodeEntities(text.slice(urlStart, at).replace(/\\([!-/:-@\[-`{-~])/g, '$1'));
  if (angled) {
    at++;
  }
  const afterUrl = at;
  while (white(char(text, at)) && at < text.length) {
    at++;
  }
  const quote = char(text, at);
  if (at > afterUrl && (quote === '"' || quote === "'" || quote === '(')) {
    const close = quote === '(' ? ')' : quote;
    at++;
    while (at < text.length && char(text, at) !== close) {
      at += char(text, at) === '\\' ? 2 : 1;
    }
    if (char(text, at) !== close) {
      return undefined;
    }
    at++;
    while (white(char(text, at)) && at < text.length) {
      at++;
    }
  }
  if (inline ? char(text, at) !== ')' : at !== text.length) {
    return undefined;
  }
  return new Destination(url, inline ? at + 1 : at);
}

function markerLength(text: string, start: number, marker: string): number {
  let stop = start + 1;
  while (char(text, stop) === marker) {
    stop++;
  }
  return stop - start;
}

function codeEnd(text: string, at: number, width: number): number {
  let end = text.indexOf('`', at);
  while (end >= 0) {
    const size = markerLength(text, end, '`');
    if (size === width) {
      return end;
    }
    end = text.indexOf('`', end + size);
  }
  return -1;
}

function bracketEnd(text: string, from: number): number {
  let nested = 0;
  for (let at = from; at < text.length; at++) {
    const c = char(text, at);
    if (c === '\\') {
      at++;
    } else if (c === '`') {
      const size = markerLength(text, at, c);
      const end = codeEnd(text, at + size, size);
      at = end >= 0 ? end + size - 1 : at + size - 1;
    } else if (c === '[') {
      nested++;
    } else if (c === ']') {
      if (nested === 0) {
        return at;
      }
      nested--;
    }
  }
  return -1;
}

function emphasisEnd(text: string, start: number, marker: string, size: number): number {
  for (let at = start; at < text.length; at++) {
    const c = char(text, at);
    if (c === '\\') {
      at++;
      continue;
    }
    if (c === '`') {
      const width = markerLength(text, at, c);
      const codeClose = codeEnd(text, at + width, width);
      at = codeClose >= 0 ? codeClose + width - 1 : at + width - 1;
      continue;
    }
    if (c !== marker) {
      continue;
    }
    const width = markerLength(text, at, marker);
    if (!white(char(text, at - 1)) && !(marker === '_' && wordCharacter.test(char(text, at + width)))) {
      if (width === size) {
        return at;
      }
      if (width === 3 && size === 2) {
        return at + 1;
      }
    }
    at += width - 1;
  }
  return -1;
}

class InlineWriter {
  runs: MarkdownRun[] = [];
  limit: number;
  previousStyle: number = -1;

  constructor(limit: number) {
    this.limit = limit;
  }

  add(text: string, style: number, anchor: string): void {
    if (text.length === 0) {
      return;
    }
    const last = this.runs[this.runs.length - 1];
    if (this.runs.length > 0 && this.previousStyle === style && last.anchor === anchor) {
      last.text += text;
      return;
    }
    // Dense markup falls back to plain text, never extending a link hit target.
    if (this.runs.length >= this.limit) {
      this.runs[this.limit - 1] = new MarkdownRun(last.text + text, 0, '');
      this.previousStyle = 0;
      return;
    }
    this.runs.push(new MarkdownRun(text, style, anchor));
    this.previousStyle = style;
  }
}

function inlineInto(text: string, references: Map<string, string>, writer: InlineWriter, style: number,
  anchor: string, depth: number): void {
  if (depth >= DEPTH_LIMIT) {
    writer.add(decodeEntities(text), style, anchor);
    return;
  }
  let plain = '';
  for (let at = 0; at < text.length;) {
    if (writer.runs.length >= writer.limit - 2) {
      writer.add(plain + decodeEntities(text.slice(at)), 0, '');
      return;
    }
    const c = char(text, at);
    const next = char(text, at + 1);
    if (c === '\\' && /[!-/:-@\[-`{-~]/.test(next)) {
      plain += next;
      at += 2;
      continue;
    }
    if (c === '`') {
      const width = markerLength(text, at, c);
      const end = codeEnd(text, at + width, width);
      if (end >= 0) {
        writer.add(plain, style, anchor);
        plain = '';
        let code = text.slice(at + width, end).replace(/\n/g, ' ');
        if (code.startsWith(' ') && code.endsWith(' ') && code.trim().length > 0) {
          code = code.slice(1, -1);
        }
        writer.add(code, style | CODE, anchor);
        at = end + width;
        continue;
      }
      plain += text.slice(at, at + width);
      at += width;
      continue;
    }
    const image = c === '!' && next === '[';
    if (c === '[' || image) {
      const from = at + (image ? 2 : 1);
      const end = bracketEnd(text, from);
      if (end >= 0) {
        const label = text.slice(from, end);
        let after = end + 1;
        let url: string | undefined;
        if (char(text, after) === '(') {
          const target = destination(text, after + 1, true);
          if (target !== undefined) {
            url = target.url;
            after = target.end;
          }
        } else if (char(text, after) === '[') {
          const refEnd = bracketEnd(text, after + 1);
          if (refEnd >= 0) {
            url = references.get(labelKey(text.slice(after + 1, refEnd) || label));
            after = refEnd + 1;
          }
        } else {
          url = references.get(labelKey(label));
        }
        if (url !== undefined) {
          writer.add(plain, style, anchor);
          plain = '';
          if (image) {
            writer.add(label.length > 0 ? `［图片：${decodeEntities(label)}］` : '［图片］', style | IMAGE, anchor);
          } else {
            inlineInto(label, references, writer, style | LINK, anchor || fragment(url), depth + 1);
          }
          at = after;
          continue;
        }
      }
    }
    if (c === '*' || c === '_' || c === '~') {
      const width = markerLength(text, at, c);
      const canOpen = c === '~' ? width === 2 : width <= 3;
      if (canOpen && !white(char(text, at + width)) &&
        !(c === '_' && wordCharacter.test(char(text, at - 1)))) {
        const end = emphasisEnd(text, at + width, c, width);
        if (end > at + width) {
          const flags = c === '~' ? STRIKE : (width === 3 ? BOLD | ITALIC : (width === 2 ? BOLD : ITALIC));
          writer.add(plain, style, anchor);
          plain = '';
          inlineInto(text.slice(at + width, end), references, writer, style | flags, anchor, depth + 1);
          at = end + width;
          continue;
        }
      }
      plain += text.slice(at, at + width);
      at += width;
      continue;
    }
    if (c === '<') {
      if (text.startsWith('<!--', at)) {
        const end = text.indexOf('-->', at + 4);
        if (end >= 0) {
          at = end + 3;
          continue;
        }
      }
      const token = /^<(https?:\/\/[^<>\s]+|[^<>\s@]+@[^<>\s@]+)>/i.exec(text.slice(at));
      if (token !== null) {
        writer.add(plain, style, anchor);
        plain = '';
        writer.add(decodeEntities(token[1]), style | LINK, anchor);
        at += token[0].length;
        continue;
      }
      // Common README wrapper tags are inert. Other HTML remains literal text.
      const html = /^<(\/?(?:img|a|div|p|picture|source|br|center|details|summary))\b(?:"[^"]*"|'[^']*'|[^'"<>])*>/i.exec(text.slice(at));
      if (html !== null) {
        const tag = html[1].toLowerCase();
        if (tag === 'br' || tag === '/br') {
          plain += '\n';
        } else if (tag === 'img') {
          const alt = /\salt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(html[0]);
          const label = alt !== null ? alt[1] ?? alt[2] ?? alt[3] ?? '' : '';
          writer.add(plain, style, anchor);
          plain = '';
          writer.add(label.length > 0 ? `［图片：${decodeEntities(label)}］` : '［图片］', style | IMAGE, anchor);
        }
        at += html[0].length;
        continue;
      }
    }
    if (c === '&') {
      const escaped = /^&(?:#[0-9]{1,8}|#x[0-9a-f]{1,8}|amp|lt|gt|quot|apos|nbsp);/i.exec(text.slice(at, at + 13));
      if (escaped !== null) {
        plain += entity(escaped[0]);
        at += escaped[0].length;
        continue;
      }
    }
    plain += c;
    at++;
  }
  writer.add(plain, style, anchor);
}

function parseInline(text: string, references: Map<string, string>, limit: number = INLINE_RUNS): MarkdownRun[] {
  const writer = new InlineWriter(limit);
  inlineInto(text, references, writer, 0, '', 0);
  return writer.runs;
}

function runCost(runs: MarkdownRun[]): number {
  let size = 0;
  for (const run of runs) {
    size += run.text.length + 12;
  }
  return size;
}

function prose(kind: string, text: string, references: Map<string, string>): MarkdownBlock {
  const block = new MarkdownBlock(kind);
  block.runs = parseInline(text, references);
  block.cost = runCost(block.runs);
  return block;
}

function headingSlug(runs: MarkdownRun[]): string {
  let label = '';
  for (const run of runs) {
    if (!run.image) {
      label += run.text;
    }
  }
  return label.trim().toLowerCase().replace(slugPunctuation, '').replace(/ /g, '-');
}

function heading(text: string, level: number, used: Set<string>, suffixes: Map<string, number>,
  references: Map<string, string>): MarkdownBlock {
  const block = prose('heading', text, references);
  block.level = level;
  const slug = headingSlug(block.runs);
  let candidate = slug;
  if (candidate !== '' && used.has(candidate)) {
    let suffix = suffixes.get(slug) ?? 1;
    do {
      candidate = `${slug}-${suffix++}`;
    } while (used.has(candidate));
    suffixes.set(slug, suffix);
  }
  if (candidate !== '') {
    used.add(candidate);
  }
  block.anchor = candidate;
  return block;
}

function atx(line: string): RegExpExecArray | null {
  return /^ {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*)$/.exec(line);
}

function setext(line: string): boolean {
  return /^ {0,3}(?:=+|-+)[ \t]*$/.test(line);
}

function rule(line: string): boolean {
  return /^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/.test(line);
}

function bullet(line: string): RegExpExecArray | null {
  return /^([ \t]*)([-+*]|[0-9]{1,9}[.)])(?:[ \t]+(.*)|[ \t]*)$/.exec(line);
}

function quote(line: string): boolean {
  return /^ {0,3}>/.test(line);
}

function indented(line: string): boolean {
  return /^(?: {4}| {0,3}\t)/.test(line);
}

function fence(line: string): RegExpExecArray | null {
  const match = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
  if (match !== null && match[2].startsWith('`') && match[3].includes('`')) {
    return null;
  }
  return match;
}

function closeFence(line: string, mark: string): boolean {
  const match = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line);
  return match !== null && char(match[1], 0) === char(mark, 0) && match[1].length >= mark.length;
}

function prepareLines(lines: string[]): Map<string, string> {
  const references = new Map<string, string>();
  let mark = '';
  let comment = false;
  for (let index = 0; index < lines.length; index++) {
    let line = lines[index];
    if (mark !== '') {
      if (closeFence(line, mark)) {
        mark = '';
      }
      continue;
    }
    if (comment || /^ {0,3}<!--/.test(line)) {
      const skip = comment ? 0 : line.indexOf('<!--') + 4;
      const close = line.indexOf('-->', skip);
      comment = close < 0;
      line = comment ? '' : line.slice(close + 3);
      lines[index] = line;
    }
    const opener = fence(line);
    if (opener !== null) {
      mark = opener[2];
      continue;
    }
    const definition = /^ {0,3}\[([^\]\n]{1,160})\]:[ \t]*(.+)$/.exec(line);
    if (definition !== null) {
      const target = destination(clipped(definition[2], LINE_LIMIT), 0, false);
      if (target !== undefined && target.url !== '') {
        const key = labelKey(definition[1]);
        if (!references.has(key) && references.size < REFERENCES_LIMIT) {
          references.set(key, target.url);
        }
        lines[index] = '';
      }
    }
  }
  return references;
}

function splitCells(line: string): string[] {
  if (!line.includes('|') || line.length > LINE_LIMIT) {
    return [];
  }
  const input = line.trim();
  const cells: string[] = [];
  let cell = '';
  let boundary = false;
  for (let at = 0; at < input.length; at++) {
    const c = char(input, at);
    if (c === '\\' && at + 1 < input.length) {
      const next = char(input, at + 1);
      cell += next === '|' ? '|' : c + next;
      at++;
    } else if (c === '`') {
      const width = markerLength(input, at, c);
      const end = codeEnd(input, at + width, width);
      const stop = end < 0 ? at + width : end + width;
      cell += input.slice(at, stop).replace(/\\\|/g, '|');
      at = stop - 1;
    } else if (c === '|') {
      boundary = true;
      if (at > 0) {
        cells.push(cell.trim());
        if (cells.length > TABLE_COLUMNS) {
          return [];
        }
      }
      cell = '';
    } else {
      cell += c;
    }
  }
  if (cell.length > 0 || !input.endsWith('|')) {
    cells.push(cell.trim());
  }
  return boundary && cells.length <= TABLE_COLUMNS ? cells : [];
}

function tableAlignment(separator: string): string[] {
  const cells = splitCells(separator);
  if (cells.length === 0 || !cells.every((cell: string) => /^:?-+:?$/.test(cell))) {
    return [];
  }
  return cells.map((cell: string) => cell.endsWith(':') ? (cell.startsWith(':') ? 'center' : 'right') : 'left');
}

function tableAt(lines: string[], at: number): boolean {
  return at + 1 < lines.length && lines[at + 1].includes('|') &&
    tableAlignment(lines[at + 1]).length > 0 && splitCells(lines[at]).length > 0;
}

function tableRow(cells: string[], columns: number, references: Map<string, string>): MarkdownCell[] {
  const row: MarkdownCell[] = [];
  for (let column = 0; column < columns; column++) {
    row.push(new MarkdownCell(parseInline(clipped(cells[column] ?? '', TABLE_CELL), references, CELL_RUNS)));
  }
  return row;
}

function rowCost(row: MarkdownCell[]): number {
  let cost = 0;
  for (const cell of row) {
    cost += runCost(cell.runs) + 20;
  }
  return cost;
}

function codeColumns(value: string): number {
  let columns = 0;
  for (let index = 0; index < value.length; index++) {
    const point = value.charCodeAt(index);
    if (point === 9) {
      columns += 8 - (columns % 8);
    } else if (point < 0xDC00 || point > 0xDFFF) {
      columns += point >= 0x1100 ? 2 : 1;
    }
  }
  return columns;
}

function bodyLead(line: string): boolean {
  return atx(line) !== null || fence(line) !== null || rule(line) || bullet(line) !== null ||
    quote(line);
}

function appendCode(batch: string[], language: string, blocks: MarkdownBlock[]): void {
  const block = new MarkdownBlock('code');
  block.language = language;
  block.code = batch.join('\n');
  for (const line of batch) {
    block.codeColumns = Math.max(block.codeColumns, codeColumns(line));
  }
  block.cost = block.code.length + batch.length * 40;
  blocks.push(block);
}

function paginate(blocks: MarkdownBlock[], document: MarkdownDocument): void {
  let page = new MarkdownPage();
  let cost = 0;
  for (const block of blocks) {
    if (page.blocks.length >= MARKDOWN_PAGE_BLOCKS || (page.blocks.length > 0 && cost + block.cost > PAGE_COST)) {
      document.pages.push(page);
      page = new MarkdownPage();
      cost = 0;
    }
    if (block.anchor !== '') {
      document.anchors.set(block.anchor, new MarkdownPosition(document.pages.length, page.blocks.length));
    }
    page.blocks.push(block);
    cost += block.cost;
  }
  document.pages.push(page);
}

export function parseMarkdown(source: string): MarkdownDocument {
  const document = new MarkdownDocument();
  document.truncated = source.length > MARKDOWN_SOURCE_LIMIT;
  const lines = prefix(source, MARKDOWN_SOURCE_LIMIT).replace(/\r\n?/g, '\n').split('\n');
  const references = prepareLines(lines);
  const used = new Set<string>();
  const suffixes = new Map<string, number>();
  const blocks: MarkdownBlock[] = [];
  let index = 0;
  let listContext = false;
  while (index < lines.length && blocks.length < MARKDOWN_BLOCK_LIMIT) {
    const line = lines[index];
    if (line.trim() === '') {
      index++;
      continue;
    }
    const opener = fence(line);
    const item = bullet(clipped(line, LINE_LIMIT));
    const wasList = listContext;
    listContext = false;
    if (opener !== null || (indented(line) && !(wasList && item !== null))) {
      const mark = opener !== null ? opener[2] : '';
      const language = opener !== null ? clipped(opener[3].trim().split(/\s+/)[0], 28) : '';
      if (opener !== null) {
        index++;
      }
      let batch: string[] = [];
      let size = 0;
      let emitted = false;
      while (index < lines.length && blocks.length < MARKDOWN_BLOCK_LIMIT) {
        const raw = lines[index];
        if (opener !== null && closeFence(raw, mark)) {
          index++;
          break;
        }
        if (opener === null && !indented(raw) &&
          !(raw.trim() === '' && index + 1 < lines.length && indented(lines[index + 1]))) {
          break;
        }
        let indent = 0;
        if (opener !== null) {
          while (indent < opener[1].length && char(raw, indent) === ' ') {
            indent++;
          }
        }
        const content = opener !== null ? raw.slice(indent) : raw.replace(/^(?: {4}| {0,3}\t)/, '');
        const code = clipped(content, CODE_WIDTH);
        if (batch.length >= CODE_LINES || (batch.length > 0 && size + code.length > 1300)) {
          appendCode(batch, language, blocks);
          emitted = true;
          batch = [];
          size = 0;
          if (blocks.length >= MARKDOWN_BLOCK_LIMIT) {
            break;
          }
        }
        if (code !== content) {
          document.truncated = true;
        }
        batch.push(code);
        size += code.length;
        index++;
      }
      if (blocks.length < MARKDOWN_BLOCK_LIMIT && (batch.length > 0 || !emitted)) {
        appendCode(batch, language, blocks);
      }
      continue;
    }
    if (line.length > LINE_LIMIT) {
      document.truncated = true;
    }
    const title = atx(clipped(line, LINE_LIMIT));
    if (title !== null) {
      const label = (title[2] ?? '').replace(/(?:^|[ \t]+)#+[ \t]*$/, '').trim();
      blocks.push(heading(label, title[1].length, used, suffixes, references));
      index++;
      continue;
    }
    const alignments = index + 1 < lines.length ? tableAlignment(lines[index + 1]) : [];
    if (alignments.length > 0) {
      const header = splitCells(line);
      if (header.length === alignments.length) {
        const headers = tableRow(header, alignments.length, references);
        index += 2;
        let block = new MarkdownBlock('table');
        block.headers = headers;
        block.alignments = alignments;
        block.cost = rowCost(headers);
        while (index < lines.length && blocks.length < MARKDOWN_BLOCK_LIMIT) {
          const cells = splitCells(lines[index]);
          if (cells.length === 0 || bodyLead(lines[index])) {
            break;
          }
          const row = tableRow(cells, alignments.length, references);
          const cost = rowCost(row);
          if (block.rows.length >= TABLE_ROWS || (block.rows.length > 0 && block.cost + cost > PAGE_COST)) {
            blocks.push(block);
            if (blocks.length >= MARKDOWN_BLOCK_LIMIT) {
              break;
            }
            block = new MarkdownBlock('table');
            block.headers = headers;
            block.alignments = alignments;
            block.cost = rowCost(headers);
          }
          block.rows.push(row);
          block.cost += cost;
          index++;
        }
        if (blocks.length < MARKDOWN_BLOCK_LIMIT) {
          blocks.push(block);
        }
        continue;
      }
    }
    if (rule(line)) {
      blocks.push(new MarkdownBlock('rule'));
      index++;
      continue;
    }
    if (item !== null) {
      listContext = true;
      const content = item[3] ?? '';
      const task = /^\[([ xX])\](?:[ \t]+|$)/.exec(content);
      const block = prose('item', task !== null ? content.slice(task[0].length) : content, references);
      block.marker = item[2].length === 1 ? '•' : item[2];
      if (task !== null) {
        block.marker = task[1] === ' ' ? '☐' : '☑';
      }
      block.level = Math.min(4, Math.floor(item[1].replace(/\t/g, '    ').length / 2));
      blocks.push(block);
      index++;
      continue;
    }
    if (quote(line)) {
      blocks.push(prose('quote', clipped(line.replace(/^ {0,3}>[ \t]?/, ''), LINE_LIMIT), references));
      index++;
      continue;
    }
    let text = '';
    let joiner = '';
    let level = 0;
    while (index < lines.length) {
      const next = lines[index];
      if (text !== '' && setext(next)) {
        level = next.trimStart().startsWith('=') ? 1 : 2;
        index++;
        break;
      }
      if (text !== '' && (next.trim() === '' || bodyLead(next) || tableAt(lines, index))) {
        break;
      }
      const hard = /(?: {2,}|\\)$/.test(next) && !next.endsWith('\\\\');
      const trimmed = next.trim();
      const segment = clipped(hard && trimmed.endsWith('\\') ? trimmed.slice(0, -1) : trimmed, LINE_LIMIT);
      if (text !== '' && text.length + joiner.length + segment.length > LINE_LIMIT) {
        break;
      }
      if (trimmed.length > LINE_LIMIT) {
        document.truncated = true;
      }
      text += joiner + segment;
      joiner = hard ? '\n' : ' ';
      index++;
    }
    blocks.push(level > 0 ? heading(text, level, used, suffixes, references) : prose('paragraph', text, references));
  }
  document.truncated = document.truncated || index < lines.length;
  paginate(blocks, document);
  return document;
}
