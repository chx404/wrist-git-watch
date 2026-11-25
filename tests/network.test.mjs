import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const common = new URL('../entry/src/main/ets/common/', import.meta.url);
const source = async (file) => stripTypeScriptTypes((await readFile(new URL(`${file}.ets`, common), 'utf8'))
  .replace(/^import .*;\n|^export \{[^\n]*\}[^\n]*;\n/gm, ''), { mode: 'transform' }).replace(/^export /gm, '');
const makeNet = new Function('http', 'patchThread', 'setTimeout', (await source('NetRest')) +
  '\nreturn { NetRest, NetMethod, GitHubError, API_ORIGIN };');
const makeGitHub = new Function('NetRest', 'NetMethod', 'GitHubError', 'API_ORIGIN', 'PAGE_SIZE', 'urlPath',
  (await source('GitHub')) + '\nreturn GitHub;');
const payload = (result = '{"ok":true}', responseCode = 200, header = {}) => ({ result, responseCode, header });

function mock(responder) {
  const requests = [];
  let destroyed = 0;
  const http = {
    RequestMethod: { GET: 'GET', PUT: 'PUT', POST: 'POST', DELETE: 'DELETE' }, HttpDataType: { STRING: 'string' },
    createHttp() { return {
      request: async (url, config) => {
        const call = { url, config };
        requests.push(call);
        return responder(call, requests.length);
      },
      destroy() { destroyed++; },
    }; },
  };
  return { ...makeNet(http, async () => ({ status: 205, headers: {} }), queueMicrotask), requests, destroyed: () => destroyed };
}

function gate() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

test('coalesces identical GETs, caches successful short replies, and closes native clients', async () => {
  const pending = gate();
  const m = mock(() => pending.promise);
  const first = m.NetRest.get('/rate_limit', false);
  const second = m.NetRest.get('/rate_limit', false);
  assert.equal(m.requests.length, 1);
  pending.resolve(payload());
  assert.equal(await first, await second);
  assert.equal(await m.NetRest.get('/rate_limit', false), '{"ok":true}');
  assert.equal(m.requests.length, 1);
  assert.equal(m.destroyed(), 1);
  assert.equal(m.requests[0].url, 'https://api.github.com/rate_limit');
  assert.equal(m.requests[0].config.usingCache, false);
});

test('separates raw and JSON, obeys no-store, and never leaks one account cache into another', async () => {
  const m = mock(({ config }) => payload(config.header.Authorization || config.header.Accept));
  assert.equal(await m.NetRest.get('/repos/o/r/readme', true), 'application/vnd.github.raw+json');
  assert.equal(await m.NetRest.get('/repos/o/r/readme', false), 'application/vnd.github+json');
  m.NetRest.setToken('account_one');
  assert.equal(await m.NetRest.get('/user', false), 'Bearer account_one');
  m.NetRest.setToken('account_two');
  assert.equal(await m.NetRest.get('/user', false), 'Bearer account_two');
  m.NetRest.setToken('');
  assert.equal(await m.NetRest.get('/user', false), 'application/vnd.github+json');
  const n = mock(() => payload('not stored', 200, { 'Cache-Control': 'private, no-store' }));
  await n.NetRest.get('/notifications', false);
  await n.NetRest.get('/notifications', false);
  assert.equal(n.requests.length, 2);
});

test('candidate validation does not install the candidate or reuse account data', async () => {
  const m = mock(({ config }) => payload(config.header.Authorization || 'guest'));
  m.NetRest.setToken('saved_token');
  assert.equal(await m.NetRest.validateToken('candidate_token'), 'Bearer candidate_token');
  assert.equal(await m.NetRest.get('/user', false, true), 'Bearer saved_token');
  assert.equal(m.requests.length, 2);
  await assert.rejects(m.NetRest.validateToken('invalid\r\nAuthorization: forged'));
  await assert.rejects(m.NetRest.get('//non-github.example/request', false));
  assert.equal(m.requests.length, 2);
});

test('retries transient GETs once, never retries mutations, and invalidates cached reads on writes', async () => {
  const m = mock(({ config }, n) => {
    if (n === 1) { throw { code: 2300028 }; }
    if (config.method === 'PUT') return payload('', 503);
    return payload(`reply${n}`);
  });
  m.NetRest.setToken('test_token');
  assert.equal(await m.NetRest.get('/user/starred', false), 'reply2');
  assert.equal(await m.NetRest.get('/user/starred', false), 'reply2');
  await assert.rejects(m.NetRest.write('/user/starred/o/r', m.NetMethod.PUT, [204], '{}'), { status: 503 });
  assert.equal(m.requests.length, 3);
  assert.equal(await m.NetRest.get('/user/starred', false), 'reply4');
  assert.equal(m.destroyed(), 4);
});

