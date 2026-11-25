import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../entry/src/main/ets/common/Markdown.ets', import.meta.url), 'utf8');
const moduleUrl = `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`;
const {
  parseMarkdown, resolveMarkdownImage, MARKDOWN_SOURCE_LIMIT, MARKDOWN_BLOCK_LIMIT, MARKDOWN_PAGE_BLOCKS,
  MARKDOWN_IMAGE_LIMIT,
} = await import(moduleUrl);
const blocks = (doc) => doc.pages.flatMap((page) => page.blocks);
const text = (node) => node.runs.map((run) => run.text).join('');

function expectAnchor(doc, slug, label) {
  const position = doc.anchors.get(slug);
  assert.ok(position, `Missing heading slug ${slug}`);
  const block = doc.pages[position.page].blocks[position.block];
  assert.equal(block.kind, 'heading');
  assert.equal(text(block), label);
  return position;
}

test('keeps heading levels, setext titles and unique GitHub-like multilingual anchors', () => {
  const doc = parseMarkdown([
    '# Install **Now**! ###', '', '### Install Now-1', '## Install Now', '', '安装 指南', '=======', '',
    '[Go](#install-now-2) and [中文](#%E5%AE%89%E8%A3%85-%E6%8C%87%E5%8D%97)',
  ].join('\n'));
  assert.deepEqual(blocks(doc).filter((block) => block.kind === 'heading').map((block) => block.level), [1, 3, 2, 1]);
  expectAnchor(doc, 'install-now', 'Install Now!');
  expectAnchor(doc, 'install-now-1', 'Install Now-1');
  expectAnchor(doc, 'install-now-2', 'Install Now');
  expectAnchor(doc, '安装-指南', '安装 指南');
  assert.deepEqual(blocks(doc).at(-1).runs.filter((run) => run.link).map((run) => run.anchor), ['install-now-2', '安装-指南']);
});

test('preserves inline emphasis, nested styling, code, escapes and hard breaks', () => {
  const [paragraph] = blocks(parseMarkdown('**bold *also italic***, _italic_, ***both***, ~~old~~ and `` `x` ``.  \nEscaped \\*stars\\*, path_name_here &amp; &#x1F680;.'));
  assert.equal(text(paragraph), 'bold also italic, italic, both, old and `x`.\nEscaped *stars*, path_name_here & 🚀.');
  const byText = Object.fromEntries(paragraph.runs.map((run) => [run.text, run]));
  assert.equal(byText['bold '].bold, true);
  assert.equal(byText['also italic'].bold, true);
  assert.equal(byText['also italic'].italic, true);
  assert.equal(byText.italic.italic, true);
  assert.equal(byText.both.bold, true);
  assert.equal(byText.both.italic, true);
  assert.equal(byText.old.strike, true);
  assert.equal(byText['`x`'].code, true);
});

test('supports ordinary, ordered, nested and task list markers, blockquotes and rules', () => {
  const doc = parseMarkdown('- Parent\n    + Nested\n    - [x] Completed\n    - [ ] Todo\n12) Ordered\n\n> **Quote**\n\n---');
  const nodes = blocks(doc);
  assert.deepEqual(nodes.map((node) => node.kind), ['item', 'item', 'item', 'item', 'item', 'quote', 'rule']);
  assert.deepEqual(nodes.slice(0, 5).map((node) => node.marker), ['•', '•', '☑', '☐', '12)']);
  assert.ok(nodes[1].level > nodes[0].level);
  assert.equal(nodes[5].runs[0].bold, true);
});

test('preserves fenced and indented code, even when the contents resemble Markdown or HTML', () => {
  const doc = parseMarkdown('    - literal marker\n\n   ~~~~typescript\n   const x = "**literal**";  \n   \t<!-- keep me -->\n~~~\n   ~~~~\n```sh\necho hi');
  const nodes = blocks(doc);
  assert.deepEqual(nodes.map((node) => node.kind), ['code', 'code', 'code']);
  assert.equal(nodes[0].code, '- literal marker');
  assert.equal(nodes[1].language, 'typescript');
  assert.equal(nodes[1].code, 'const x = "**literal**";  \n\t<!-- keep me -->\n~~~');
  assert.equal(nodes[2].code, 'echo hi');
});

