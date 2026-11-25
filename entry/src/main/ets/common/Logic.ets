export const PAGE_SIZE: number = 10;
export const TEXT_LIMIT: number = 96000;
const TEXT_PAGE: number = 4200;

export function exactRepo(value: string): string {
  const input = value.trim();
  // Only the canonical GitHub host; a URL is never used as a request URL.
  const url = /^https?:\/\/(?:www\.)?github\.com\/([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)(?:[/?#].*)?$/i.exec(input);
  const slug = url ?? /^([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)$/.exec(input);
  if (!slug) {
    return '';
  }
  const repo = slug[2].replace(/\.git$/i, '');
  if (slug[1].length > 39 || repo.length === 0 || repo.length > 100 || repo === '.' || repo === '..') {
    return '';
  }
  return `${slug[1]}/${repo}`;
}

export function urlPath(path: string): string {
  return path.split('/').map((part: string) => encodeURIComponent(part)).join('/');
}

export function compact(value: number): string {
  if (value >= 1000000) {
    return `${Math.round(value / 100000) / 10}m`;
  }
  return value >= 1000 ? `${Math.round(value / 100) / 10}k` : `${value}`;
}

export function sizeLabel(value: number): string {
  if (value >= 1048576) {
    return `${Math.round(value / 104857.6) / 10} MB`;
  }
  return value >= 1024 ? `${Math.round(value / 102.4) / 10} KB` : `${value} B`;
}

export function dateSince(days: number, now: Date = new Date()): string {
  return new Date(now.getTime() - days * 86400000).toISOString().slice(0, 10);
}

export function listQuery(tab: number, month: boolean, now: Date = new Date()): string {
  if (tab === 1) {
    return `created:>=${dateSince(month ? 30 : 7, now)} archived:false fork:false`;
  }
  if (tab === 2) {
    return `created:>=${dateSince(7, now)} stars:>=1 archived:false fork:false`;
  }
  return 'stars:>=30000 archived:false fork:false';
}

export function asReadableMarkdown(text: string): string {
  // Deliberately no web view, remote images, or executable HTML on the watch.
  return text.replace(/<!--[\s\S]*?-->/g, '')
    .replace(/!\[[^\]]*\]\([^\n)]*\)/g, '')
    .replace(/\[([^\]\n]+)\]\([^\n)]*\)/g, '$1')
    .replace(/<\/?(?:img|a|div|p|picture|source|br|center)\b[^>]*>/gi, '')
    .replace(/^\s*#{1,6}[ \t]+/gm, '')
    .replace(/^([ \t]*)[-*+] +/gm, '$1• ')
    .replace(/\*\*([^*\n]+)\*\*/g, '$1')
    .replace(/\n{3,}/g, '\n\n').trim();
}

export function textPages(raw: string): string[] {
  let text = raw.slice(0, TEXT_LIMIT);
  if (raw.length > TEXT_LIMIT) {
    text += '\n\n[已到手表预览上限]';
  }
  const pages: string[] = [];
  let start = 0;
  while (start < text.length) {
    let end = Math.min(start + TEXT_PAGE, text.length);
    if (end < text.length) {
      const lineEnd = text.lastIndexOf('\n', end - 1);
      if (lineEnd >= start + TEXT_PAGE / 2) {
        end = lineEnd + 1;
      } else if (text.charCodeAt(end - 1) >= 0xd800 && text.charCodeAt(end - 1) <= 0xdbff) {
        end--;
      }
    }
    pages.push(text.slice(start, end));
    start = end;
  }
  return pages.length > 0 ? pages : ['暂无文字内容'];
}
