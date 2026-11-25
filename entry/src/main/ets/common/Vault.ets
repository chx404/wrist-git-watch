import lazy { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import type { BusinessError } from '@kit.BasicServicesKit';
import { calculateTotp, parseTotpInput, validTotpMetadata } from './Totp';
import type { TotpAccount, TotpCode, TotpMetadata } from './Totp';

export type { TotpAccount, TotpCode } from './Totp';

const TOKEN_ALIAS = 'wristgit.pat.v1';
const TOTP_PREFIX = 'wristgit.totp.v1:';
const TOTP_KIND = 'wristgit.totp.v1';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const TOKEN_FORMAT = /^[\x21-\x7e]{1,1024}$/;
const NOT_FOUND = 24000002;
const PAGE = 20;
const MAX_ASSET_BYTES = 1024;
const UNAVAILABLE = '此设备的系统安全存储（Asset）不可用，不会以明文保存';
const INVALID_RECORD = '本地安全存储中的记录无效';

function ensureAsset(): void {
  try {
    // Do not load the optional native module on devices without this capability.
    if (canIUse('SystemCapability.Security.Asset') && typeof asset.add === 'function' &&
        typeof asset.query === 'function' && typeof asset.remove === 'function') {
      return;
    }
  } catch (_) {
    // Treat loader failures like a missing service rather than falling back.
  }
  throw new Error(UNAVAILABLE);
}

function assetError(code: number | undefined): Error {
  if (code === 801 || code === 24000001 || code === 24000017 || code === undefined) {
    return new Error(UNAVAILABLE);
  }
  if (code === 24000004 || code === 24000005) {
    return new Error('无法访问系统安全存储，请解锁手表后重试');
  }
  if (code === 24000007) {
    return new Error(INVALID_RECORD);
  }
  return new Error('系统安全存储操作失败');
}

function utf8(value: string): Uint8Array {
  try {
    return new util.TextEncoder().encodeInto(value);
  } catch (_) {
    throw new Error('无法编码本地安全存储记录');
  }
}

function newId(): string {
  try {
    return util.generateRandomUUID(false);
  } catch (_) {
    throw new Error('无法创建本地 TOTP 账户 ID');
  }
}

function asText(value: Uint8Array): string {
  try {
    return util.TextDecoder.create('utf-8', { ignoreBOM: true, fatal: true }).decodeToString(value);
  } catch (_) {
    throw new Error(INVALID_RECORD);
  }
}

function bytesOf(row: asset.AssetMap, tag: asset.Tag): Uint8Array {
  const value = row.get(tag);
  if (!(value instanceof Uint8Array) || value.length === 0) {
    throw new Error(INVALID_RECORD);
  }
  return value;
}

function byAlias(name: string): asset.AssetMap {
  const values: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  values.set(asset.Tag.ALIAS, utf8(name));
  return values;
}

function totpAlias(id: string): string {
  if (!UUID.test(id)) {
    throw new Error('TOTP 账户 ID 无效');
  }
  return TOTP_PREFIX + id;
}

async function queryRows(query: asset.AssetMap): Promise<asset.AssetMap[]> {
  try {
    return await asset.query(query);
  } catch (error) {
    const code = (error as BusinessError | undefined)?.code;
    if (code === NOT_FOUND) {
      return [];
    }
    throw assetError(code);
  }
}

async function readSecret(alias: string): Promise<Uint8Array | undefined> {
  const query = byAlias(alias);
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  const rows = await queryRows(query);
  if (rows.length === 0) {
    return undefined;
  }
  if (rows.length !== 1) {
    throw new Error(INVALID_RECORD);
  }
  return bytesOf(rows[0], asset.Tag.SECRET);
}

async function remove(alias: string): Promise<void> {
  try {
    await asset.remove(byAlias(alias));
  } catch (error) {
    const code = (error as BusinessError | undefined)?.code;
    if (code !== NOT_FOUND) {
      throw assetError(code);
    }
  }
}

async function store(alias: string, secret: Uint8Array, overwrite: boolean, totp: boolean): Promise<void> {
  const row = byAlias(alias);
  row.set(asset.Tag.SECRET, secret);
  row.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
  row.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
  // No IS_PERSISTENT, grouping, authentication session or backup/export support.
  row.set(asset.Tag.CONFLICT_RESOLUTION, overwrite ? asset.ConflictResolution.OVERWRITE : asset.ConflictResolution.THROW_ERROR);
  if (totp) {
    row.set(asset.Tag.DATA_LABEL_CRITICAL_1, utf8(TOTP_KIND));
  }
  try {
    await asset.add(row);
  } catch (error) {
    throw assetError((error as BusinessError | undefined)?.code);
  }
}

// Keep names/issuers inside the protected SECRET, not in Asset's normal attributes.
// Format: [version=1][metadata size, uint16 BE][UTF-8 metadata JSON][raw seed].
function encodeTotp(metadata: TotpMetadata, seed: Uint8Array): Uint8Array {
  const header = utf8(JSON.stringify(metadata));
  const size = 3 + header.length + seed.length;
  if (size > MAX_ASSET_BYTES) {
    throw new Error('TOTP 记录超出系统安全存储长度限制');
  }
  const bytes = new Uint8Array(size);
  bytes[0] = 1;
  bytes[1] = header.length >> 8;
  bytes[2] = header.length & 255;
  bytes.set(header, 3);
  bytes.set(seed, 3 + header.length);
  return bytes;
}

function seedOffset(record: Uint8Array): number {
  if (record.length < 5 || record.length > MAX_ASSET_BYTES || record[0] !== 1) {
    throw new Error(INVALID_RECORD);
  }
  const offset = 3 + ((record[1] << 8) | record[2]);
  if (offset <= 3 || offset >= record.length) {
    throw new Error(INVALID_RECORD);
  }
  return offset;
}

function readMetadata(record: Uint8Array, offset: number): TotpMetadata {
  try {
    const metadata = JSON.parse(asText(record.subarray(3, offset))) as TotpMetadata;
    if (metadata !== null && validTotpMetadata(metadata)) {
      return metadata;
    }
  } catch (_) {
    // JSON and decoder errors may include their input; never propagate them.
  }
  throw new Error(INVALID_RECORD);
}

export class Vault {
  static async loadToken(): Promise<string> {
    ensureAsset();
    const data = await readSecret(TOKEN_ALIAS);
    if (data === undefined) {
      return '';
    }
    try {
      const token = asText(data);
      if (!TOKEN_FORMAT.test(token)) {
        throw new Error(INVALID_RECORD);
      }
      return token;
    } finally {
      data.fill(0);
    }
  }

  static async saveToken(token: string): Promise<void> {
    ensureAsset();
    const value = token.trim();
    if (!TOKEN_FORMAT.test(value)) {
      throw new Error('请输入有效的 GitHub 令牌');
    }
    const bytes = utf8(value);
    try {
      await store(TOKEN_ALIAS, bytes, true, false);
    } finally {
      bytes.fill(0);
    }
  }

  static async clearToken(): Promise<void> {
    ensureAsset();
    await remove(TOKEN_ALIAS);
  }

  static async listTotp(): Promise<TotpAccount[]> {
    ensureAsset();
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.DATA_LABEL_CRITICAL_1, utf8(TOTP_KIND));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    query.set(asset.Tag.RETURN_LIMIT, PAGE);
    const accounts: TotpAccount[] = [];
    const seen = new Set<string>();
    for (let offset = 0; offset <= 65536; offset += PAGE) {
      if (offset > 0) {
        query.set(asset.Tag.RETURN_OFFSET, offset);
      }
      const rows = await queryRows(query);
      for (const row of rows) {
        const alias = asText(bytesOf(row, asset.Tag.ALIAS));
        const id = alias.slice(TOTP_PREFIX.length);
        if (alias !== totpAlias(id)) {
          throw new Error(INVALID_RECORD);
        }
        if (seen.has(id)) {
          continue;
        }
        seen.add(id);
        // Only the opaque aliases are enumerable. Decrypt each record to read its
        // metadata, never decode the seed for listing, and promptly zero the buffer.
        const data = await readSecret(alias);
        if (data !== undefined) {
          try {
            const metadata = readMetadata(data, seedOffset(data));
            accounts.push({ id, label: metadata.label, issuer: metadata.issuer,
              algorithm: metadata.algorithm, digits: metadata.digits, period: metadata.period });
          } finally {
            data.fill(0);
          }
        }
      }
      if (rows.length < PAGE) {
        return accounts;
      }
    }
    throw new Error('本地 TOTP 记录过多，无法浏览');
  }

  static async saveTotp(label: string, input: string): Promise<void> {
    ensureAsset();
    const entry = parseTotpInput(label, input);
    let data: Uint8Array | undefined;
    try {
      const id = newId();
      data = encodeTotp(entry.metadata, entry.secret);
      await store(totpAlias(id), data, false, true);
    } finally {
      entry.secret.fill(0);
      if (data !== undefined) {
        data.fill(0);
      }
    }
  }

  static async codeFor(id: string, nowMs: number): Promise<TotpCode> {
    ensureAsset();
    const data = await readSecret(totpAlias(id));
    if (data === undefined) {
      throw new Error('本地 TOTP 账户不存在');
    }
    try {
      const offset = seedOffset(data);
      return calculateTotp(data.subarray(offset), readMetadata(data, offset), nowMs);
    } finally {
      data.fill(0);
    }
  }

  static async removeTotp(id: string): Promise<void> {
    ensureAsset();
    await remove(totpAlias(id));
  }
}
