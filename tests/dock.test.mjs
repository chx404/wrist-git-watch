import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../entry/src/main/ets/common/DockGeometry.ets', import.meta.url), 'utf8');
const code = stripTypeScriptTypes(source);
const { DockGeometry, DOCK_WIDTH_FRACTION, DOCK_HEIGHT, DOCK_BOTTOM_INSET, DOCK_RAIL_THICKNESS,
  DOCK_LENS_HEIGHT, DOCK_TOUCH_HEIGHT, clampDockSlot, dockDragSlot, dockDragTarget } =
  await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);

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

test('intermediate lens angle stays on the track instead of following a chord', () => {
  const dock = new DockGeometry(240 * DOCK_WIDTH_FRACTION);
  for (const slot of [0, 0.25, 1, 1.5, 2.8, 3]) {
    const radians = -dock.slotAngle(slot, 4);
    near(dock.centerX - dock.radius * Math.sin(radians), dock.slotX(slot, 4));
    near(dock.centerY + dock.radius * Math.cos(radians), dock.slotY(slot, 4));
  }
  assert.ok(dock.slotY(1.5, 4) > dock.slotY(0, 4));
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
