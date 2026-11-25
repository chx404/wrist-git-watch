import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../entry/src/main/ets/common/CrownMotion.ets', import.meta.url), 'utf8');
const { CrownMotion, crownDelta, crownScrollRange, crownStep, CROWN_EDGE_LIMIT_VP, CROWN_STEP_LIMIT_VP } =
  await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);

test('uses relative degrees, supports direction calibration and clamps extreme samples', () => {
  assert.equal(crownDelta(10), 13);
  assert.equal(crownDelta(-10), -13);
  assert.equal(crownDelta(10, 2, -1), -20);
  assert.equal(crownDelta(-360), -CROWN_STEP_LIMIT_VP);
  assert.equal(crownDelta(NaN), 0);
  assert.equal(crownDelta(Infinity), 0);
  assert.equal(crownDelta(15, -2), 0);
});

test('distinguishes a short list from a viewport not laid out yet', () => {
  assert.equal(crownScrollRange(0, 800), -1);
  assert.equal(crownScrollRange(420, -1), -1);
  assert.equal(crownScrollRange(420, 200), 0);
  assert.equal(crownScrollRange(420, 800), 380);
});

test('scrolls in bounds and uses only the unconsumed delta to move the last item', () => {
  assert.deepEqual(crownStep(40, 100, 10), { targetY: 50, pull: 0, translationY: 0 });
  const crossing = crownStep(95, 100, 10);
  assert.equal(crossing.targetY, 100);
  assert.equal(crossing.pull, 5);
  assert.ok(crossing.translationY < 0);
  const atEnd = crownStep(100, 100, 10, crossing.pull);
  assert.equal(atEnd.targetY, 100);
  assert.ok(atEnd.translationY < crossing.translationY);
});

test('resists and caps continued overscroll, reverses without a dead zone', () => {
  const first = crownStep(100, 100, 8);
  let result = crownStep(100, 100, 8, first.pull);
  assert.ok(Math.abs(result.translationY - first.translationY) < Math.abs(first.translationY));
  for (let i = 0; i < 80; i++) {
    result = crownStep(100, 100, 8, result.pull);
  }
  assert.equal(result.targetY, 100);
  assert.ok(Math.abs(result.translationY) < CROWN_EDGE_LIMIT_VP);
  assert.deepEqual(crownStep(100, 100, -5, result.pull), { targetY: 95, pull: 0, translationY: 0 });
  assert.deepEqual(crownStep(100, 120, 5, result.pull), { targetY: 105, pull: 0, translationY: 0 });
});

test('top feedback does not send a negative native scroll target even with touch bounce', () => {
  const top = crownStep(-12, 100, -8);
  assert.equal(top.targetY, 0);
  assert.ok(top.translationY > 0);
  assert.deepEqual(crownStep(-12, 100, 8), { targetY: 8, pull: 0, translationY: 0 });
  assert.equal(crownStep(0, 0, -8).targetY, 0);
  assert.ok(crownStep(0, 0, -8).translationY > 0);
  assert.ok(crownStep(0, 0, 8).translationY < 0);
});

test('gives an END-only step time to render then springs to rest', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const targets = [];
  const translations = [];
  let settles = 0;
  const motion = new CrownMotion((y) => targets.push(y), (y) => translations.push(y), () => { settles++; });
  motion.apply(10, 96, 100);
  motion.settle();
  assert.deepEqual(targets, [100]);
  assert.ok(translations[0] < 0);
  assert.equal(settles, 0);
  t.mock.timers.tick(30);
  assert.equal(settles, 0);
  t.mock.timers.tick(30);
  assert.equal(settles, 1);
  t.mock.timers.tick(200);
  assert.equal(settles, 1);
});

test('extends the idle deadline and resets pending work when the surface loses ownership', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const targets = [];
  const translations = [];
  let settles = 0;
  const motion = new CrownMotion((y) => targets.push(y), (y) => translations.push(y), () => { settles++; });
  motion.apply(10, 0, -1);
  assert.deepEqual(targets, []);
  assert.deepEqual(translations, []);
  motion.apply(-12, 0, 100);
  t.mock.timers.tick(100);
  motion.apply(-12, 0, 100);
  t.mock.timers.tick(30);
  assert.equal(settles, 0);
  t.mock.timers.tick(120);
  assert.equal(settles, 1);
  motion.apply(-12, 0, 100);
  motion.reset();
  assert.equal(translations.at(-1), 0);
  t.mock.timers.tick(200);
  assert.equal(settles, 1);
  assert.deepEqual(targets, []);
});
