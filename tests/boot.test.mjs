import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const get = async path => readFile(new URL(`../entry/src/main/${path}`, import.meta.url), 'utf8');

test('the complete app is the only route and boots straight into its surface', async () => {
  const entry = await get('ets/entryability/EntryAbility.ets');
  const routes = JSON.parse(await get('resources/base/profile/main_pages.json'));
  assert.deepEqual(routes.src, ['pages/Index']);
  assert.match(entry, /stage\.loadContent\('pages\/Index'/);
  const index = await get('ets/pages/Index.ets');
  assert.match(index, /aboutToAppear\(\): void \{\s*console\.info\([^)]*index-created[^)]*\);[\s\S]*?this\.activateFull\(\);/);
  assert.doesNotMatch(index, /SafeHome|FullBoot|goLite|返回轻量版/);
});

test('enhanced UI still switches on after the minimal frame and services', async () => {
  const index = await get('ets/pages/Index.ets');
  assert.match(index, /private fullReady: boolean = false/);
  assert.match(index, /build\(\) \{\s*if \(!this\.fullReady\) \{\s*this\.shell\(\)/);
  assert.match(index, /if \(this\.enhanced && ROOT_KINDS\.includes\(this\.screen\.kind\)\) \{\s*this\.nativePager\(1, ROOT_TABS\)/);
  assert.match(index, /else \{\s*this\.compatibleScroll\(\)/);
  assert.match(index, /scheduleDefaultEnhanced\(\): void \{\s*if \(!this\.fullReady \|\| !this\.servicesReady/);
  assert.match(index, /this\.defaultApplied = true;\s*if \(!this\.enhanced\) \{ this\.tryEnhanced\(\); \}/);
  assert.match(index, /F20[^\n]+scheduleServices\(\)/);
});

test('QR device sign-in is wired from settings with safe polling bounds', async () => {
  const index = await get('ets/pages/Index.ets');
  assert.match(index, /扫码连接 GitHub（推荐）/);
  assert.match(index, /openDeviceAuth\(\)/);
  assert.match(index, /DeviceAuth\.start\(this\.deviceClientId\(\), DEVICE_SCOPE\)/);
  assert.match(index, /DeviceAuth\.poll\(session, this\.deviceClientId\(\)/);
  assert.match(index, /finishDeviceAuth\(token\)/);
  assert.match(index, /qrPathCommands\(qr, cell, 2\)/);
  assert.match(index, /this\.qrZoom = true/);
  assert.match(index, /qrZoomOverlay\(\)/);
  assert.doesNotMatch(index, /console\.(info|warn|error)\([^)]*device_?code/i);
  const navigation = await get('ets/common/WristNavigation.ets');
  assert.match(navigation, /'deviceAuth'/);
});

test('the lightweight guard module is gone from the source tree', async () => {
  const probe = new URL('../entry/src/main/ets/common/FullBoot.ets', import.meta.url);
  await assert.rejects(readFile(probe), { code: 'ENOENT' });
  const safe = new URL('../entry/src/main/ets/pages/SafeHome.ets', import.meta.url);
  await assert.rejects(readFile(safe), { code: 'ENOENT' });
});

test('device flow polling still parses and cancels', async () => {
  const source = await get('ets/common/DeviceAuth.ets');
  const js = stripTypeScriptTypes(source.replace(/^import .*;\n/gm, '').replace(/^export /gm, ''), { mode: 'transform' });
  const mod = new Function('http', 'canIUse', `${js}\nreturn { DeviceAuth, DEVICE_CLIENT_ID };`)({
    RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' },
    createHttp() { return { request: async () => ({ responseCode: 200, result: '{"access_token":"gho_' + 'x'.repeat(40) + '"}' }), destroy() {} }; },
  }, () => true);
  const token = await mod.DeviceAuth.poll(
    { deviceCode: 'd'.repeat(40), userCode: 'WDJB-MJHT', verificationUri: 'https://github.com/login/device', expiresIn: 900, interval: 1 },
    'c'.repeat(20), () => true, () => {}, () => Promise.resolve());
  assert.match(token, /^gho_/);
});
