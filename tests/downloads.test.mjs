import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

// Run the download controller against a fake native agent and sandbox, never a live mirror.
const source = await readFile(new URL('../entry/src/main/ets/common/Downloads.ets', import.meta.url), 'utf8');
const code = stripTypeScriptTypes(source.replace(/^import .*;\n/gm, ''));
const load = new Function('request', 'fs', 'canIUse', code.replace(/^export /gm, '') + '\nreturn { Downloads, DOWNLOAD_MAX_BYTES };');
const root = '/data/storage/el2/base/files';
const saved = `${root}/wristgit-downloads/latest`;
const zip = Uint8Array.of(0x50, 0x4b, 0x05, 0x06, ...new Uint8Array(18));

function fake(script) {
  const files = new Map();
  const requests = [];
  const tasks = new Map();
  const removed = [];
  const transitions = [];
  const context = { filesDir: root };
  const agent = {
    Action: { DOWNLOAD: 0 },
    Mode: { FOREGROUND: 1 },
    async create(actualContext, config) {
      assert.equal(actualContext, context);
      requests.push(config);
      const events = new Map();
      const emit = (event, value) => events.get(event)?.(value);
      const tid = String(requests.length);
      const tools = {
        config,
        reply(statusCode, headers = []) { emit('response', { statusCode, headers: new Map(headers) }); },
        progress(processed, size = -1) { emit('progress', { processed, sizes: [size] }); },
        complete(data) {
          files.set(config.saveas, data);
          emit('completed', { processed: data.length, sizes: [data.length] });
        },
      };
      const task = {
        tid,
        on: (event, callback) => events.set(event, callback),
        off: (event) => events.delete(event),
        start: async () => script(tools, requests.length),
        pause: async () => transitions.push('pause'),
        resume: async () => transitions.push('resume'),
        stop: async () => transitions.push('stop'),
      };
      tasks.set(tid, task);
      return task;
    },
    async remove(tid) {
      removed.push(tid);
      tasks.delete(tid);
    },
  };
  function stat(path) {
    if (!files.has(path)) throw Error('missing file');
    return { size: files.get(path).length };
  }
  const fs = {
    OpenMode: { READ_ONLY: 0 },
    mkdir: async () => {},
    listFile: async () => [...files.keys()].map(path => path.split('/').at(-1)),
    unlink: async (path) => files.delete(path),
    rename: async (from, to) => {
      files.set(to, files.get(from));
      files.delete(from);
    },
    stat: async path => stat(path),
    statSync: stat,
    open: async (path) => ({ fd: path }),
    read: async (fd, out) => {
      const data = files.get(fd).subarray(0, out.byteLength);
      new Uint8Array(out).set(data);
      return data.length;
    },
    close: async () => {},
  };
  const { Downloads, DOWNLOAD_MAX_BYTES } = load({ agent }, fs, () => false);
  const status = [];
  const manager = new Downloads(context, update => status.push(update));
  return { manager, Downloads, DOWNLOAD_MAX_BYTES, requests, files, removed, transitions, status };
}

test('source ZIP uses an official sandbox-only transfer with safe naming and picker fallback', async () => {
  const m = fake(t => {
    t.reply(200); // Codeload can omit Content-Length.
    t.progress(10);
    t.complete(zip);
  });
  await m.manager.start(m.Downloads.sourceZip('owner/repo', 'feature/测试'));
  assert.equal(m.requests[0].url, 'https://codeload.github.com/owner/repo/zip/feature%2F%E6%B5%8B%E8%AF%95');
  assert.equal(m.requests[0].redirect, false);
  assert.equal(m.requests[0].ends, undefined);
  assert.deepEqual(m.requests[0].headers, { 'Accept-Encoding': 'identity' });
  assert.deepEqual(m.status.map(s => s.phase), ['starting', 'downloading', 'completed']);
  assert.match(m.manager.status().name, /^[\w-]+\.zip$/);
  assert.equal(m.status[1].totalBytes, -1);
  assert.equal(m.manager.status().totalBytes, zip.length);
  assert.equal(await m.manager.exportFile(), false);
  assert.deepEqual([...m.files.keys()], [saved]);
  assert.deepEqual(m.removed, ['1']);
});

test('rejects invalid source inputs and oversized release metadata before native creation', async () => {
  const m = fake(() => assert.fail('unexpected network request'));
  for (const slug of ['https://example.com/owner/repo', 'owner/..', 'owner/repo\n']) {
    await assert.rejects(m.manager.start(m.Downloads.sourceZip(slug, 'HEAD')));
  }
  for (const ref of ['', '/HEAD', '../main', 'feature/./zip']) {
    await assert.rejects(m.manager.start(m.Downloads.sourceZip('owner/repo', ref)));
  }
  await assert.rejects(m.manager.start(m.Downloads.releaseAsset('owner/repo', 'v1', '../a', 4)));
  await assert.rejects(m.manager.start(m.Downloads.releaseAsset('owner/repo', 'v1', 'a', m.DOWNLOAD_MAX_BYTES + 1)));
  assert.equal(m.requests.length, 0);
});