test('keeps visible inline and reference labels but only activates local fragments', () => {
  const doc = parseMarkdown([
    '[Start](<#intro> "Jump") / [**website**](https://example.test/path_(part)) / [Read][See Me]',
    '[Blocked](javascript:alert(1)) / [Unsafe scheme](//example.test/secret) / [Bad fragment](#%zz)',
    '[Link with [brackets]](#intro) / [Escaped](#intro "with a title")', '',
    '[See Me]: #intro "Jump here"', '', '## Intro',
  ].join('\n'));
  const [p] = blocks(doc);
  const links = p.runs.filter((run) => run.link);
  assert.deepEqual(links.map((run) => [run.text, run.anchor]), [
    ['Start', 'intro'], ['website', ''], ['Read', 'intro'], ['Blocked', ''], ['Unsafe scheme', ''],
    ['Bad fragment', ''], ['Link with [brackets]', 'intro'], ['Escaped', 'intro'],
  ]);
  assert.equal(links[1].bold, true);
  assert.equal(blocks(doc).length, 2);
  assert.doesNotMatch(text(p), /javascript|example\.test|%zz/);
});

test('without README context the render model keeps just the image fallback', () => {
  const doc = parseMarkdown([
    '<!-- This comment', 'is not rendered -->', '<picture>',
    '<source srcset="https://private.example/track">',
    '<img src="https://private.example/hash" alt="Build &amp; test">',
    '</picture>', '', '[![CI][ci-badge]](https://private.example/project)', '',
    '![Logo](data:image/png;base64,deadbeef) and ![](https://avatars.githubusercontent.com/u/1)', '',
    '[ci-badge]: https://raw.githubusercontent.com/a/b/main/status.svg',
  ].join('\n'));
  const rendered = blocks(doc).flatMap((node) => node.runs).filter((run) => run.image);
  assert.deepEqual(rendered.map((run) => run.text), ['［图片：Build & test］', '［图片：CI］', '［图片：Logo］', '［图片］']);
  assert.ok(rendered.every((run) => run.anchor === '' && run.imageUrl === ''));
  assert.doesNotMatch(blocks(doc).map(text).join('\n'), /private\.example|raw\.githubusercontent|deadbeef|This comment/);
});

test('README Markdown, reference and HTML images produce separate native image targets in source order', () => {
  const doc = parseMarkdown([
    'Before ![Shot](<./docs/Watch preview.png> "Title")![Icon](/assets/icon.svg) after', '',
    '[![Build][build]](#details) <IMG width="9000" src="https://Avatars.githubusercontent.com/u/1?s=32&amp;v=4" alt="Avatar">', '',
    '<picture><source srcset="./never-loaded.png"><img data-x="other src=./fake.png" alt="Build &amp; test" src=./real.png></picture>', '',
    '[build]: https://github.com/Owner/Repo/blob/main/status.svg?raw=true',
    '## Details',
  ].join('\n'), 'Owner/Repo', 'feature/preview');
  const runs = blocks(doc).flatMap((node) => node.runs);
  const images = runs.filter((run) => run.image);
  assert.deepEqual(images.map(({ text, imageUrl }) => [text, imageUrl]), [
    ['［图片：Shot］', 'https://raw.githubusercontent.com/Owner/Repo/feature/preview/docs/Watch%20preview.png'],
    ['［图片：Icon］', 'https://raw.githubusercontent.com/Owner/Repo/feature/preview/assets/icon.svg'],
    ['［图片：Build］', 'https://raw.githubusercontent.com/Owner/Repo/main/status.svg'],
    ['［图片：Avatar］', 'https://avatars.githubusercontent.com/u/1?s=32&v=4'],
    ['［图片：Build & test］', 'https://raw.githubusercontent.com/Owner/Repo/feature/preview/real.png'],
  ]);
  assert.equal(images[2].anchor, 'details');
  assert.equal(runs[0].text, 'Before ');
  assert.equal(runs[3].text, ' after');
});

