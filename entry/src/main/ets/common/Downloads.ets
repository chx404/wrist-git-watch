import type { common } from '@kit.AbilityKit';
import lazy { request } from '@kit.BasicServicesKit';
import lazy { fileIo as fs } from '@kit.CoreFileKit';

export const DOWNLOAD_MAX_BYTES: number = 32 * 1024 * 1024;
const SPEED_BYTES: number = 256 * 1024;
const OFFICIAL_TEST: string = 'https://raw.githubusercontent.com/torvalds/linux/master/MAINTAINERS';
const WATCH_INTERVAL_MS: number = 400;
const TRANSFER_TIMEOUT_MS: number = 180000;
const SPEED_TIMEOUT_MS: number = 12000;

export type DownloadPhase = 'idle' | 'starting' | 'downloading' | 'paused' | 'cancelling' |
  'completed' | 'failed' | 'cancelled';

export interface DownloadSpec {
  readonly kind: 'source' | 'asset';
  readonly slug: string;
  readonly ref: string;
  readonly assetName?: string;
  readonly size?: number;
}

export interface DownloadStatus {
  readonly phase: DownloadPhase;
  readonly name: string;
  readonly receivedBytes: number;
  readonly totalBytes: number; // -1 if unknown
  readonly message: string;
}

export interface DownloadSpeedResult {
  readonly source: string; // hostname
  readonly bytes: number;
  readonly elapsedMs: number;
  readonly bytesPerSecond: number;
}

class DownloadError extends Error {}

interface DownloadTarget {
  url: string;
  name: string;
  expected: number;
}

function repoSlug(slug: string): string {
  if (!/^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\/[a-z0-9_.-]{1,100}$/i.test(slug) ||
    /\/(?:\.{1,2}|\.git)$/i.test(slug)) {
    throw new DownloadError('GitHub 仓库名无效');
  }
  return slug;
}

function encodedRef(ref: string): string {
  if (ref.length === 0 || ref.length > 240 || /[\x00-\x20\x7f\\]/.test(ref) ||
    ref.split('/').some((part: string): boolean => part === '' || part === '.' || part === '..')) {
    throw new DownloadError('版本名称无效');
  }
  try {
    return encodeURIComponent(ref);
  } catch (_) {
    throw new DownloadError('版本名称无效');
  }
}

