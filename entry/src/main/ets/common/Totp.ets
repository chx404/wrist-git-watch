import lazy { cryptoFramework } from '@kit.CryptoArchitectureKit';

export interface TotpParameters {
  algorithm: string;
  digits: number;
  period: number;
}

export interface TotpMetadata extends TotpParameters {
  label: string;
  issuer: string;
}

export interface TotpAccount extends TotpMetadata {
  id: string;
}

export interface TotpCode {
  code: string;
  remainingSeconds: number;
  period: number;
}

export interface TotpImport {
  metadata: TotpMetadata;
  secret: Uint8Array;
}

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export const MAX_SEED_BYTES = 1024;
const MAX_INPUT = 4096;
const MAX_NAME = 100;

export function decodeBase32(input: string): Uint8Array {
  const clean = input.replace(/[ \t\r\n]/g, '');
  const err = new Error('TOTP 密钥必须是有效的 Base32');
  if (clean.length === 0 || clean.length > 1640 || !/^[A-Za-z2-7]+=*$/.test(clean)) {
    throw err;
  }
  const firstPad = clean.indexOf('=');
  const key = (firstPad < 0 ? clean : clean.slice(0, firstPad)).toUpperCase();
  const mod = key.length % 8;
  if (mod === 1 || mod === 3 || mod === 6 ||
      (firstPad >= 0 && (mod === 0 || clean.length - firstPad !== 8 - mod))) {
    throw err;
  }
  const size = Math.floor(key.length * 5 / 8);
  if (size === 0 || size > MAX_SEED_BYTES) {
    throw err;
  }
  const bytes = new Uint8Array(size);
  let pending = 0;
  let bits = 0;
  let index = 0;
  for (let i = 0; i < key.length; i++) {
    pending = (pending << 5) | BASE32.indexOf(key.charAt(i));
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes[index++] = pending >> bits;
      pending &= (1 << bits) - 1;
    }
  }
  // The unused low bits in the final Base32 symbol must be zero (RFC 4648).
  if (pending !== 0) {
    bytes.fill(0);
    throw err;
  }
  return bytes;
}

function urlDecode(input: string): string {
  try {
    return decodeURIComponent(input);
  } catch (_) {
    throw new Error('TOTP 链接中的转义字符无效');
  }
}

function queryParams(input: string): Map<string, string> {
  const values = new Map<string, string>();
  for (const pair of input.split('&')) {
    const equals = pair.indexOf('=');
    if (equals <= 0) {
      throw new Error('TOTP 链接中的参数格式无效');
    }
    const name = urlDecode(pair.slice(0, equals).replace(/\+/g, '%20')).toLowerCase();
    if (values.has(name)) {
      throw new Error('TOTP 链接中有重复参数');
    }
    values.set(name, urlDecode(pair.slice(equals + 1).replace(/\+/g, '%20')));
  }
  return values;
}

export function validTotpParameters(parameters: TotpParameters): boolean {
  const algorithm = parameters.algorithm;
  return (algorithm === 'SHA1' || algorithm === 'SHA256' || algorithm === 'SHA512') &&
    (parameters.digits === 6 || parameters.digits === 8) &&
    Number.isInteger(parameters.period) && parameters.period >= 1 && parameters.period <= 86400;
}

export function validTotpMetadata(metadata: TotpMetadata): boolean {
  return typeof metadata.label === 'string' && metadata.label.trim().length > 0 &&
    typeof metadata.issuer === 'string' && metadata.label.length <= MAX_NAME && metadata.issuer.length <= MAX_NAME &&
    !/[\u0000-\u001f\u007f]/.test(metadata.label) && !/[\u0000-\u001f\u007f]/.test(metadata.issuer) &&
    validTotpParameters(metadata);
}