test('image URL resolution accepts known GitHub image routes and normalizes safe repository paths', () => {
  const attachment = 'https://github.com/user-attachments/assets/c7ca57d1-feb3-44e6-a36c-d2c037ab4754';
  const legacyAttachment = 'https://github.com/a/b/assets/123/c7ca57d1-feb3-44e6-a36c-d2c037ab4754';
  const workflow = 'https://github.com/a/b/actions/workflows/ci.yml/badge.svg?branch=release%2Fwatch&event=push';
  const media = 'https://media.githubusercontent.com/media/a/b/refs/heads/main/art.png';
  const upload = 'https://user-images.githubusercontent.com/1234/abc-456.gif';
  for (const url of [attachment, legacyAttachment, workflow, media, upload]) {
    assert.equal(resolveMarkdownImage(url), url);
  }
  assert.equal(resolveMarkdownImage('https://RAW.GITHUBusercontent.com/a/b/main/pic.PNG#gh-dark-mode-only'),
    'https://raw.githubusercontent.com/a/b/main/pic.PNG');
  assert.equal(resolveMarkdownImage('./docs/sub/../图.png?raw=1', 'a/b', 'v1.2.0'),
    'https://raw.githubusercontent.com/a/b/v1.2.0/docs/%E5%9B%BE.png');
  assert.equal(resolveMarkdownImage('/images/test%20one.png', 'a/b', 'HEAD'),
    'https://raw.githubusercontent.com/a/b/HEAD/images/test%20one.png');
});

test('image URL policy fails closed on third parties, unsafe authorities, routes, and traversal', () => {
  const blocked = [
    '//raw.githubusercontent.com/a/b/main/image.png', 'http://raw.githubusercontent.com/a/b/main/image.png',
    'https://localhost/logo.png', 'https://10.1.2.3/logo.png', 'https://[::1]/logo.png', 'https://0x7f000001/logo.png',
    'https://raw.githubusercontent.com.evil.test/a/b/main/image.png', 'https://raw.githubusercontent.com./a/b/main/image.png',
    'https://raw.githubusercontent.com@evil.test/a/b/main/image.png', 'https://user:secret@raw.githubusercontent.com/a/b/main/image.png',
    'https://raw.githubusercontent.com:443/a/b/main/image.png', 'https://raw.githubusercontent.com\\@evil.test/a/b/main/image.png',
    'https://raw.githubusercontent.com/a/b/main/image.png?token=untrusted',
    'https://github.com/login?return_to=https://localhost/logo.png', 'https://github.com/a/b/issues/1.png',
    'https://github.com/a/b/blob/main/x%2F..%2Fp.png', 'https://raw.githubusercontent.com/a/b/main/%2e%2e/p.png',
    'https://camo.githubusercontent.com/123/456.png', 'https://images.example.test/tracker.png',
    'https://img.shields.io/badge/status-ok-green.svg', 'https://a.github.io/image.png',
    'file:///logo.png', 'data:image/png;base64,abc', 'javascript:logo.png', '#logo.png',
    '../other/logo.png', './sub/../../logo.png', '%2e%2e/logo.png', 'dir/%252e%252e/logo.png',
    'dir/logo%5Cother.png', 'dir/logo%0Aother.png', 'dir/logo%zz.png', 'dir//logo.png', 'README.md', 'logo.png?url=x',
    `${'a'.repeat(1024)}.png`,
  ];
  for (const url of blocked) {
    assert.equal(resolveMarkdownImage(url, 'owner/repo', 'main'), '', url);
  }
  assert.equal(resolveMarkdownImage('logo.png', 'malformed/repo/name', 'main'), '');
  assert.equal(resolveMarkdownImage('logo.png', 'owner/..', 'main'), '');
  assert.equal(resolveMarkdownImage('logo.png', 'owner/repo', '../main'), '');
  assert.equal(resolveMarkdownImage('logo.png', 'owner/repo', 'main?next=evil'), '');
  assert.equal(resolveMarkdownImage('logo.png'), '');
  const doc = parseMarkdown([
    '<img alt="Safe fallback" data-example=" src=./fake.png" srcset="./ignored.png">',
    '![blocked](https://img.shields.io/tracker.svg)',
  ].join('\n'), 'a/b', 'main');
  assert.deepEqual(blocks(doc)[0].runs.filter((run) => run.image).map((run) => [run.text, run.imageUrl]), [
    ['［图片：Safe fallback］', ''], ['［图片：blocked］', ''],
  ]);
});