function safeFilename(name: string): string {
  let result = name.replace(/[^a-z0-9._-]+/gi, '_').replace(/^[.]+|[.]+$/g, '');
  if (result === '' || /^[_-]+$/.test(result)) {
    return 'download';
  }
  if (/^(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(result)) {
    result = `_${result}`;
  }
  if (result.length > 100) {
    const dot = result.lastIndexOf('.');
    const suffix = dot > 0 && result.length - dot <= 16 ? result.substring(dot) : '';
    result = result.substring(0, 100 - suffix.length).replace(/[.]+$/, '') + suffix;
  }
  return result;
}

function downloadTarget(spec: DownloadSpec): DownloadTarget {
  const slug = repoSlug(spec.slug);
  const ref = encodedRef(spec.ref);
  if (spec.kind === 'source') {
    return { url: `https://codeload.github.com/${slug}/zip/${ref}`,
      name: safeFilename(`${slug.replace('/', '-')}-${spec.ref}.zip`), expected: -1 };
  }
  if (spec.kind !== 'asset') {
    throw new DownloadError('此下载类型不受支持');
  }
  const name = spec.assetName ?? '';
  const size = spec.size ?? -1;
  if (!name || name.length > 255 || name === '.' || name === '..' || /[\x00-\x1f\x7f/\\]/.test(name)) {
    throw new DownloadError('附件名称无效');
  }
  if (!Number.isSafeInteger(size) || size < 0 || size > DOWNLOAD_MAX_BYTES) {
    throw new DownloadError('附件大小无效或超过 32 MB 上限');
  }
  let encoded: string;
  try {
    encoded = encodeURIComponent(name);
  } catch (_) {
    throw new DownloadError('附件名称无效');
  }
  return { url: `https://github.com/${slug}/releases/download/${ref}/${encoded}`,
    name: safeFilename(name), expected: size };
}

// An explicitly selected mirror gets only this URL and an anonymous byte-range GET.
// No query, userinfo, port, fragment, redirect or fallback request is allowed.
function mirrorHost(value: string): string {
  const match = /^https:\/\/([a-z\d.-]{1,253})(\/[a-z\d._~!$&'()*+,;=:/%-]+)$/i.exec(value);
  if (value.length > 2048 || !match || match[0] !== value ||
    !/^(?:[a-z\d](?:[a-z\d-]{0,61}[a-z\d])?\.)+[a-z](?:[a-z\d-]{0,61}[a-z\d])?$/i.test(match[1]) ||
    /\.(?:localhost|local|internal|test|invalid)$/i.test(match[1]) || /%(?![a-f\d]{2})/i.test(match[2])) {
    throw new DownloadError('请输入已确认的公开 HTTPS 文件直链（无参数、登录或跳转）');
  }
  return match[1].toLowerCase();
}

function allowedAssetRedirect(value: string): boolean {
  // Only known GitHub release CDNs; never forward to an arbitrary hostname.
  return value.length <= 8192 &&
    /^https:\/\/(?:release-assets|objects|github-releases)\.githubusercontent\.com\/[^#\s\\]+$/i.test(value) &&
    !/[\x00-\x20\x7f]/.test(value);
}

function header(reply: request.agent.HttpResponse, name: string): string {
  let result = '';
  reply.headers.forEach((values: Array<string>, key: string): void => {
    if (key.toLowerCase() === name && values.length === 1) {
      result = values[0].trim();
    }
  });
  return result;
}

function parseLength(value: string): number {
  if (!/^\d+$/.test(value)) {
    return -1;
  }
  const length = Number(value);
  return Number.isSafeInteger(length) ? length : -1;
}

interface ByteRange {
  start: number;
  end: number;
  total: number;
}

function parseRange(value: string): ByteRange | undefined {
  const match = /^bytes (\d+)-(\d+)\/(\d+)$/i.exec(value);
  if (!match) {
    return undefined;
  }
  const start = parseLength(match[1]);
  const end = parseLength(match[2]);
  const total = parseLength(match[3]);
  return start >= 0 && start <= end && end < total ? { start, end, total } : undefined;
}

async function removeTask(task: request.agent.Task): Promise<void> {
  try {
    await request.agent.remove(task.tid);
    return;
  } catch (error) {
    if ((error as ErrorWithCode).code === 21900006) {
      return;
    }
  }
  try {
    await task.stop();
  } catch (_) {
    // A task that already ended cannot be stopped, but can still be removed.
  }
  try {
    await request.agent.remove(task.tid);
  } catch (error) {
    if ((error as ErrorWithCode).code !== 21900006) {
      throw new DownloadError('系统下载任务未能清理，请稍后重试');
    }
  }
}

interface ErrorWithCode {
  code: number;
}

async function deletePartial(path: string): Promise<void> {
  if (path !== '') {
    try {
      await fs.unlink(path);
    } catch (_) {
      // A task may already have removed the staging file.
    }
  }
}

interface AttemptOptions {
  url: string;
  path: string;
  cap: number;
  expected: number;
  kind: 'source' | 'asset' | 'speed';
  canRedirect: boolean;
}

interface AttemptResult {
  redirect: string;
  size: number;
  error: string;
}

class NativeAttempt {
  private readonly options: AttemptOptions;
  private task: request.agent.Task | undefined;
  private resolveResult: ((result: AttemptResult) => void) | undefined;
  private result: AttemptResult | undefined;
  private total: number = -1;
  private accepted: boolean = false;
  private paused: boolean = false;
  private deadline: number = 0;
  private startedAt: number = 0;
  private stoppedAt: number = 0;

  constructor(options: AttemptOptions) {
    this.options = options;
  }

  private finish(redirect: string, size: number, error: string): void {
    if (!this.result) {
      const result: AttemptResult = { redirect, size, error };
      this.result = result;
      this.resolveResult?.(result);
    }
  }

  private fail(message: string): void {
    this.finish('', -1, message);
  }

  abort(): void {
    this.fail('已取消');
  }

  private timeoutMs(): number {
    return this.options.kind === 'speed' ? SPEED_TIMEOUT_MS : TRANSFER_TIMEOUT_MS;
  }

  elapsedMs(): number {
    return Math.max(1, this.stoppedAt - this.startedAt);
  }

  async pause(): Promise<void> {
    const task = this.task;
    if (!task || this.result) {
      throw new DownloadError('当前无法暂停');
    }
    try {
      await task.pause();
      this.paused = true;
    } catch (_) {
      throw new DownloadError('当前无法暂停');
    }
  }

  async resume(): Promise<void> {
    const task = this.task;
    if (!task || this.result) {
      throw new DownloadError('当前无法继续');
    }
    try {
      await task.resume();
      this.paused = false;
      this.deadline = Date.now() + this.timeoutMs();
    } catch (_) {
      throw new DownloadError('当前无法继续，可取消后重试');
    }
  }

  private response(reply: request.agent.HttpResponse): void {
    if (this.result) {
      return;
    }
    const code = reply.statusCode;
    if (code === 301 || code === 302 || code === 303 || code === 307 || code === 308) {
      const next = header(reply, 'location');
      if (this.options.canRedirect && allowedAssetRedirect(next)) {
        this.finish(next, -1, '');
      } else {
        this.fail('下载地址发生了未经批准的跳转');
      }
      return;
    }
    if (code !== 200 && code !== 206) {
      if (code !== 408) { // The native service may retry a request timeout.
        this.fail(code === 404 || code === 403 ? '仅支持公开内容，文件不存在或访问被拒绝' : `下载失败（HTTP ${code}）`);
      }
      return;
    }
    const length = parseLength(header(reply, 'content-length'));
    const encoding = header(reply, 'content-encoding').toLowerCase();
    if (encoding !== '' && encoding !== 'identity') {
      this.fail('响应使用了不受支持的内容编码');
      return;
    }
    if (this.options.kind !== 'source' && (length < 0 || header(reply, 'transfer-encoding') !== '')) {
      this.fail('无法验证服务器文件大小');
      return;
    }
    const range = code === 206 ? parseRange(header(reply, 'content-range')) : undefined;
    if (code === 206 && (!range || (length >= 0 && length !== range.end - range.start + 1))) {
      this.fail('服务器返回了无效的续传范围');
      return;
    }
    if (this.options.kind === 'speed') {
      if (!range || range.start !== 0 || range.end + 1 !== Math.min(range.total, this.options.cap)) {
        this.fail('测速直链不支持预期的字节范围');
        return;
      }
      this.total = range.end + 1;
    } else {
      if ((range && range.end + 1 !== range.total) || (this.options.expected > 0 && !range)) {
        this.fail('服务器未返回完整文件或有效的续传范围');
        return;
      }
      const total = range ? range.total : length;
      if (total > this.options.cap || length > this.options.cap) {
        this.fail('下载内容超过手表大小上限');
        return;
      }
      if (this.options.expected >= 0 && total >= 0 && total !== this.options.expected) {
        this.fail('服务器文件大小与发行版记录不一致');
        return;
      }
      this.total = total >= 0 ? total : this.options.expected;
    }
    this.accepted = true;
  }

  async transfer(context: common.UIAbilityContext,
    update: (received: number, total: number) => void): Promise<AttemptResult> {
    if (this.result) {
      return this.result;
    }
    const config: request.agent.Config = {
      action: request.agent.Action.DOWNLOAD,
      mode: request.agent.Mode.FOREGROUND, // No unattended background transfer after the UI exits.
      url: this.options.url,
      title: 'WristGit download',
      saveas: this.options.path,
      overwrite: false,
      precise: this.options.kind !== 'source',
      retry: false,
      redirect: false,
      roaming: false,
      headers: { 'Accept-Encoding': 'identity' }
    };
    if (this.options.kind !== 'source' && this.options.cap > 0) {
      // Native Range request (also used for native pause/resume); never send credentials.
      config.ends = this.options.cap - 1;
    }
    const task = await request.agent.create(context, config);
    this.task = task;
    let timer = -1;
    let terminalTimer = -1;
    try {
      return await new Promise<AttemptResult>((resolve: (result: AttemptResult) => void): void => {
        this.resolveResult = resolve;
        if (this.result) {
          resolve(this.result);
          return;
        }
        const onTerminal = (state: 'completed' | 'failed', progress: request.agent.Progress): void => {
          this.stoppedAt = Date.now();
          // Response and terminal notifications come through separate native callbacks.
          terminalTimer = setTimeout((): void => {
            if (state === 'failed') {
              this.fail(this.options.kind === 'speed' ? '测速失败：需使用支持字节范围的公开直链' :
                '下载失败或设备不支持此下载，可重试');
            } else if (!this.accepted) {
              this.fail('无法验证服务器响应');
            } else if (progress.processed > this.options.cap) {
              this.fail('下载内容超过手表大小上限');
            } else {
              this.finish('', this.total, '');
            }
          }, 100);
        };
        task.on('response', (reply: request.agent.HttpResponse): void => this.response(reply));
        task.on('progress', (progress: request.agent.Progress): void => {
          if (this.result) {
            return;
          }
          if (progress.processed > this.options.cap || (progress.sizes[0] ?? -1) > this.options.cap) {
            this.fail('下载内容超过手表大小上限');
          } else {
            update(progress.processed, this.total);
          }
        });
        task.on('completed', (progress: request.agent.Progress): void => onTerminal('completed', progress));
        task.on('failed', (progress: request.agent.Progress): void => onTerminal('failed', progress));
        task.on('remove', (): void => this.fail('系统已移除下载任务'));
        this.deadline = Date.now() + this.timeoutMs();
        timer = setInterval((): void => {
          if (this.result || this.paused) {
            return;
          }
          if (Date.now() >= this.deadline) {
            this.fail(this.options.kind === 'speed' ? '测速超时' : '下载超时，可重试');
            return;
          }
          try {
            // Codeload ZIPs can be chunked and ignore Range. Guard the actual
            // on-disk bytes as well as response headers and native progress.
            if (fs.statSync(this.options.path).size > this.options.cap) {
              this.fail('下载内容超过手表大小上限');
            }
          } catch (_) {
            // The staging file may not yet exist.
          }
        }, WATCH_INTERVAL_MS);
        this.startedAt = Date.now();
        task.start().catch((): void => this.fail('无法启动系统下载任务'));
      });
    } finally {
      clearInterval(timer);
      clearTimeout(terminalTimer);
      this.resolveResult = undefined;
      try {
        task.off('response');
        task.off('progress');
        task.off('completed');
        task.off('failed');
        task.off('remove');
      } finally {
        await removeTask(task);
      }
    }
  }
}

class DownloadRun {
  attempt: NativeAttempt | undefined;
  completion: Promise<void> | undefined;
  cancelled: boolean = false;
  changing: boolean = false;
}

async function hasZipSignature(path: string): Promise<boolean> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY);
  try {
    const bytes = new ArrayBuffer(4);
    const count = await fs.read(file.fd, bytes);
    const b = new Uint8Array(bytes);
    return count === 4 && b[0] === 0x50 && b[1] === 0x4b &&
      ((b[2] === 0x03 && b[3] === 0x04) || (b[2] === 0x05 && b[3] === 0x06));
  } finally {
    await fs.close(file);
  }
}

export class Downloads {
  private static busy: boolean = false;
  private static sequence: number = 0;
  private static fileOwner: Downloads | undefined;
  private readonly context: common.UIAbilityContext;
  private readonly onStatus?: (status: DownloadStatus) => void;
  private readonly directory: string;
  private readonly finalPath: string;
  private active: DownloadRun | undefined;
  private lastSpec: DownloadSpec | undefined;
  private snapshot: DownloadStatus = { phase: 'idle', name: '', receivedBytes: 0, totalBytes: -1, message: '' };

  constructor(context: common.UIAbilityContext, onStatus?: (status: DownloadStatus) => void) {
    this.context = context;
    this.onStatus = onStatus;
    this.directory = `${context.filesDir}/wristgit-downloads`;
    this.finalPath = `${this.directory}/latest`;
  }

  static sourceZip(slug: string, ref: string): DownloadSpec {
    return { kind: 'source', slug, ref };
  }

  static releaseAsset(slug: string, tag: string, assetName: string, size: number): DownloadSpec {
    return { kind: 'asset', slug, ref: tag, assetName, size };
  }

  status(): DownloadStatus {
    return { phase: this.snapshot.phase, name: this.snapshot.name, receivedBytes: this.snapshot.receivedBytes,
      totalBytes: this.snapshot.totalBytes, message: this.snapshot.message };
  }

  private publish(phase: DownloadPhase, received: number, total: number, message: string = '',
    name: string = this.snapshot.name): void {
    this.snapshot = { phase, name, receivedBytes: received, totalBytes: total, message };
    try {
      this.onStatus?.(this.status());
    } catch (_) {
      // UI observer failures must not interrupt native cleanup.
    }
  }

  private checkFree(): void {
    if (Downloads.busy) {
      throw new DownloadError('已有下载、导出或测速正在进行');
    }
  }

  private async prepare(): Promise<void> {
    await fs.mkdir(this.directory, true);
    const files = await fs.listFile(this.directory);
    for (const file of files) {
      if (/^part-\d+-\d+$/.test(file)) {
        await deletePartial(`${this.directory}/${file}`);
      }
    }
  }

  private stagingPath(): string {
    Downloads.sequence++;
    return `${this.directory}/part-${Date.now()}-${Downloads.sequence}`;
  }

  // Resolves at a terminal status. Validation and overlapping-operation errors reject.
  async start(spec: DownloadSpec): Promise<void> {
    this.checkFree();
    const kind = spec.kind;
    const target = downloadTarget(spec);
    this.lastSpec = { kind, slug: spec.slug, ref: spec.ref, assetName: spec.assetName, size: spec.size };
    Downloads.busy = true;
    const run = new DownloadRun();
    this.active = run;
    // Set completion before calling a potentially reentrant UI observer.
    run.completion = Promise.resolve().then((): Promise<void> => this.runDownload(run, kind, target));
    this.publish('starting', 0, target.expected, '', target.name);
    await run.completion;
  }

  private async runDownload(run: DownloadRun, kind: 'source' | 'asset', target: DownloadTarget): Promise<void> {
    let path = '';
    let phase: DownloadPhase = 'failed';
    let message = '下载失败或设备不支持系统下载';
    let size = 0;
    try {
      await this.prepare();
      let url = target.url;
      // At most one manually checked hop, solely for the release CDN.
      for (let hop = 0; hop < 2; hop++) {
        if (run.cancelled) {
          break;
        }
        path = this.stagingPath();
        const options: AttemptOptions = { url, path, kind, cap: kind === 'asset' ? target.expected : DOWNLOAD_MAX_BYTES,
          expected: target.expected, canRedirect: kind === 'asset' && hop === 0 };
        const attempt = new NativeAttempt(options);
        run.attempt = attempt;
        const result = await attempt.transfer(this.context, (received: number, total: number): void => {
          if (!run.cancelled && (this.snapshot.phase === 'starting' || this.snapshot.phase === 'downloading')) {
            this.publish('downloading', received, total >= 0 ? total : target.expected);
          }
        });
        if (run.cancelled) {
          break;
        }
        if (result.error !== '') {
          throw new DownloadError(result.error);
        }
        if (result.redirect !== '') {
          await deletePartial(path);
          path = '';
          url = result.redirect;
          continue;
        }
        size = (await fs.stat(path)).size;
        if (size > options.cap || (result.size >= 0 && result.size !== size) ||
          (target.expected >= 0 && target.expected !== size)) {
          throw new DownloadError('实际文件大小无效或超过手表上限');
        }
        if (kind === 'source' && !(await hasZipSignature(path))) {
          throw new DownloadError('服务器未返回有效的 ZIP 文件');
        }
        if (!run.cancelled) {
          this.active = undefined; // A validated file is committing; do not report a misleading cancellation.
          await fs.rename(path, this.finalPath);
          path = '';
          Downloads.fileOwner = this;
          phase = 'completed';
          message = '已保存到应用内';
        }
        break;
      }
      if (run.cancelled) {
        phase = 'cancelled';
        message = '已取消';
      }
    } catch (error) {
      if (error instanceof DownloadError) {
        message = error.message;
      }
    } finally {
      await deletePartial(path);
      this.active = undefined;
      Downloads.busy = false;
      if (phase === 'completed') {
        this.publish(phase, size, size, message);
      } else {
        this.publish(phase, this.snapshot.receivedBytes, this.snapshot.totalBytes, message);
      }
    }
  }

  async pause(): Promise<void> {
    const run = this.active;
    const attempt = run?.attempt;
    if (!run || !attempt || run.changing || run.cancelled ||
      (this.snapshot.phase !== 'starting' && this.snapshot.phase !== 'downloading')) {
      throw new DownloadError('当前无法暂停');
    }
    run.changing = true;
    try {
      await attempt.pause();
      if (this.active === run && run.attempt === attempt && !run.cancelled) {
        this.publish('paused', this.snapshot.receivedBytes, this.snapshot.totalBytes);
      }
    } finally {
      run.changing = false;
    }
  }

  async resume(): Promise<void> {
    const run = this.active;
    const attempt = run?.attempt;
    if (!run || !attempt || run.changing || run.cancelled || this.snapshot.phase !== 'paused') {
      throw new DownloadError('当前无法继续');
    }
    run.changing = true;
    try {
      await attempt.resume();
      if (this.active === run && !run.cancelled) {
        this.publish('downloading', this.snapshot.receivedBytes, this.snapshot.totalBytes);
      }
    } finally {
      run.changing = false;
    }
  }

  async cancel(): Promise<void> {
    const run = this.active;
    if (run && !run.cancelled) {
      run.cancelled = true;
      run.attempt?.abort();
      this.publish('cancelling', this.snapshot.receivedBytes, this.snapshot.totalBytes);
    }
    await run?.completion;
  }

  async retry(): Promise<void> {
    const spec = this.lastSpec;
    if (!spec || (this.snapshot.phase !== 'failed' && this.snapshot.phase !== 'cancelled')) {
      throw new DownloadError('没有可重试的下载');
    }
    await this.start(spec);
  }

  async exportFile(): Promise<boolean> {
    if (Downloads.busy || Downloads.fileOwner !== this || this.snapshot.phase !== 'completed' ||
      !canIUse('SystemCapability.FileManagement.UserFileService')) {
      return false;
    }
    Downloads.busy = true;
    try {
      const pickerModule = await import('@ohos.file.picker');
      const options = new pickerModule.default.DocumentSaveOptions();
      options.newFileNames = [this.snapshot.name];
      const uris = await new pickerModule.default.DocumentViewPicker(this.context).save(options);
      if (uris.length !== 1 || !uris[0]) {
        return false;
      }
      const output = await fs.open(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        await fs.copyFile(this.finalPath, output.fd);
      } finally {
        await fs.close(output);
      }
      return true;
    } catch (_) {
      // Document picker is optional on wearables. Keep the app-local file.
      return false;
    } finally {
      Downloads.busy = false;
    }
  }

  async speedTest(mirrorUrl?: string): Promise<DownloadSpeedResult> {
    this.checkFree();
    const url = mirrorUrl === undefined ? OFFICIAL_TEST : mirrorUrl.trim();
    const source = mirrorUrl === undefined ? 'raw.githubusercontent.com' : mirrorHost(url);
    Downloads.busy = true;
    let path = '';
    try {
      await this.prepare();
      path = this.stagingPath();
      const options: AttemptOptions = { url, path, cap: SPEED_BYTES, expected: -1, kind: 'speed', canRedirect: false };
      const attempt = new NativeAttempt(options);
      const result = await attempt.transfer(this.context, (_received: number, _total: number): void => {});
      const elapsedMs = attempt.elapsedMs();
      if (result.error !== '') {
        throw new DownloadError(result.error);
      }
      const bytes = (await fs.stat(path)).size;
      if (bytes <= 0 || bytes > SPEED_BYTES || bytes !== result.size) {
        throw new DownloadError('测速样本的实际大小无效');
      }
      return { source, bytes, elapsedMs, bytesPerSecond: bytes * 1000 / elapsedMs };
    } catch (error) {
      if (error instanceof DownloadError) {
        throw error;
      }
      throw new DownloadError('测速失败或设备不支持系统下载');
    } finally {
      await deletePartial(path);
      Downloads.busy = false;
    }
  }
}
