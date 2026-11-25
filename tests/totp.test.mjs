import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const dataUrl = (code) => `data:text/javascript;base64,${Buffer.from(code).toString('base64')}`;
const source = (name) => readFile(new URL(`../entry/src/main/ets/common/${name}.ets`, import.meta.url), 'utf8');

// Exercise the ArkTS code on the host, mapping only native system APIs to test doubles.
// Node's OpenSSL supplies HMAC; hardware-backed Asset behavior still requires a device test.
const native = dataUrl(`
  import { createHmac, randomUUID } from 'node:crypto';
  export const cryptoFramework = {
    createSymKeyGenerator(name) {
      if (name !== 'HMAC') throw new Error('Expected HMAC key');
      return { convertKeySync: ({ data }) => ({ data: data.slice(), clearMem() { this.data.fill(0); } }) };
    },
    createMac(algorithm) {
      let mac;
      return {
        initSync(key) { mac = createHmac(algorithm.toLowerCase(), key.data); },
        updateSync({ data }) { mac.update(data); },
        doFinalSync() { return { data: new Uint8Array(mac.digest()) }; }
      };
    }
  };
  export const util = {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: { create: (encoding, flags) => ({
      decodeToString: (bytes) => new TextDecoder(encoding, flags).decode(bytes)
    }) },
    generateRandomUUID: () => randomUUID()
  };
  export const fixture = { available: true, failure: 0, rows: new Map(), calls: 0, queryTypes: [] };
  export const canIUse = (capability) => capability === 'SystemCapability.Security.Asset' && fixture.available;
  const tag = Object.fromEntries('ALIAS SECRET RETURN_TYPE RETURN_LIMIT RETURN_OFFSET ACCESSIBILITY SYNC_TYPE CONFLICT_RESOLUTION DATA_LABEL_CRITICAL_1'.split(' ').map((key) => [key, key]));
  const aliasOf = (row) => new TextDecoder().decode(row.get(tag.ALIAS));
  function call() {
    fixture.calls++;
    if (fixture.failure) throw Object.assign(new Error('sensitive native diagnostic'), { code: fixture.failure });
  }
  export const asset = {
    Tag: tag, Accessibility: { DEVICE_UNLOCKED: 2 }, SyncType: { NEVER: 0 },
    ReturnType: { ALL: 0, ATTRIBUTES: 1 }, ConflictResolution: { OVERWRITE: 0, THROW_ERROR: 1 },
    async add(row) {
      call();
      const key = aliasOf(row);
      if (fixture.rows.has(key) && row.get(tag.CONFLICT_RESOLUTION) !== 0) throw { code: 24000003 };
      fixture.rows.set(key, new Map([...row].map(([k, v]) => [k, v instanceof Uint8Array ? v.slice() : v])));
    },
    async remove(query) {
      call();
      if (!fixture.rows.delete(aliasOf(query))) throw { code: 24000002 };
    },
    async query(query) {
      call();
      const type = query.get(tag.RETURN_TYPE);
      fixture.queryTypes.push(type);
      let rows = [...fixture.rows.values()];
      if (query.has(tag.ALIAS)) rows = rows.filter((row) => aliasOf(row) === aliasOf(query));
      if (query.has(tag.DATA_LABEL_CRITICAL_1)) {
        rows = rows.filter((row) => Buffer.from(row.get(tag.DATA_LABEL_CRITICAL_1) ?? []).equals(query.get(tag.DATA_LABEL_CRITICAL_1)));
      }
      const offset = query.get(tag.RETURN_OFFSET) ?? 0;
      rows = rows.slice(offset, offset + (query.get(tag.RETURN_LIMIT) ?? rows.length));
      if (!rows.length) throw { code: 24000002 };
      return rows.map((row) => new Map([...row]
        .filter(([k]) => type === 0 || k !== tag.SECRET)
        .map(([k, v]) => [k, v instanceof Uint8Array ? v.slice() : v])));
    }
  };
`);
const totpUrl = dataUrl(stripTypeScriptTypes((await source('Totp'))
  .replace("import lazy { cryptoFramework } from '@kit.CryptoArchitectureKit';", `import { cryptoFramework } from '${native}';`)));
