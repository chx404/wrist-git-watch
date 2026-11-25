import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../entry/src/main/ets/common/WristNavigation.ets', import.meta.url), 'utf8');
const { allowsQuickFloor, rootSwipeTarget } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
const pager = await readFile(new URL('../entry/src/main/ets/common/WatchPager.ets', import.meta.url), 'utf8');
const { watchPageProgress } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(pager)).toString('base64')}`);

test('adjacent native Swiper callbacks give the same short-bar position', () => {
  for (const page of [0, 1, 2]) {
    for (const fraction of [0.1, 0.3, 0.5, 0.83]) {
      assert.ok(Math.abs(watchPageProgress(page, -fraction, 4) - (page + fraction)) < 1e-9);
      assert.ok(Math.abs(watchPageProgress(page + 1, 1 - fraction, 4) - (page + fraction)) < 1e-9);
    }
  }
  assert.equal(watchPageProgress(0, 0.2, 4), 0);
  assert.equal(watchPageProgress(3, -0.2, 4), 3);
  assert.equal(watchPageProgress(3, NaN, 4), 0);
});

test('horizontal swipes move through root tabs in order without wrapping', () => {
  assert.equal(rootSwipeTarget(0, 4, -50, 2), 1);
  assert.equal(rootSwipeTarget(1, 4, -50, 4), 2);
  assert.equal(rootSwipeTarget(2, 4, -50, 1), 3);
  assert.equal(rootSwipeTarget(3, 4, 80, 8), 2);
  assert.equal(rootSwipeTarget(3, 4, -80, 8), -1);
  assert.equal(rootSwipeTarget(0, 4, 80, 8), -1);
});

test('short, vertical, invalid or deep-page swipes cannot change tabs', () => {
  assert.equal(rootSwipeTarget(1, 4, 39, 0), -1);
  assert.equal(rootSwipeTarget(1, 4, -45, 60), -1);
  assert.equal(rootSwipeTarget(-1, 4, -60, 0), -1);
  assert.equal(rootSwipeTarget(1, 4, NaN, 0), -1);
  assert.equal(rootSwipeTarget(1, 4, -60, NaN), -1);
});

test('the collection family has no quick floor while other tabs keep theirs', () => {
  for (const kind of ['saved', 'starred', 'groups', 'group', 'groupPicker']) assert.equal(allowsQuickFloor(kind), false);
  for (const kind of ['home', 'search', 'notifications', 'repo', 'settings']) assert.equal(allowsQuickFloor(kind), true);
});
