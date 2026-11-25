import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../entry/src/main/ets/common/DeviceAuth.ets', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(source.replace(/^import .*;\n/gm, '').replace(/^export /gm, ''), { mode: 'transform' });
function makeDeviceAuth(responder) {
  const requests = [];
  const http = {
    RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' },
    createHttp() { return {
      request: async (url, config) => {
        requests.push({ url, config });
        return responder(requests.length, config);
      },
      destroy() {},
    }; },
  };
  const mod = new Function('http', 'canIUse', `${js}\nreturn { DeviceAuth, DeviceAuthError, DEVICE_CLIENT_ID, DEVICE_SCOPE };`);
  return { ...mod(http, () => true), requests };
}

const session = { deviceCode: 'd'.repeat(40), userCode: 'WDJB-MJHT',
  verificationUri: 'https://github.com/login/device', expiresIn: 900, interval: 5 };

test('device code start parses the session and validates the client id first', async () => {
  const { DeviceAuth, DeviceAuthError, requests } = makeDeviceAuth(() => ({
    responseCode: 200, result: JSON.stringify({ device_code: 'd'.repeat(40), user_code: 'WDJB-MJHT',
      verification_uri: 'https://github.com/login/device', expires_in: 900, interval: 5 }) }));
  const out = await DeviceAuth.start('178c6fc778ccc68e1d6a', 'repo user');
  assert.deepEqual(out, session);
  assert.equal(requests[0].url, 'https://github.com/login/device/code');
  assert.ok(requests[0].config.extraData.includes('client_id=178c6fc778ccc68e1d6a'));
  assert.ok(!requests[0].config.header.Authorization);
  await assert.rejects(DeviceAuth.start('bad id!', 'repo'), { code: 'client' });
  assert.equal(requests.length, 1);

  const invalid = makeDeviceAuth(() => ({ responseCode: 200,
    result: JSON.stringify({ device_code: 'x', user_code: 'zzz', verification_uri: 'https://evil.example/' }) }));
  await assert.rejects(invalid.DeviceAuth.start('178c6fc778ccc68e1d6a', 'repo'), { code: 'session' });
  const broken = makeDeviceAuth(() => ({ responseCode: 401, result: 'denied' }));
  await assert.rejects(broken.DeviceAuth.start('178c6fc778ccc68e1d6a', 'repo'), { code: 'http' });
});

test('polling handles pending, slow_down and success without leaking secrets', async () => {
  const responses = ['{"error":"authorization_pending"}', '{"error":"slow_down","interval":10}',
    '{"error":"authorization_pending"}', '{"access_token":"gho_' + 't'.repeat(40) + '"}'];
  const delays = [];
  const { DeviceAuth, requests } = makeDeviceAuth(() => ({ responseCode: 200, result: responses.shift() }));
  const ticks = [];
  const token = await DeviceAuth.poll({ ...session, interval: 2 }, 'cid12345678901234567890',
    () => true, tick => ticks.push(tick), ms => { delays.push(ms); return Promise.resolve(); });
  assert.equal(token, 'gho_' + 't'.repeat(40));
  assert.deepEqual(delays, [2000, 7000, 7000]);
  assert.deepEqual(ticks, ['等待在手机上确认授权…', '请求过快，已自动放慢轮询…', '等待在手机上确认授权…']);
  for (const req of requests) {
    assert.ok(!req.config.extraData.includes('authorization') && !req.config.extraData.includes('token='));
    assert.equal(req.url, 'https://github.com/login/oauth/access_token');
    assert.ok(req.config.extraData.includes('grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code'));
  }
});

test('polling stops on expiry, denial, cancellation and malformed responses', async () => {
  for (const [body, code] of [['{"error":"expired_token"}', 'expired'], ['{"error":"access_denied"}', 'denied']]) {
    const { DeviceAuth } = makeDeviceAuth(() => ({ responseCode: 200, result: body }));
    await assert.rejects(DeviceAuth.poll({ ...session, interval: 1 }, 'c'.repeat(20), () => true, () => {},
      () => Promise.resolve()), { code });
  }
  let calls = 0;
  const { DeviceAuth } = makeDeviceAuth(() => { calls++; return { responseCode: 200, result: '{"error":"authorization_pending"}' }; });
  await assert.rejects(DeviceAuth.poll({ ...session, interval: 1 }, 'c'.repeat(20),
    () => calls < 2, () => {}, () => Promise.resolve()), { code: 'cancelled' });
  assert.equal(calls, 2);
  const bad = makeDeviceAuth(() => ({ responseCode: 200, result: '<html>proxy error</html>' }));
  await assert.rejects(bad.DeviceAuth.poll({ ...session, interval: 1 }, 'c'.repeat(20), () => true, () => {},
    () => Promise.resolve()), { code: 'json' });
});

test('verification URL carries only the user code', () => {
  const mod = makeDeviceAuth(() => ({ responseCode: 200, result: '{}' }));
  assert.equal(mod.DeviceAuth.verificationUrl('WDJB-MJHT'),
    'https://github.com/login/device?user_code=WDJB-MJHT');
  assert.ok(!mod.DeviceAuth.verificationUrl('AB CD').includes(' '));
});
