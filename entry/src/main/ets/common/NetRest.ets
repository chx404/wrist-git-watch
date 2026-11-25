import { http } from '@kit.NetworkKit';
import { patchThread } from './NetPatch';

export const API_ORIGIN: string = 'https://api.github.com';
const REQUEST_TIMEOUT: number = 8500;
const CONNECT_TIMEOUT: number = 4200;
const MAX_BODY: number = 2 * 1024 * 1024;
const CACHE_ENTRIES: number = 24;
const CACHE_VALUE_CHARS: number = 64 * 1024;
const CACHE_MS: number = 25000;
const SECONDARY_LIMIT_MS: number = 60000;
const USER_AGENT: string = 'WristGit-Harmony/0.2';

export class GitHubError extends Error {
  status: number;
  retryAt: number;
  constructor(status: number, message: string, retryAt: number = 0) {
    super(message);
    this.status = status;
    this.retryAt = retryAt;
  }
}

export enum NetMethod {
  POST,
  PUT,
  DELETE,
  PATCH
}

interface RestReply {
  status: number;
  body: string;
  headers: Record<string, string>;
}

interface CacheEntry {
  reply: RestReply;
  expires: number;
}

class RateState {
  coreUntil: number = 0;
  searchUntil: number = 0;
  secondaryUntil: number = 0;
}

interface NativeFailure {
  code?: number;
}

class NetworkFailure extends GitHubError {
  transient: boolean;
  constructor(transient: boolean) {
    super(0, '连接 GitHub 失败，请检查网络后重试');
    this.transient = transient;
  }
}

export class NetRest {
  private static token: string = '';
  private static identity: number = 0;
  private static epoch: number = 0;
  private static cache: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  private static pending: Map<string, Promise<RestReply>> = new Map<string, Promise<RestReply>>();
  private static publicRate: RateState = new RateState();
  private static authRate: RateState = new RateState();
  // Candidate validation is never cached or shared with normal reads. Its cooldown
  // is retained across validation attempts, including attempts with uninstalled PATs.
  private static validationRate: RateState = new RateState();
  private static writes: number = 0;

  static clearCache(): void {
    NetRest.epoch++;
    NetRest.cache.clear();
    NetRest.pending.clear();
  }

  private static cleanToken(value: string): string {
    const token = value.trim();
    if (token && !/^[A-Za-z0-9_]{1,512}$/.test(token)) {
      throw new GitHubError(401, 'GitHub 令牌格式无效');
    }
    return token;
  }

  static setToken(value: string): void {
    const token = NetRest.cleanToken(value);
    if (token !== NetRest.token) {
      NetRest.token = token;
      NetRest.identity++;
      NetRest.authRate = new RateState();
      NetRest.clearCache();
    }
  }

  private static requireToken(token: string): void {
    if (!token) {
      throw new GitHubError(401, '请先在设置中添加 GitHub 令牌');
    }
  }

  static async validateToken(value: string): Promise<string> {
    const token = NetRest.cleanToken(value);
    NetRest.requireToken(token);
    const rate = token === NetRest.token ? NetRest.authRate : NetRest.validationRate;
    const reply = await NetRest.fetchGet('/user', false, token, rate);
    NetRest.check(reply, [200]);
    return reply.body;
  }

  static async get(path: string, raw: boolean, requiresAuth: boolean = false): Promise<string> {
    const reply = await NetRest.read(path, raw, requiresAuth, [200]);
    return reply.body;
  }

  static async status(path: string, accepted: number[]): Promise<number> {
    const reply = await NetRest.read(path, false, true, accepted);
    return reply.status;
  }

  static async read(path: string, raw: boolean, requiresAuth: boolean, accepted: number[]): Promise<RestReply> {
    const token = NetRest.token;
    if (requiresAuth) {
      NetRest.requireToken(token);
    }
    const identity = NetRest.identity;
    const epoch = NetRest.epoch;
    const key = `${identity}:${raw ? 'raw' : 'json'}:${path}`;
    const cached = NetRest.cache.get(key);
    if (cached) {
      NetRest.cache.delete(key);
      if (cached.expires > Date.now()) {
        NetRest.cache.set(key, cached);
        NetRest.check(cached.reply, accepted);
        return cached.reply;
      }
    }
    let pending = NetRest.pending.get(key);
    const startsRequest = pending === undefined;
    if (pending === undefined) {
      const rate = token ? NetRest.authRate : NetRest.publicRate;
      pending = NetRest.fetchGet(path, raw, token, rate, identity, epoch);
      NetRest.pending.set(key, pending);
    }
    try {
      const reply = await pending;
      NetRest.checkGeneration(identity, epoch);
      NetRest.check(reply, accepted);
      if (startsRequest && NetRest.writes === 0 && (reply.status === 200 || reply.status === 204) &&
        reply.body.length <= CACHE_VALUE_CHARS) {
        NetRest.save(key, reply);
      }
      return reply;
    } finally {
      if (startsRequest && NetRest.pending.get(key) === pending) {
        NetRest.pending.delete(key);
      }
    }
  }