const { calculateTotp, decodeBase32, parseTotpInput } = await import(totpUrl);
const { fixture, asset } = await import(native);
const { Vault } = await import(dataUrl(stripTypeScriptTypes((await source('Vault'))
  .replace("import lazy { asset } from '@kit.AssetStoreKit';", `import { asset, canIUse } from '${native}';`)
  .replace("'@kit.ArkTS'", `'${native}'`).replaceAll("'./Totp'", `'${totpUrl}'`))));

const defaults = { algorithm: 'SHA1', digits: 6, period: 30 };
const generic = 'JBSWY3DPEHPK3PXP';
const rfcSeed = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

for (const [algorithm, secret, expected] of [
  ['SHA1', '12345678901234567890', ['94287082', '07081804', '14050471', '89005924', '69279037', '65353130']],
  ['SHA256', '12345678901234567890123456789012', ['46119246', '68084774', '67062674', '91819424', '90698825', '77737706']],
  ['SHA512', '1234567890123456789012345678901234567890123456789012345678901234',
    ['90693936', '25091201', '99943326', '93441116', '38618901', '47863826']]
]) {
  test(`matches RFC 6238 Appendix B ${algorithm} vectors`, () => {
    const times = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000];
    const options = { algorithm, digits: 8, period: 30 };
    assert.deepEqual(times.map((s) => calculateTotp(Buffer.from(secret), options, s * 1000).code), expected);
  });
}

test('keeps six digits, rolls over at the boundary and supports counters beyond 32 bits', () => {
  const seed = decodeBase32(rfcSeed);
  assert.deepEqual(calculateTotp(seed, defaults, 29999), { code: '755224', remainingSeconds: 1, period: 30 });
  assert.deepEqual(calculateTotp(seed, defaults, 30000), { code: '287082', remainingSeconds: 30, period: 30 });
  const options = { ...defaults, period: 45 };
  assert.deepEqual(calculateTotp(seed, options, 44999), { code: '755224', remainingSeconds: 1, period: 45 });
  assert.deepEqual(calculateTotp(seed, options, 45000), { code: '287082', remainingSeconds: 45, period: 45 });
  const large = calculateTotp(seed, defaults, 2 ** 32 * 30000);
  assert.equal(large.code, '999456');
  for (const badTime of [-1, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => calculateTotp(seed, defaults, badTime), /时间无效/);
  }
});

test('decodes RFC 4648 Base32, including unpadded or grouped lowercase input', () => {
  for (const [text, encoded] of [['f', 'MY======'], ['fo', 'MZXQ===='], ['foo', 'MZXW6==='],
    ['foob', 'MZXW6YQ='], ['fooba', 'MZXW6YTB'], ['foobar', 'MZXW6YTBOI======']]) {
    const expected = new TextEncoder().encode(text);
    assert.deepEqual(decodeBase32(encoded), expected);
    assert.deepEqual(decodeBase32(encoded.replaceAll('=', '').toLowerCase().replace(/(.{4})/g, '$1 ')), expected);
  }
  for (const bad of ['', 'M', 'MZ', 'MZX', 'MZXW6Y', 'MZXQ=', 'MZXW6YTB=', 'MY=MY', 'M0', 'Mß']) {
    assert.throws(() => decodeBase32(bad), /Base32/);
  }
});

test('parses manual keys and common otpauth URIs without weakening non-default settings', () => {
  assert.deepEqual(parseTotpInput(' Example ', generic).metadata, { label: 'Example', issuer: '', ...defaults });
  const uri = 'otpauth://totp/%E6%9C%8D%E5%8A%A1%3Aalice%2Btest%40example.com?secret=my======&issuer=%E6%9C%8D%E5%8A%A1&digits=8&algorithm=sha512&period=45';
  const parsed = parseTotpInput('', uri);
  assert.deepEqual(parsed.metadata, { label: 'alice+test@example.com', issuer: '服务', algorithm: 'SHA512', digits: 8, period: 45 });
  assert.deepEqual(parsed.secret, new Uint8Array([102]));
  assert.equal(parseTotpInput(' My Account ', uri).metadata.label, 'My Account');
  assert.equal(parseTotpInput('', `otpauth://totp/Service:alice?secret=${generic}`).metadata.issuer, 'Service');
});

