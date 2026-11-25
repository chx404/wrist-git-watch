import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../entry/src/main/ets/common/DockGeometry.ets', import.meta.url), 'utf8');
const code = stripTypeScriptTypes(source);
const { DockGeometry, DOCK_WIDTH_FRACTION, DOCK_HEIGHT, DOCK_BOTTOM_INSET, DOCK_RAIL_THICKNESS,
  DOCK_LENS_HEIGHT, DOCK_TOUCH_HEIGHT, clampDockSlot, dockDragSlot, dockDragTarget, dockGlassOpacity } =
  await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const component = await readFile(new URL('../entry/src/main/ets/components/GlassDock.ets', import.meta.url), 'utf8');

const near = (value, expected) => assert.ok(Math.abs(value - expected) < 1e-8, `${value} ≈ ${expected}`);

test('the 20 vp curve is concentric with the watch and fits its 46 vp overlay', () => {
  for (const diameter of [192, 220, 240, 260, 300, 320]) {
    const width = DOCK_WIDTH_FRACTION * diameter;
    const dock = new DockGeometry(width);
    const top = diameter - DOCK_HEIGHT - DOCK_BOTTOM_INSET;
    const left = (diameter - width) / 2;
    const railRim = (DOCK_RAIL_THICKNESS + 1.5) / 2;
    near(left + dock.centerX, diameter / 2);
    near(top + dock.centerY, diameter / 2);
    for (let step = -16; step <= 16; step++) {
      const angle = dock.halfAngle * step / 16;
      const x = dock.centerX + dock.radius * Math.sin(angle);
      const y = dock.centerY + dock.radius * Math.cos(angle);
      assert.ok(x - railRim >= 0 && x + railRim <= width);
      assert.ok(y - railRim >= 0 && y + railRim <= DOCK_HEIGHT);
      assert.ok(dock.radius + railRim < diameter / 2);
    }
  }
});

test('the declarative arc has finite symmetric endpoints and shortens the edge shine', () => {
  assert.equal(new DockGeometry(0).strokePath(), 'M 0 0');
  const geometry = new DockGeometry(148.8);
  const path = geometry.strokePath().split(' ');
  assert.deepEqual([path[0], path[3], path[6], path[7], path[8]], ['M', 'A', '0', '0', '0']);
  assert.ok(Math.abs(Number(path[1]) + Number(path[9]) - geometry.width) < 0.002);
  assert.equal(path[2], path[10]);
  const shine = geometry.strokePath(-8, 0.035).split(' ');
  assert.ok(Number(shine[1]) > Number(path[1]));
});

test('quarter slots read symmetrically with larger (in-bounds) touch regions', () => {
  for (const diameter of [192, 240, 260, 320]) {
    const dock = new DockGeometry(diameter * DOCK_WIDTH_FRACTION);
    const count = 4;
    assert.ok(dock.lensWidth(count) < dock.slotWidth(count));
    for (let index = 0; index < count; index++) {
      const mirror = count - 1 - index;
      const hitTop = dock.touchTop(index, count);
      const labelY = dock.slotY(index, count);
      near(dock.slotX(index, count) + dock.slotX(mirror, count), dock.width);
      near(labelY, dock.slotY(mirror, count));
      assert.ok(Math.abs(dock.slotAngle(index, count)) < dock.halfAngle);
      assert.ok(hitTop >= 0 && hitTop + DOCK_TOUCH_HEIGHT <= DOCK_HEIGHT);
      assert.ok(labelY - DOCK_LENS_HEIGHT / 2 >= hitTop);
      assert.ok(labelY + DOCK_LENS_HEIGHT / 2 <= hitTop + DOCK_TOUCH_HEIGHT);
    }
  }
});

test('all four native cell boxes sit on the existing circular track', () => {
  const count = 4;
  for (const diameter of [192, 220, 240, 260, 300, 320]) {
    const dock = new DockGeometry(diameter * DOCK_WIDTH_FRACTION);
    const width = dock.slotWidth(count);
    for (let slot = 0; slot < count; slot++) {
      const left = dock.cellLeft(slot, count);
      const top = dock.cellTop(slot, count);
      const x = left + width / 2;
      const y = top + DOCK_RAIL_THICKNESS / 2;
      near(x, dock.slotX(slot, count));
      near(y, dock.slotY(slot, count));
      near(Math.hypot(x - dock.centerX, y - dock.centerY), dock.radius);
      assert.ok(left >= 0 && left + width <= dock.width);
      assert.ok(top >= 0 && top + DOCK_RAIL_THICKNESS <= DOCK_HEIGHT);
    }
  }
});

test('every tab builds glass and text inside the same native centered cell', () => {
  const glass = component.slice(component.indexOf('  cellGlass('), component.indexOf('  dockCell('));
  const cell = component.slice(component.indexOf('  dockCell('), component.indexOf('  build()'));
  const root = component.slice(component.indexOf('  build()'));
  assert.match(glass, /\.opacity\(dockGlassOpacity\(/);
  assert.doesNotMatch(glass, /\.position\(/);
  assert.match(cell, /Button\(\{ type: ButtonType\.Capsule \}\)\s*\{[\s\S]*?Stack\(\{ alignContent: Alignment\.Center \}\)\s*\{\s*this\.cellGlass\(tab\)\s*Text\(tab\.title\)/);
  assert.equal((cell.match(/\.position\(/g) ?? []).length, 1);
  assert.equal((component.match(/this\.cellGlass\(/g) ?? []).length, 1);
  assert.match(root, /ForEach\(this\.tabs, \(tab: DockTab\) => \{ this\.dockCell\(tab\) \}/);
});

test('drag blends adjacent fixed glass cells and leaves only the settled cell lit', () => {
  const cells = [0, 1, 2, 3];
  for (const active of cells) {
    assert.deepEqual(cells.map(slot => dockGlassOpacity(slot, active)), cells.map(slot => Number(slot === active)));
  }
  for (let slot = 0; slot < cells.length - 1; slot++) {
    const preview = dockDragSlot(slot, 9, 36, cells.length);
    assert.deepEqual(cells.map(cell => dockGlassOpacity(cell, preview)),
      cells.map(cell => cell === slot ? 0.75 : cell === slot + 1 ? 0.25 : 0));
  }
});

test('drag previews fractionally, snaps symmetrically and clamps to valid tabs', () => {
  const width = 36;
  near(dockDragSlot(2, -9, width, 4), 1.75);
  assert.equal(dockDragTarget(2, -13, width, 4), 2);
  assert.equal(dockDragTarget(2, -14, width, 4), 1);
  assert.equal(dockDragTarget(1, 14, width, 4), 2);
  assert.equal(dockDragTarget(2, -width / 2, width, 4), 1);
  assert.equal(dockDragTarget(1, width / 2, width, 4), 2);
  assert.equal(dockDragTarget(0, -999, width, 4), 0);
  assert.equal(dockDragTarget(1, 999, width, 4), 3);
  assert.equal(dockDragSlot(3, 999, width, 4), 3);
  assert.equal(dockDragTarget(2, 999, 0, 4), 2);
  assert.equal(clampDockSlot(-1, 4), 0);
  assert.equal(clampDockSlot(7, 0), 0);
});
