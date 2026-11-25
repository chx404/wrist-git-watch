// Host-only smoke test for generated ViewPU control flow, not native ArkUI or wearable execution.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { pathToFileURL } from 'node:url';

const generated = process.argv[2] ?? new URL('../entry/build/api26/cache/default/default@CompileArkTS/esmodule/release/entry/src/main/ets/pages/Index.ts', import.meta.url);
const source = await readFile(generated, 'utf8');
const js = stripTypeScriptTypes(source.replace(/^import .*;\r?\n/gm, ''), { mode: 'transform' });
const events = [];
const declarations = new Map();
const widget = name => new Proxy({}, { get(_target, key) {
  return (...args) => {
    events.push([`${name}.${String(key)}`, ...args]);
  };
} });
const forbid = name => new Proxy({}, { get() { assert.fail(`${name} accessed before opt-in`); } });
class State {
  constructor(value) { this.value = value; }
  get() { return this.value; }
  set(value) { this.value = value; }
}
class ViewPU {
  observeComponentCreation2(fn) { fn(1, true); }
  ifElseBranchUpdateFunction(_branch, fn) { fn(); }
  forEachUpdateFunction(_id, items, fn) { items.forEach(fn); }
  getUIContext() { assert.fail('UI context accessed before enhanced mode / services'); }
}
class Scroller {
  constructor() { events.push(['Scroller']); }
  currentOffset() { return { yOffset: 0 }; }
}
class WatchTab { constructor(title, key) { Object.assign(this, { title, key }); } }
class CrownMotion { reset() {} }
const enumStub = new Proxy({}, { get: (_target, key) => String(key) });
const context = {
  console: { info: msg => events.push([msg]), warn: msg => events.push([msg]) },
  ViewPU, ObservedPropertyObjectPU: State, ObservedPropertySimplePU: State, SynchedPropertySimpleOneWayPU: State,
  WatchTab, CrownMotion, Scroller, registerNamedRoute: (fn, _name, meta) => declarations.set(meta.pagePath, fn),
  ROOT_SENTINEL: true, DAY_LOOK: { bg: '#fff', blue: '#009', card: '#fff', muted: '#555', ink: '#000', pale: '#eef' },
  preferences: forbid('preferences'), GitHub: forbid('GitHub'), Downloads: forbid('Downloads'), Vault: forbid('Vault'),
  AppStorage: forbid('AppStorage'), curves: forbid('curves'),
  setTimeout: () => 1, clearTimeout: () => {},
  allowsQuickFloor: kind => !['saved', 'groups', 'group', 'groupPicker', 'starred'].includes(kind),
  $r: () => assert.fail('native resources resolved before enhanced mode')
};
for (const name of ['Alignment', 'TextAlign', 'FontWeight', 'FlexAlign', 'VerticalAlign', 'HorizontalAlign', 'ButtonType', 'TextOverflow', 'Color', 'BarState']) context[name] = enumStub;
for (const name of ['If', 'Column', 'Text', 'Button', 'Scroll', 'Stack', 'Row', 'Blank', 'ForEach']) context[name] = widget(name);
vm.runInNewContext(js, context, { filename: 'GeneratedIndex.ts' });
const index = declarations.get('pages/Index')();
index.aboutToAppear();
index.initialRender();
assert.equal(events.filter(([name]) => name === 'Scroller').length, 2);
assert.ok(events.some(([name]) => name === 'Scroll.create'));
assert.ok(events.some(([name, value]) => name === 'Button.createWithLabel' && value === '首页'));
assert.ok(!events.some(([name]) => ['Scroll.onDigitalCrown', 'Scroll.parallelGesture', 'Stack.transition'].includes(name)));
console.log('Direct boot: the first painted frame is the compatible full surface with four tabs');

const guideSource = await readFile(new URL('../components/WristGuide.ts', typeof generated === 'string' ? pathToFileURL(generated) : generated), 'utf8');
const guideJS = stripTypeScriptTypes(guideSource.replace(/^import .*;\r?\n/gm, '').replace(/^export class /gm, 'class '), { mode: 'transform' });
for (const name of ['Circle']) context[name] = widget(name);
context.NIGHT_LOOK = { ...context.DAY_LOOK, bg: '#000', blue: '#9bf', muted: '#abc', ink: '#fff', card: '#111' };
vm.runInNewContext(`${guideJS}\nglobalThis.makeWristGuide = (dark) => new WristGuide(undefined, {dark});`, context, { filename: 'GeneratedGuide.ts' });
for (const dark of [false, true]) {
  events.length = 0;
  context.makeWristGuide(dark).initialRender();
  assert.ok(events.some(([name, value]) => name === 'Text.create' && value === '在页首向下滑'));
  assert.ok(events.some(([name, value]) => name === 'Scroll.backgroundColor' && value === (dark ? '#000' : '#fff')));
}
console.log('Guide: both light and dark first frames rendered successfully');

