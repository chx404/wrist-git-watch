import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../entry/src/main/ets/common/Logic.ets', import.meta.url), 'utf8');
const code = stripTypeScriptTypes(source);
const { exactRepo, urlPath, compact, sizeLabel, listQuery, asReadableMarkdown, textPages, TEXT_LIMIT } =
  await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);

test('resolves GitHub repository shorthand and GitHub page URLs', () => {
  assert.equal(exactRepo(' octocat/Hello-World '), 'octocat/Hello-World');
  assert.equal(exactRepo('https://github.com/octocat/Hello-World/tree/master?q=1'), 'octocat/Hello-World');
  assert.equal(exactRepo('https://www.github.com/octocat/Hello-World.git/'), 'octocat/Hello-World');
  assert.equal(exactRepo('https://github.com.example.net/octocat/Hello-World'), '');
  assert.equal(exactRepo('https://github.com@evil.example/a/b'), '');
  assert.equal(exactRepo('octocat/..'), '');
  assert.equal(exactRepo('octocat/.git'), '');
  assert.equal(exactRepo('keyword search'), '');
});

test('encodes URL components and formats human-readable counts', () => {
  assert.equal(urlPath('docs/a #+汉.md'), 'docs/a%20%23%2B%E6%B1%89.md');
  assert.equal(compact(999), '999');
  assert.equal(compact(1548), '1.5k');
  assert.equal(compact(1350000), '1.4m');
  assert.equal(sizeLabel(1024), '1 KB');
});

test('constructs reproducible date-based feeds', () => {
  const now = new Date('2026-11-25T19:43:00+08:00');
  assert.match(listQuery(0, false, now), /stars:>=30000/);
  assert.match(listQuery(1, false, now), /created:>=2026-11-18/);
  assert.match(listQuery(1, true, now), /created:>=2026-10-26/);
  assert.match(listQuery(2, false, now), /created:>=2026-11-18.*stars:>=1/);
});

test('converts common Markdown decorations to readable text', () => {
  const result = asReadableMarkdown('# Title\n\n<!-- comment -->\n\n- **one**\n- [two](https://github.com)\n![badge](https://img.org)');
  assert.equal(result, 'Title\n\n• one\n• two');
});

test('preserves exact text and surrogate pairs between preview pages', () => {
  const raw = `${'x'.repeat(4199)}🚀${'\n汉 hello world'.repeat(1500)}`;
  const pages = textPages(raw);
  assert.equal(pages.join(''), raw);
  assert.ok(pages.length > 1);
  assert.ok(pages.every((page) => !/[\uD800-\uDBFF]$/.test(page)));
  assert.equal(textPages('')[0], '暂无文字内容');
  assert.match(textPages('a'.repeat(TEXT_LIMIT + 1)).at(-1), /预览上限/);
});
