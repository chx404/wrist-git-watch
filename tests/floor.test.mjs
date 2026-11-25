import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const common = new URL('../entry/src/main/ets/common/', import.meta.url);
async function load(name) {
  const code = stripTypeScriptTypes(await readFile(new URL(`${name}.ets`, common), 'utf8'));
  return import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
}
const { closesFloor, floorCopy, floorReveal, floorRise, opensFloor, pullAccepted, pullDistance } = await load('QuickFloor');
const { DAY_LOOK, NIGHT_LOOK } = await load('Look');
const index = await readFile(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');

test('the top panel opens only on a downward, mostly vertical pull from the top', () => {
  assert.equal(opensFloor(true, 3, 36), true);
  assert.equal(opensFloor(true, -8, 75), true);
  assert.equal(opensFloor(true, -52, 36), false);
  assert.equal(opensFloor(true, 0, 35), false);
  assert.equal(opensFloor(false, 0, 70), false);
  assert.equal(opensFloor(true, 0, -70), false);
  assert.equal(pullAccepted(true, 0, 10), true);
  assert.equal(pullDistance(-10), 0);
  assert.equal(pullDistance(20), 9);
  assert.equal(pullDistance(200), 44);
});

test('upward exit is reserved for the bottom handle or end of the panel list', () => {
  assert.equal(closesFloor(true, 3, -36), true);
  assert.equal(closesFloor(true, 3, -35), false);
  assert.equal(closesFloor(true, 70, -45), false);
  assert.equal(closesFloor(true, 3, 60), false);
  assert.equal(closesFloor(false, 0, -90), false);
});

test('floor motion has reversible clamped opacity and opposite palette', () => {
  assert.equal(floorReveal(-1), 0);
  assert.equal(floorReveal(45), 0.5);
  assert.equal(floorReveal(90), 1);
  assert.equal(floorReveal(100), 1);
  assert.equal(floorRise(0), -48);
  assert.equal(floorRise(0.5), -24);
  assert.equal(floorRise(1), 0);
  assert.match(index, /floorTheme\(\): Look \{ return this\.dark \? DAY_LOOK : NIGHT_LOOK; \}/);
  assert.match(index, /\.opacity\(this\.floorProgress\)\.translate\(\{ y: floorRise\(this\.floorProgress\)/);
  assert.doesNotMatch(index, /Button\('⌃ 返回页面'/);
});

test('all navigable pages have contextual controls and real handlers', () => {
  const kinds = new Set(['home', 'search', 'notifications', 'saved', 'repo', 'readme', 'tree', 'releases', ...
    [...index.matchAll(/(?:new Screen|this\.fromRepo)\('([a-zA-Z]+)'/g)].map(match => match[1]), 'groups', 'groupPicker']);
  for (const kind of kinds) {
    const floor = floorCopy(kind);
    assert.notEqual(floor.title, '快捷面板', `missing context for ${kind}`);
    assert.ok(floor.note && floor.actions.length, `no actionable content on ${kind}`);
    assert.equal(new Set(floor.actions.map(a => a.id)).size, floor.actions.length);
    for (const action of floor.actions) assert.ok(index.includes(`id === '${action.id}'`), `no handler for ${kind}/${action.id}`);
  }
  assert.ok(kinds.size >= 26);
});

function lum(hex) {
  const parts = hex.slice(1).match(/.{2}/g).map(n => parseInt(n, 16) / 255);
  const linear = parts.map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}
const contrast = (a, b) => (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05);

test('light and black themes keep body and active-control text readable', () => {
  assert.equal(NIGHT_LOOK.bg, '#000000');
  for (const colors of [DAY_LOOK, NIGHT_LOOK]) {
    assert.ok(contrast(colors.ink, colors.card) >= 4.5);
    assert.ok(contrast(colors.muted, colors.bg) >= 4.5);
    assert.ok(contrast(colors.accentText, colors.blue) >= 4.5);
    assert.ok(contrast(colors.blue, colors.pale) >= 4.5);
  }
});