test('does not complete or cache a stale read after the active account changes', async () => {
  const pending = gate();
  const m = mock((_request, n) => n === 1 ? pending.promise : payload('new'));
  m.NetRest.setToken('old_token');
  const old = m.NetRest.get('/user', false, true);
  m.NetRest.setToken('new_token');
  pending.resolve(payload('old'));
  await assert.rejects(old, /已变更/);
  assert.equal(await m.NetRest.get('/user', false, true), 'new');
});

test('honors Retry-After without replaying and isolates search primary rate limit', async () => {
  const n = mock(() => payload('{}', 429, { 'Retry-After': '60' }));
  await assert.rejects(n.NetRest.get('/user', false), error => error.status === 429 && error.retryAt > Date.now());
  await assert.rejects(n.NetRest.get('/repos/o/r', false), { status: 429 });
  assert.equal(n.requests.length, 1);
  const m = mock(({ url }, calls) => url.includes('/search/')
    ? payload('{}', 403, { 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': String(Math.floor(Date.now() / 1000) + 60) })
    : payload(`core ${calls}`));
  await assert.rejects(m.NetRest.get('/search/repositories?q=e', false), { status: 403 });
  await assert.rejects(m.NetRest.get('/search/repositories?q=f', false), { status: 429 });
  assert.equal(await m.NetRest.get('/repos/o/r', false), 'core 2');
});

test('recognizes a GitHub notification target and only follows comment paths in the same repository', () => {
  const n = mock(() => payload());
  const GitHub = makeGitHub(n.NetRest, n.NetMethod, n.GitHubError, n.API_ORIGIN, 10, path => path.split('/').map(encodeURIComponent).join('/'));
  const notice = { id: '25', unread: true, reason: 'mention', repository: { id: 123, full_name: 'Some/Repo' },
    subject: { type: 'PullRequest', title: 'a PR', url: 'https://api.github.com/repos/Some/Repo/pulls/43',
      latest_comment_url: 'https://api.github.com/repositories/123/pulls/comments/846' } };
  assert.equal(GitHub.notificationJump(notice).number, 43);
  assert.equal(GitHub.notificationJump(notice).webUrl, 'https://github.com/Some/Repo/pull/43');
  assert.equal(GitHub.noticeCommentPath(notice), '/repos/Some/Repo/pulls/comments/846');
  notice.subject.latest_comment_url = 'https://api.github.com/repositories/124/pulls/comments/846';
  assert.equal(GitHub.noticeCommentPath(notice), '');
  notice.subject.latest_comment_url = 'https://example.com/repos/Some/Repo/pulls/comments/846';
  assert.equal(GitHub.noticeCommentPath(notice), '');
  assert.equal(n.requests.length, 0);
});

test('single-thread PATCH does not send a token before verified TLS and parses a split response', async () => {
  const makePatch = new Function('socket', 'cert', (await source('NetPatch')) + '\nreturn patchThread;');
  const calls = [];
  let validHost = false;
  const socket = { constructTLSSocketInstance() {
    const events = new Map();
    return {
      on: (event, fn) => events.set(event, fn),
      async bind() {},
      async connect(args) { calls.push(args); },
      async getRemoteCertificate() { return {}; },
      async send(request) {
        calls.push(request);
        for (const part of ['HTTP/1.1 20', '5 Reset Content\r\n', 'X-RateLimit-Remaining: 20\r\n\r\n']) {
          events.get('message')({ message: new TextEncoder().encode(part).buffer });
        }
      },
      async close() {},
    };
  } };
  const cert = { GeneralNameType: { GENERAL_NAME_TYPE_DNS_NAME: 2 },
    async createX509Cert() { return { match: () => validHost }; } };
  const patch = makePatch(socket, cert);
  await assert.rejects(patch('/notifications/threads/7', 'dummy_test', 'WristGit', 500));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].skipRemoteValidation, false);
  validHost = true;
  const reply = await patch('/notifications/threads/7', 'dummy_test', 'WristGit', 500);
  assert.equal(reply.status, 205);
  assert.equal(reply.headers['x-ratelimit-remaining'], '20');
  assert.match(calls.at(-1), /^PATCH \/notifications\/threads\/7 HTTP\/1\.1\r\nHost: api\.github\.com\r\n/);
  await assert.rejects(patch('/notifications/../../user', 'dummy_test', 'WristGit', 500));
  assert.equal(calls.length, 3);
});