test('rejects malformed and incompatible otpauth inputs without exposing the seed', () => {
  const valid = `otpauth://totp/Service:alice?secret=${generic}`;
  for (const invalid of [
    valid.replace('://totp/', '://hotp/'), valid.replace('://totp/', '://totp.evil/'),
    valid.replace(':alice', ':%ZZ'), valid.replace(':alice', ':'), valid + '#fragment',
    valid + '&s%65cret=MY', valid + '&issuer=Other', valid + '&counter=0', valid + '&encoder=steam',
    valid + '&digits=7', valid + '&algorithm=MD5', valid + '&period=0', valid + '&period=86401',
    valid + '&period=1e2', 'otpauth://totp/A?issuer=Test'
  ]) {
    assert.throws(() => parseTotpInput('', invalid), (error) => !error.message.includes(generic));
  }
  assert.throws(() => parseTotpInput('', generic), /账户名称/);
});

test('Vault token overwrite/removal and paginated TOTP metadata', async () => {
  assert.equal(await Vault.loadToken(), '');
  await Vault.saveToken(' first-token ');
  await Vault.saveToken('second-token');
  assert.equal(await Vault.loadToken(), 'second-token');
  await assert.rejects(Vault.saveToken('bad\nheader'), /有效的 GitHub 令牌/);
  assert.equal(await Vault.loadToken(), 'second-token');
  await Vault.clearToken();
  await Vault.clearToken();
  assert.equal(await Vault.loadToken(), '');

  await Vault.saveToken('unrelated-token');
  const uri = `otpauth://totp/Service:Account?secret=${rfcSeed}`;
  for (let i = 0; i < 21; i++) await Vault.saveTotp(`Label ${i}`, uri);
  const { Tag } = asset;
  for (const row of fixture.rows.values()) {
    assert.equal(row.get(Tag.SYNC_TYPE), asset.SyncType.NEVER);
    assert.equal(row.get(Tag.ACCESSIBILITY), asset.Accessibility.DEVICE_UNLOCKED);
    for (const [tag, value] of row) {
      if (tag !== Tag.SECRET && value instanceof Uint8Array) {
        assert.doesNotMatch(new TextDecoder().decode(value), /Label|Service|1234567890|token/);
      }
    }
  }
  fixture.queryTypes.length = 0;
  const accounts = await Vault.listTotp();
  assert.equal(accounts.length, 21);
  assert.equal(new Set(accounts.map(({ id }) => id)).size, 21);
  assert.equal(fixture.queryTypes.filter((type) => type === asset.ReturnType.ATTRIBUTES).length, 2);
  const id = accounts.find(({ label }) => label === 'Label 20').id;
  assert.deepEqual(accounts.find((account) => account.id === id), { id, label: 'Label 20', issuer: 'Service', ...defaults });
  assert.equal((await Vault.codeFor(id, 59000)).code, '287082');
  await Vault.removeTotp(id);
  await Vault.removeTotp(id);
  await assert.rejects(Vault.codeFor(id, 59000), /不存在/);
  assert.equal((await Vault.listTotp()).length, 20);
  assert.equal(await Vault.loadToken(), 'unrelated-token');
});

test('Vault fails closed when unavailable or locked and sanitizes native diagnostics', async () => {
  fixture.rows.clear();
  await Vault.saveToken('unrelated-token');
  const calls = fixture.calls;
  fixture.available = false;
  for (const operation of [() => Vault.loadToken(), () => Vault.listTotp(), () => Vault.clearToken(),
    () => Vault.saveToken('hidden'), () => Vault.saveTotp('Example', generic)]) {
    await assert.rejects(operation(), /安全存储.*不可用/);
  }
  assert.equal(fixture.calls, calls);
  fixture.available = true;
  fixture.failure = 24000001;
  await assert.rejects(Vault.loadToken(), /安全存储.*不可用/);
  fixture.failure = 24000005;
  await assert.rejects(Vault.loadToken(), /解锁手表/);
  fixture.failure = 24000008;
  await assert.rejects(Vault.loadToken(), { message: '系统安全存储操作失败' });
  fixture.failure = 0;
  await assert.rejects(Vault.removeTotp('wristgit.pat.v1'), /账户 ID 无效/);
  assert.equal(await Vault.loadToken(), 'unrelated-token');
});