export function parseTotpInput(label: string, input: string): TotpImport {
  if (input.length > MAX_INPUT) {
    throw new Error('TOTP 输入太长');
  }
  const source = input.trim();
  let display = label.trim();
  let issuer = '';
  let seed = source;
  let algorithm = 'SHA1';
  let digits = 6;
  let period = 30;
  if (source.toLowerCase().startsWith('otpauth:')) {
    const uri = /^otpauth:\/\/totp\/([^/?#]+)\?([^#]+)$/i.exec(source);
    if (uri === null) {
      throw new Error('仅支持 otpauth://totp/ 格式的 TOTP 链接');
    }
    const params = queryParams(uri[2]);
    if (params.has('counter') || params.has('encoder')) {
      throw new Error('不支持计数型或自定义编码的验证码');
    }
    const name = urlDecode(uri[1]).trim();
    const colon = name.indexOf(':');
    const account = (colon < 0 ? name : name.slice(colon + 1)).trim();
    const prefix = colon < 0 ? '' : name.slice(0, colon).trim();
    issuer = (params.get('issuer') ?? prefix).trim();
    if (account.length === 0 || (prefix.length > 0 && prefix !== issuer)) {
      throw new Error('TOTP 链接中的账户或服务名称无效');
    }
    display = display || account;
    seed = params.get('secret') ?? '';
    algorithm = (params.get('algorithm') ?? 'SHA1').toUpperCase();
    const digitText = params.get('digits') ?? '6';
    const periodText = params.get('period') ?? '30';
    if (!/^(6|8)$/.test(digitText) || !/^[1-9][0-9]{0,4}$/.test(periodText)) {
      throw new Error('TOTP 验证码位数或周期不受支持');
    }
    digits = Number(digitText);
    period = Number(periodText);
  }
  const metadata: TotpMetadata = { label: display, issuer, algorithm, digits, period };
  if (!validTotpParameters(metadata)) {
    throw new Error('TOTP 算法、验证码位数或周期不受支持');
  }
  if (!validTotpMetadata(metadata)) {
    throw new Error('请输入有效的 TOTP 账户名称（最多 100 个字符）');
  }
  return { metadata, secret: decodeBase32(seed) };
}

// RFC 4226/6238: HMAC of the 8-byte BE counter, then dynamic truncation.
export function calculateTotp(secret: Uint8Array, parameters: TotpParameters, nowMs: number): TotpCode {
  if (!validTotpParameters(parameters) || secret.length === 0 || secret.length > MAX_SEED_BYTES) {
    throw new Error('TOTP 密钥或配置无效');
  }
  if (!Number.isFinite(nowMs) || nowMs < 0 || nowMs > Number.MAX_SAFE_INTEGER) {
    throw new Error('系统时间无效，无法生成 TOTP');
  }
  const period = parameters.period;
  const nowSeconds = Math.floor(nowMs / 1000);
  let counter = Math.floor(nowSeconds / period);
  const message = new Uint8Array(8);
  // Avoid JS bitwise shifts on the whole counter, which discard all bits beyond 32.
  for (let i = message.length - 1; i >= 0; i--) {
    message[i] = counter % 256;
    counter = Math.floor(counter / 256);
  }
  let key: cryptoFramework.SymKey | undefined;
  let digest: Uint8Array | undefined;
  try {
    const generator = cryptoFramework.createSymKeyGenerator('HMAC');
    const mac = cryptoFramework.createMac(parameters.algorithm);
    key = generator.convertKeySync({ data: secret });
    mac.initSync(key);
    mac.updateSync({ data: message });
    digest = mac.doFinalSync().data;
    const expectedSize = parameters.algorithm === 'SHA1' ? 20 : (parameters.algorithm === 'SHA256' ? 32 : 64);
    if (digest.length !== expectedSize) {
      throw new Error('Invalid HMAC length');
    }
    const offset = digest[digest.length - 1] & 15;
    const integer = ((digest[offset] & 127) << 24) | (digest[offset + 1] << 16) |
      (digest[offset + 2] << 8) | digest[offset + 3];
    const digits = parameters.digits;
    const code = String(integer % Math.pow(10, digits)).padStart(digits, '0');
    return { code, remainingSeconds: period - (nowSeconds % period), period };
  } catch (_) {
    throw new Error('系统加密服务不可用，无法生成 TOTP');
  } finally {
    if (digest !== undefined) {
      digest.fill(0);
    }
    if (key !== undefined) {
      try {
        key.clearMem();
      } catch (_) {
        // Best effort; do not expose a native exception or retain a key reference.
      }
    }
  }
}