const floorSource = await readFile(new URL('../entry/src/main/ets/common/QuickFloor.ets', import.meta.url), 'utf8');
const floorJS = stripTypeScriptTypes(floorSource.replace(/^export /gm, ''), { mode: 'transform' });
for (const name of ['PanGesture', 'Gesture']) context[name] = widget(name);
for (const name of ['EdgeEffect', 'CrownSensitivity', 'HitTestMode', 'PanDirection', 'GesturePriority', 'GestureMask']) context[name] = enumStub;
Object.assign(context.DAY_LOOK, { glow: '#def', low: '#ffe', accentText: '#fff', border: '#ccd' });
Object.assign(context.NIGHT_LOOK, { glow: '#111', low: '#050505', accentText: '#000', border: '#445' });
vm.runInNewContext(floorJS, context, { filename: 'GeneratedFloorDependencies.ts' });
index.floorVisible = true;
index.floorOpen = true;
index.floorProgress = 0.5;
for (const dark of [false, true]) {
  events.length = 0;
  index.dark = dark;
  index.initialRender();
  const theme = dark ? context.DAY_LOOK : context.NIGHT_LOOK;
  assert.ok(events.some(([name, value]) => name === 'Stack.linearGradient' && value.colors[1][0] === theme.bg));
  assert.ok(events.some(([name, value]) => name === 'Stack.opacity' && value === 0.5));
  assert.ok(events.some(([name, value]) => name === 'Column.accessibilityText' && value === '从这里向上滑动返回页面'));
  assert.ok(events.some(([name, value]) => name === 'Column.height' && value === 26));
  assert.ok(!events.some(([name, value]) => name === 'Button.createWithLabel' && value === '⌃ 返回页面'));
}
console.log('Floor: both inverse palettes render with transitional opacity and a thin swipe handle');

for (const name of ['PasteIconStyle', 'PasteDescription', 'PasteButtonOnClickResult']) context[name] = enumStub;
for (const name of ['PasteButton', 'TextInput']) context[name] = widget(name);
index.floorVisible = false;
index.floorOpen = false;
index.screen.kind = 'search';
index.screen.title = '搜索';
events.length = 0;
index.initialRender();
assert.ok(events.some(([name, value]) => name === 'Button.createWithLabel' && value === '输入关键词或仓库名 ›'));
assert.ok(!events.some(([name]) => name.startsWith('TextInput.')));
index.screen.kind = 'saved';
index.screen.title = '收藏';
events.length = 0;
index.initialRender();
assert.ok(!events.some(([name, value]) => name === 'Button.accessibilityText' && typeof value === 'string' && value.includes('打开快捷面板')));
console.log('Search has no editable field before explicit activation; 收藏 has no quick-floor cue');

for (const name of ['Swiper', 'Image']) context[name] = widget(name);
context.ImageFit = enumStub;
context.$r = () => 'test-resource';
const pagerCode = stripTypeScriptTypes((await readFile(new URL('../entry/src/main/ets/common/WatchPager.ets', import.meta.url), 'utf8'))
  .replace(/^export /gm, ''), { mode: 'transform' });
context.watchPageProgress = new Function(`${pagerCode}; return watchPageProgress;`)();
index.enhanced = true;
index.screen.kind = 'home';
index.screen.title = '首页';
events.length = 0;
index.initialRender();
assert.ok(events.some(([name, value]) => name === 'Swiper.indicator' && value === false));
assert.ok(events.some(([name, value]) => name === 'Swiper.loop' && value === false));
const position = events.find(([name]) => name === 'Swiper.onContentDidScroll')[1];
position(0, 1, 0.7, 230);
assert.ok(Math.abs(index.pagerProgress - 0.3) < 1e-10);
let selected = -1;
index.dockSelect = canonical => { selected = canonical; };
events.find(([name]) => name === 'Swiper.onChange')[1](1);
assert.equal(selected, 1);
assert.ok(!events.some(([name]) => name.startsWith('Path.')));
console.log('Swiper: native page events move the short indicator and commit tab switches, no glass path');