  private static checkGeneration(identity: number, epoch: number): void {
    if (identity !== NetRest.identity || epoch !== NetRest.epoch) {
      throw new GitHubError(0, 'GitHub 账户或数据已变更，请刷新');
    }
  }

  private static save(key: string, reply: RestReply): void {
    const control = NetRest.header(reply, 'cache-control').toLowerCase();
    if (/(?:^|,)\s*(?:no-store|no-cache)\b/.test(control) || NetRest.header(reply, 'vary').trim() === '*') {
      return;
    }
    const maxAge = /(?:^|,)\s*max-age\s*=\s*"?([0-9]+)/.exec(control);
    const age = NetRest.header(reply, 'age');
    const remaining = maxAge ? (Number(maxAge[1]) - (/^\d+$/.test(age) ? Number(age) : 0)) * 1000 : CACHE_MS;
    const ttl = Math.min(CACHE_MS, remaining);
    if (ttl <= 0) {
      return;
    }
    if (NetRest.cache.size >= CACHE_ENTRIES) {
      const oldest = NetRest.cache.keys().next();
      if (!oldest.done) {
        NetRest.cache.delete(oldest.value);
      }
    }
    NetRest.cache.set(key, { reply: reply, expires: Date.now() + ttl });
  }

  static async write(path: string, method: NetMethod, accepted: number[], body?: string): Promise<RestReply> {
    const token = NetRest.token;
    NetRest.requireToken(token);
    const rate = NetRest.authRate;
    NetRest.enforceRate(rate, path);
    NetRest.writes++;
    NetRest.clearCache();
    try {
      let reply: RestReply;
      if (method === NetMethod.PATCH) {
        const result = await patchThread(path, token, USER_AGENT, REQUEST_TIMEOUT);
        reply = { status: result.status, body: '', headers: result.headers };
      } else {
        const verb = method === NetMethod.POST ? http.RequestMethod.POST :
          (method === NetMethod.PUT ? http.RequestMethod.PUT : http.RequestMethod.DELETE);
        reply = await NetRest.exchange(path, verb, token, false, body);
      }
      NetRest.observeRate(rate, path, reply);
      NetRest.check(reply, accepted);
      return reply;
    } finally {
      // Invalidate even on timeout: the server could still have applied the write.
      NetRest.writes--;
      NetRest.clearCache();
    }
  }

  private static async fetchGet(path: string, raw: boolean, token: string, rate: RateState,
    identity: number = -1, epoch: number = -1): Promise<RestReply> {
    // One retry only; never wait out a server cooldown on the watch.
    for (let attempt = 0; attempt < 2; attempt++) {
      if (identity >= 0) {
        NetRest.checkGeneration(identity, epoch);
      }
      NetRest.enforceRate(rate, path);
      let reply: RestReply;
      try {
        reply = await NetRest.exchange(path, http.RequestMethod.GET, token, raw);
      } catch (error) {
        if (attempt !== 0 || !(error instanceof NetworkFailure) || !error.transient) {
          throw error as Error;
        }
        await NetRest.pause();
        continue;
      }
      NetRest.observeRate(rate, path, reply);
      if (attempt === 0 && [500, 502, 503, 504].includes(reply.status) &&
        !NetRest.header(reply, 'retry-after') && NetRest.rateUntil(rate, path) <= Date.now()) {
        await NetRest.pause();
        continue;
      }
      return reply;
    }
    throw new GitHubError(0, '连接 GitHub 失败，请检查网络后重试');
  }

