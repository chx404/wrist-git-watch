import lazy { http } from '@kit.NetworkKit';

// OAuth 2.0 Device Authorization Grant (RFC 8628) against github.com.
// The watch shows a user code; the phone scans a QR that opens the
// verification page; the watch polls until GitHub issues a token.

// GitHub CLI's public OAuth client id, widely embedded by community tools so
// that the device flow works without asking every user to register an app.
// Advanced users may replace it with their own OAuth app client id.
export const DEVICE_CLIENT_ID: string = '178c6fc778ccc68e1d6a';
export const DEVICE_SCOPE: string = 'repo user notifications';

export interface DeviceSession {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  expiresIn: number;
  interval: number;
}

export class DeviceAuthError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

interface DeviceCodeResponse {
  device_code: string;
  user_code: string;
  verification_uri: string;
  expires_in: number;
  interval: number;
}

interface TokenResponse {
  access_token?: string;
  error?: string;
  interval?: number;
}

function formEncode(pairs: string[][]): string {
  const parts: string[] = [];
  for (const pair of pairs) {
    parts.push(encodeURIComponent(pair[0]) + '=' + encodeURIComponent(pair[1]));
  }
  return parts.join('&');
}

async function postForm(path: string, pairs: string[][]): Promise<string> {
  if (!canIUse('SystemCapability.Communication.NetStack')) {
    throw new DeviceAuthError('offline', '这块手表未提供联网能力');
  }
  const client = http.createHttp();
  try {
    const reply = await client.request(`https://github.com${path}`, {
      method: http.RequestMethod.POST,
      header: { 'Accept': 'application/json', 'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'WristGit-Harmony/0.3' },
      extraData: formEncode(pairs),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000,
      readTimeout: 10000,
      maxLimit: 64 * 1024
    });
    if (reply.responseCode !== 200 || typeof reply.result !== 'string') {
      throw new DeviceAuthError('http', `GitHub 授权服务返回 ${reply.responseCode}`);
    }
    return reply.result;
  } finally {
    client.destroy();
  }
}

function parseJson(text: string): Object {
  try {
    const value = JSON.parse(text) as Object;
    if (value === null || typeof value !== 'object') {
      throw new Error('bad shape');
    }
    return value;
  } catch (_) {
    throw new DeviceAuthError('json', 'GitHub 授权响应格式无效');
  }
}

export class DeviceAuth {
  static verificationUrl(userCode: string): string {
    return `https://github.com/login/device?user_code=${encodeURIComponent(userCode)}`;
  }

  static async start(clientId: string, scope: string): Promise<DeviceSession> {
    if (!/^[A-Za-z0-9]{10,40}$/.test(clientId)) {
      throw new DeviceAuthError('client', 'OAuth Client ID 无效');
    }
    const body = parseJson(await postForm('/login/device/code',
      [['client_id', clientId], ['scope', scope]])) as DeviceCodeResponse;
    const userCode = body.user_code ?? '';
    const deviceCode = body.device_code ?? '';
    const uri = body.verification_uri ?? '';
    if (!/^[A-Z0-9]{4,9}-[A-Z0-9]{4,9}$/.test(userCode) || !/^[A-Za-z0-9_-]{20,200}$/.test(deviceCode) ||
      !/^https:\/\/github\.com\/login\/device$/.test(uri)) {
      throw new DeviceAuthError('session', 'GitHub 返回的验证码无效');
    }
    const expiresIn = Math.max(60, Math.min(1800, body.expires_in ?? 900));
    const interval = Math.max(3, Math.min(60, body.interval ?? 5));
    return { deviceCode, userCode, verificationUri: uri, expiresIn, interval };
  }

  // Polls until GitHub grants a token. `active` lets the caller stop the
  // loop (screen changed, user cancelled); `tick` reports visible states.
  static async poll(session: DeviceSession, clientId: string,
    active: () => boolean, tick: (state: string) => void,
    sleep?: (ms: number) => Promise<void>): Promise<string> {
    const wait = sleep ?? ((ms: number) => new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    }));
    const started = Date.now();
    const deadline = started + session.expiresIn * 1000 + 30 * 1000;
    let interval = session.interval;
    for (;;) {
      if (!active()) {
        throw new DeviceAuthError('cancelled', '已取消扫码连接');
      }
      if (Date.now() > deadline) {
        throw new DeviceAuthError('expired', '验证码已过期，请重新生成');
      }
      const body = parseJson(await postForm('/login/oauth/access_token',
        [['client_id', clientId], ['device_code', session.deviceCode],
        ['grant_type', 'urn:ietf:params:oauth:grant-type:device_code']])) as TokenResponse;
      if (typeof body.access_token === 'string' && body.access_token.length >= 20) {
        return body.access_token;
      }
      const error = body.error ?? 'unknown';
      if (error === 'authorization_pending') {
        tick('等待在手机上确认授权…');
      } else if (error === 'slow_down') {
        interval += 5;
        tick('请求过快，已自动放慢轮询…');
      } else if (error === 'expired_token') {
        throw new DeviceAuthError('expired', '验证码已过期，请重新生成');
      } else if (error === 'access_denied') {
        throw new DeviceAuthError('denied', '授权被取消，未保存任何令牌');
      } else {
        throw new DeviceAuthError(error, 'GitHub 无法完成授权');
      }
      await wait(interval * 1000);
    }
  }
}