test('one image budget applies across all pages, including repeated table headers', () => {
  const table = ['| ![Header](badge.png) |', '| --- |', ...Array(50).fill('| row |')].join('\n');
  const doc = parseMarkdown(`![Blocked](https://localhost/logo.png)\n\n${table}\n\n![Last](last.png)`, 'a/b', 'main');
  const runs = blocks(doc).flatMap((block) => [
    ...block.runs, ...block.headers.flatMap((cell) => cell.runs),
  ]);
  assert.equal(runs.filter((run) => run.imageUrl !== '').length, MARKDOWN_IMAGE_LIMIT);
  assert.ok(runs.some((run) => run.text === '［图片：Header］' && run.imageUrl === ''));
  assert.equal(runs.at(-1).imageUrl, '');
});

test('tables preserve alignment, escaped pipes, styled cell labels and repeated headers across chunks', () => {
  const doc = parseMarkdown([
    '| **Name** | Value | State |', '| :--- | ---: | :---: |',
    '| A\\|B | `x\\|y` | [go](#done) |', '| 2 | nine | complete |', '| 3 |',
    '| 4 | nine | done |', '| 5 | nine | complete |', '', '# Done',
  ].join('\n'));
  const sheets = blocks(doc).filter((node) => node.kind === 'table');
  assert.equal(sheets.length, 2);
  assert.deepEqual(sheets.map((sheet) => sheet.headers.map(text)), [['Name', 'Value', 'State'], ['Name', 'Value', 'State']]);
  assert.deepEqual(sheets[0].alignments, ['left', 'right', 'center']);
  assert.deepEqual(sheets[0].rows[0].map(text), ['A|B', 'x|y', 'go']);
  assert.equal(sheets[0].rows[0][1].runs[0].code, true);
  assert.equal(sheets[0].rows[0][2].runs[0].anchor, 'done');
  assert.deepEqual(sheets[0].rows[2].map(text), ['3', '', '']);
  assert.equal(sheets[0].headers[0].runs[0].bold, true);
});

test('records page and block of headings even when an anchor link jumps to a later page', () => {
  const doc = parseMarkdown(`[Jump](#details)\n\n${'- item\n'.repeat(30)}\n### Details`);
  assert.equal(doc.pages[0].blocks[0].runs[0].anchor, 'details');
  assert.ok(expectAnchor(doc, 'details', 'Details').page > 0);
  assert.ok(doc.pages.every((page) => page.blocks.length <= MARKDOWN_PAGE_BLOCKS));
  assert.equal(doc.truncated, false);
});

test('source, block, code and inline limits bound the preview and do not split surrogate pairs', () => {
  const sourceCut = parseMarkdown(`${' '.repeat(MARKDOWN_SOURCE_LIMIT - 1)}🚀\n# Hidden`);
  assert.equal(sourceCut.truncated, true);
  assert.equal(sourceCut.anchors.has('hidden'), false);
  const blockCut = parseMarkdown('- line\n'.repeat(MARKDOWN_BLOCK_LIMIT * 2));
  assert.equal(blockCut.truncated, true);
  assert.equal(blocks(blockCut).length, MARKDOWN_BLOCK_LIMIT);
  const doc = parseMarkdown(`\`\`\`\n${`${'x'.repeat(358)}🚀 tail\n`.repeat(20)}\`\`\`\n\n${'[Go](#last) plain '.repeat(42)}\n\n# Last`);
  assert.equal(doc.truncated, true);
  const code = blocks(doc).filter((node) => node.kind === 'code');
  assert.ok(code.length > 1);
  assert.ok(code.every((node) => !/[\uD800-\uDBFF](?:$|\n|…)/u.test(node.code)));
  const p = blocks(doc).find((node) => node.kind === 'paragraph');
  assert.ok(p.runs.length <= 32);
  assert.equal(p.runs.at(-1).anchor, '');
});