  private static pause(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), 250 + Math.floor(Math.random() * 200));
    });
  }

  private static async exchange(path: string, method: http.RequestMethod, token: string, raw: boolean,
    body?: string): Promise<RestReply> {
    if (!/^\/(?!\/)[!-~]*$/.test(path) || path.includes('\\') || path.includes('#')) {
      throw new GitHubError(0, 'GitHub 请求路径无效');
    }
    const header: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': raw ? 'application/vnd.github.raw+json' : 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Cache-Control': 'no-cache, no-store'
    };
    // Use only the standard Authorization header on the exact HTTPS API origin.
    // API 18–20 NetStack uses libcurl's default origin-scoped Authorization:
    // redirected host, scheme or port changes do not carry this header.
    if (token) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const request: http.HttpRequestOptions = {
      method: method,
      header: header,
      usingCache: false,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: CONNECT_TIMEOUT,
      readTimeout: REQUEST_TIMEOUT,
      maxLimit: MAX_BODY
    };
    if (body !== undefined) {
      header['Content-Type'] = 'application/json';
      request.extraData = body;
    }
    const client = http.createHttp();
    try {
      const result = await client.request(`${API_ORIGIN}${path}`, request);
      const content = typeof result.result === 'string' ? result.result : '';
      if (content.length > MAX_BODY) {
        throw new GitHubError(0, 'GitHub 响应超过手表预览上限');
      }
      return {
        status: result.responseCode,
        body: content,
        headers: result.header as Record<string, string>
      };
    } catch (error) {
      if (error instanceof GitHubError) {
        throw error;
      }
      // Keep native errors (which may contain request data) out of user-facing errors.
      const native = error as NativeFailure;
      const code = native.code ?? 0;
      throw new NetworkFailure([2300006, 2300007, 2300016, 2300028, 2300052, 2300055, 2300056].includes(code));
    } finally {
      client.destroy();
    }
  }

  private static header(reply: RestReply, name: string): string {
    for (const key of Object.keys(reply.headers)) {
      if (key.toLowerCase() === name) {
        const value = reply.headers[key];
        return typeof value === 'string' ? value : '';
      }
    }
    return '';
  }

  private static rateUntil(state: RateState, path: string): number {
    return Math.max(state.secondaryUntil, path.startsWith('/search/') ? state.searchUntil : state.coreUntil);
  }

  private static enforceRate(state: RateState, path: string): void {
    const until = NetRest.rateUntil(state, path);
    if (until > Date.now()) {
      throw new GitHubError(429, 'GitHub 请求已限流，请稍后重试', until);
    }
  }

  private static retryAfter(reply: RestReply, now: number): number {
    const value = NetRest.header(reply, 'retry-after').trim();
    if (/^[0-9]+$/.test(value)) {
      const until = now + Number(value) * 1000;
      return Number.isFinite(until) ? until : 0;
    }
    const date = Date.parse(value);
    return Number.isFinite(date) ? date : 0;
  }

  private static observeRate(state: RateState, path: string, reply: RestReply): void {
    const now = Date.now();
    const empty = NetRest.header(reply, 'x-ratelimit-remaining').trim() === '0';
    const reset = NetRest.header(reply, 'x-ratelimit-reset').trim();
    if (empty) {
      const resetAt = /^[0-9]+$/.test(reset) ? Number(reset) * 1000 : 0;
      const until = Number.isFinite(resetAt) && resetAt > now ? resetAt : now + SECONDARY_LIMIT_MS;
      if (path.startsWith('/search/')) {
        state.searchUntil = Math.max(state.searchUntil, until);
      } else {
        state.coreUntil = Math.max(state.coreUntil, until);
      }
    }
    const retryAt = NetRest.retryAfter(reply, now);
    const secondary = reply.status === 429 || (reply.status === 403 &&
      /secondary rate limit|abuse detection|rate limit exceeded/i.test(reply.body));
    if (retryAt > now || (secondary && !empty)) {
      state.secondaryUntil = Math.max(state.secondaryUntil,
        retryAt > now ? retryAt : now + SECONDARY_LIMIT_MS);
    }
  }

  private static check(reply: RestReply, accepted: number[]): void {
    const status = reply.status;
    if (accepted.includes(status)) {
      return;
    }
    if (status === 401) {
      throw new GitHubError(status, 'GitHub 令牌无效或已过期');
    }
    if (status === 403 || status === 429) {
      const retryAt = NetRest.retryAfter(reply, Date.now());
      throw new GitHubError(status, 'GitHub 限流或权限不足，请稍后重试或检查令牌权限', retryAt);
    }
    if (status === 404) {
      throw new GitHubError(status, '此内容不存在或不公开');
    }
    if (status === 409) {
      throw new GitHubError(status, 'GitHub 请求与仓库当前状态冲突');
    }
    if (status === 422) {
      throw new GitHubError(status, 'GitHub 无法处理这个请求');
    }
    throw new GitHubError(status, `GitHub 返回异常（${status}）`);
  }
}