test('release only follows a checked GitHub CDN hop and validates the complete range', async () => {
  const body = Uint8Array.of(1, 2, 3);
  const url = 'https://release-assets.githubusercontent.com/signed?example=redacted';
  const m = fake((t, n) => {
    if (n === 1) {
      t.reply(302, [['Location', [url]]]);
    } else {
      t.reply(206, [['Content-Range', ['bytes 0-2/3']], ['Content-Length', ['3']]]);
      t.complete(body);
    }
  });
  await m.manager.start(m.Downloads.releaseAsset('owner/repo', 'v/1', '日本.bin', body.length));
  assert.equal(m.manager.status().phase, 'completed');
  assert.match(m.manager.status().name, /\.bin$/);
  assert.equal(m.requests[0].url, 'https://github.com/owner/repo/releases/download/v%2F1/%E6%97%A5%E6%9C%AC.bin');
  assert.equal(m.requests[1].url, url);
  assert.ok(m.requests.every(r => r.redirect === false && r.ends === 2));
  assert.deepEqual(m.files.get(saved), body);

  const rejected = fake(t => t.reply(302, [['Location', ['https://release-assets.githubusercontent.com.attacker.test/x']]]));
  await rejected.manager.start(rejected.Downloads.releaseAsset('owner/repo', 'v1', 'x.bin', 3));
  assert.equal(rejected.manager.status().phase, 'failed');
  assert.equal(rejected.requests.length, 1);
  assert.equal(rejected.files.size, 0);
});

test('rejects oversized or invalid content and removes partial files', async () => {
  const m = fake((t, n) => {
    t.reply(200);
    if (n === 1) {
      t.progress(33 * 1024 * 1024);
    }
    t.complete(Uint8Array.of(1, 2, 3, 4));
  });
  await m.manager.start(m.Downloads.sourceZip('owner/repo', 'HEAD'));
  assert.equal(m.manager.status().phase, 'failed');
  assert.match(m.manager.status().message, /大小上限/);
  assert.equal(m.files.size, 0);
  await m.manager.retry();
  assert.equal(m.manager.status().phase, 'failed');
  assert.match(m.manager.status().message, /ZIP/);
  assert.equal(m.files.size, 0);
});

test('uses native pause and resume, cancels and retries with a fresh task', async () => {
  let begin;
  const started = new Promise(resolve => { begin = resolve; });
  const m = fake((t, n) => {
    t.reply(200);
    t.progress(5);
    if (n === 1) begin();
    else t.complete(zip);
  });
  const first = m.manager.start(m.Downloads.sourceZip('owner/repo', 'HEAD'));
  await started;
  await assert.rejects(m.manager.speedTest());
  await m.manager.pause();
  assert.equal(m.manager.status().phase, 'paused');
  await m.manager.resume();
  assert.equal(m.manager.status().phase, 'downloading');
  await m.manager.cancel();
  await first;
  assert.equal(m.manager.status().phase, 'cancelled');
  assert.deepEqual(m.transitions, ['pause', 'resume']);
  assert.equal(m.files.size, 0);
  await m.manager.retry();
  assert.equal(m.manager.status().phase, 'completed');
  assert.deepEqual(m.removed, ['1', '2']);
});

test('official speed test is default; explicit mirror is anonymous, bounded and does not redirect', async () => {
  const m = fake((t, n) => {
    if (n < 3) {
      t.reply(206, [['content-range', ['bytes 0-3/4']], ['content-length', ['4']]]);
      t.complete(new Uint8Array(4));
    } else {
      t.reply(302, [['location', ['https://other.example/sample']]]);
    }
  });
  const official = await m.manager.speedTest();
  assert.equal(official.source, 'raw.githubusercontent.com');
  assert.equal(official.bytes, 4);
  assert.ok(official.bytesPerSecond > 0);
  for (const bad of ['http://mirror.example/a', 'https://user:token@mirror.example/a',
    'https://mirror.example/file?token=1', 'https://127.0.0.1/a', 'https://mirror.example:443/a']) {
    await assert.rejects(m.manager.speedTest(bad));
  }
  assert.equal(m.requests.length, 1);
  assert.equal((await m.manager.speedTest('https://mirror.example/file.bin')).source, 'mirror.example');
  await assert.rejects(m.manager.speedTest('https://mirror.example/file.bin'));
  assert.equal(m.requests.length, 3);
  assert.ok(m.requests.every(r => r.ends === 256 * 1024 - 1 && r.redirect === false));
  assert.ok(m.requests.every(r => Object.keys(r.headers).every(key => key !== 'Authorization' && key !== 'Cookie')));
  assert.equal(m.files.size, 0);
});
