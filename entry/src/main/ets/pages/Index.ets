import type { common } from '@kit.AbilityKit';
import lazy { preferences } from '@kit.ArkData';
import lazy { curves } from '@kit.ArkUI';
import lazy { pasteboard } from '@kit.BasicServicesKit';
import lazy { GitHub, GitHubError } from '../common/GitHub';
import type { Asset, Branch, GitHubNotification, IssueComment, IssueOrPullDetail, LanguageSlice, Release, Repo, RepoThread, TreeItem } from '../common/GitHub';
import { compact, exactRepo, listQuery, PAGE_SIZE, sizeLabel, textPages } from '../common/Logic';
import { belongs, FavoriteGroup, groupName, removeFromGroups, setMembership } from '../common/Collection';
import lazy { Downloads } from '../common/Downloads';
import type { DownloadSpec, DownloadStatus } from '../common/Downloads';
import lazy { Vault } from '../common/Vault';
import type { TotpAccount } from '../common/Vault';
import { WatchTab, watchPageProgress } from '../common/WatchPager';
import { MarkdownView } from '../components/MarkdownView';
import { WristGuide } from '../components/WristGuide';
import { DAY_LOOK, Look, NIGHT_LOOK } from '../common/Look';
import { closesFloor, FloorAction, FloorCopy, floorCopy, floorReveal, floorRise, opensFloor, pullAccepted, pullDistance } from '../common/QuickFloor';
import { CrownMotion, crownScrollRange } from '../common/CrownMotion';
import { allowsQuickFloor } from '../common/WristNavigation';
import { DeviceAuth, DeviceAuthError, DEVICE_CLIENT_ID, DEVICE_SCOPE, DeviceSession } from '../common/DeviceAuth';
import { encodeQrText, qrPathCommands, QrEcc } from '../common/QrCode';
import type { QrCode } from '../common/QrCode';

const MAIN_SCROLL_ID: string = 'wrist-main-scroll';
const FLOOR_SCROLL_ID: string = 'wrist-floor-scroll';
const FILE_MAX: number = 128 * 1024;
const DIR_PAGE: number = 12;
const ROOT_KINDS: string[] = ['home', 'search', 'notifications', 'saved'];
const ROOT_TABS: WatchTab[] = [new WatchTab('首页', 'home'), new WatchTab('搜索', 'search'), new WatchTab('通知', 'notices'), new WatchTab('收藏', 'saved')];
const REPO_KINDS: string[] = ['repo', 'readme', 'tree', 'releases'];
const REPO_TABS: WatchTab[] = [new WatchTab('概览', 'overview'), new WatchTab('文档', 'readme'), new WatchTab('代码', 'tree'), new WatchTab('发布', 'releases')];
const REPO_TITLES: string[] = ['仓库', 'README', '代码', 'Releases'];

class Screen {
  kind: string;
  title: string;
  slug: string = '';
  repo: Repo | undefined = undefined;
  tab: number = 0;
  month: boolean = false;
  query: string = '';
  error: string = '';
  hint: string = '';
  busy: boolean = false;
  loaded: boolean = false;
  page: number = 1;
  more: boolean = false;
  repos: Repo[] = [];
  tree: TreeItem[] = [];
  branches: Branch[] = [];
  releases: Release[] = [];
  release: Release | undefined = undefined;
  parts: string[] = [];
  language: LanguageSlice[] = [];
  path: string = '';
  ref: string = '';
  offset: number = 0;
  markdown: string = '';
  notifications: GitHubNotification[] = [];
  reason: number = 0;
  notification: GitHubNotification | undefined = undefined;
  issue: IssueOrPullDetail | undefined = undefined;
  comments: IssueComment[] = [];
  targetComment: IssueComment | undefined = undefined;
  threads: RepoThread[] = [];
  issueNumber: number = 0;
  pull: boolean = false;
  starred: boolean = false;
  watching: boolean = false;
  hasStarsState: boolean = false;
  hasWatchState: boolean = false;
  userCode: string = '';
  deviceStatus: string = '';
  constructor(kind: string, title: string) {
    this.kind = kind;
    this.title = title;
  }
}

@Entry
@Component
struct Index {
  @State private screen: Screen = new Screen('home', '首页');
  @State private fullReady: boolean = false;
  @State private servicesReady: boolean = false;
  @State private enhanced: boolean = false;
  @State private pagerProgress: number = 0;
  @State private qrCell: number = 0;
  @State private oauthClientDraft: string = '';
  @State private qrZoom: boolean = false;
  @State private qrZoomCell: number = 0;
  @State private bootHint: string = '';
  @State private input: string = '';
  @State private favorites: Repo[] = [];
  @State private saveError: string = '';
  @State private searchEditing: boolean = false;
  @State private searchInputOpen: boolean = false;
  @State private dark: boolean = false;
  @State private floorOpen: boolean = false;
  @State private floorVisible: boolean = false;
  @State private floorProgress: number = 0;
  @State private floorKind: string = 'home';
  @State private guideOpen: boolean = false;
  @State private guideHint: boolean = false;
  @State private fingerY: number = 0;
  @State private crownY: number = 0;
  @State private groups: FavoriteGroup[] = [];
  @State private groupDraft: string = '';
  @State private login: string = '';
  @State private authReady: boolean = false;
  @State private tokenDraft: string = '';
  @State private actionBusy: boolean = false;
  @State private pendingAction: string = '';
  @State private mirror: string = '';
  @State private mirrorDraft: string = '';
  @State private download: DownloadStatus | undefined = undefined;
  @State private otpEntries: TotpAccount[] = [];
  @State private otpTitle: string = '';
  @State private otpDraft: string = '';
  @State private otpValue: string = '';
  @State private otpRemaining: number = 0;
  private sharedSlug: string = '';
  private authGeneration: number = 0;
  private markTimer: number = -1;
  private otpTimer: number = -1;
  private otpExpires: number = 0;
  private otpLoading: boolean = false;
  private downloads: Downloads | undefined = undefined;
  private downloadSpec: DownloadSpec | undefined = undefined;
  private history: Screen[] = [];
  private roots: Map<string, Screen> = new Map<string, Screen>();
  private prefs: preferences.Preferences | undefined = undefined;
  private serial: number = 0;
  private scroller: Scroller | undefined = undefined;
  private floorScroller: Scroller | undefined = undefined;
  private rootPager: SwiperController | undefined = undefined;
  private repoPager: SwiperController | undefined = undefined;
  private viewportHeight: number = 0;
  private contentHeight: number = -1;
  private pullFromTop: boolean = false;
  private floorPanFromEnd: boolean = false;
  private floorCloseArmed: boolean = false;
  private floorTimer: number = -1;
  private floorEpoch: number = 0;
  private touchDown: boolean = false;
  private focusTicket: number = 0;
  private focusTimer: number = -1;
  private bootTimer: number = -1;
  private enhancedTimer: number = -1;
  private defaultApplied: boolean = false;
  private deviceSession: DeviceSession | undefined = undefined;
  private deviceGen: number = 0;
  private qrSymbol: QrCode | undefined = undefined;
  private qrCache: string = '';
  private qrCacheFor: string = '';
  private initialized: boolean = false;
  private crown: CrownMotion = new CrownMotion((y: number) => {
    this.scroller?.scrollTo({ xOffset: 0, yOffset: y, animation: false });
  }, (y: number) => { this.crownY = y; }, () => {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.31, 0.74, 0.12) }, () => { this.crownY = 0; });
  });

  private theme(): Look { return this.dark ? NIGHT_LOOK : DAY_LOOK; }
  private floorTheme(): Look { return this.dark ? DAY_LOOK : NIGHT_LOOK; }

  aboutToAppear(): void {
    console.info('WristGitBoot: F10-index-created');
    // Boot straight into the verified compatible surface; the earlier crash
    // paths (F10 shell / lite page) are no longer part of startup.
    this.activateFull();
  }

  private activateFull(): void {
    if (this.fullReady) { return; }
    console.info('WristGitBoot: F11-mount-compatible');
    try {
      this.scroller = new Scroller();
      this.floorScroller = new Scroller();
      this.fullReady = true;
      this.scheduleServices();
    } catch (_) {
      this.bootHint = '无法创建滚动界面 · F11';
      console.warn('WristGitBoot: F11-scroll-unavailable');
    }
  }

  private scheduleServices(): void {
    if (!this.fullReady || this.initialized || this.bootTimer >= 0) { return; }
    console.info('WristGitBoot: F20-schedule-services');
    this.bootHint = '正在读取设置并连接 GitHub…';
    this.bootTimer = setTimeout(() => { this.bootTimer = -1; this.initServices(); }, 100);
  }

  private tryEnhanced(): void {
    if (!this.fullReady) { return; }
    this.crown.reset();
    this.touchReset();
    const enable = !this.enhanced;
    if (enable) {
      try {
        if (this.rootPager === undefined) { this.rootPager = new SwiperController(); }
        if (this.repoPager === undefined) { this.repoPager = new SwiperController(); }
      } catch (_) { console.warn('WristGitBoot: swiper-unavailable'); return; }
    }
    console.info(enable ? 'WristGitBoot: F30-enable-enhanced' : 'WristGitBoot: F31-disable-enhanced');
    this.enhanced = enable;
    if (enable) { this.focusSurface(); }
  }

  private uiAnimate(duration: number, change: () => void): void {
    if (!this.enhanced) { change(); return; }
    let applied = false;
    try {
      this.getUIContext().animateTo({ duration, curve: Curve.EaseOut }, () => { applied = true; change(); });
    } catch (_) { if (!applied) { change(); } }
  }

  private initServices(): void {
    if (this.initialized) { return; }
    this.initialized = true;
    console.info('WristGitBoot: F21-services-start');
    let ctx: common.UIAbilityContext | undefined = undefined;
    try { ctx = this.getUIContext().getHostContext() as common.UIAbilityContext; } catch (_) {}
    if (ctx === undefined) {
      try { ctx = getContext(this) as common.UIAbilityContext; } catch (_) {}
    }
    if (ctx !== undefined) {
      try {
        this.downloads = new Downloads(ctx, (state: DownloadStatus) => { this.download = state; });
        this.download = this.downloads.status();
      } catch (_) { console.warn('WristGitBoot: downloads-unavailable'); }
    }
    try {
      if (ctx === undefined) { throw new Error('No ability context'); }
      this.prefs = preferences.getPreferencesSync(ctx, { name: 'wrist_git' });
      const raw = this.prefs.getSync('favorites_v2', '') as string;
      if (raw) {
        const data = JSON.parse(raw) as SavedCollection;
        this.favorites = Array.isArray(data.repos) ? data.repos : [];
        this.groups = Array.isArray(data.groups) ? data.groups : [];
      } else {
        const items = JSON.parse(this.prefs.getSync('favorites', '[]') as string) as Repo[];
        this.favorites = Array.isArray(items) ? items : [];
      }
      this.mirror = this.prefs.getSync('speed_endpoint', '') as string;
      this.oauthClientDraft = this.prefs.getSync('oauth_client_id', '') as string;
      this.dark = this.prefs.getSync('appearance_dark', false) as boolean;
      this.guideHint = !(this.prefs.getSync('guide_03_seen', false) as boolean);
    } catch (_) {
      this.saveError = '无法读取本机设置';
      this.guideHint = true;
      console.warn('WristGitBoot: preferences-unavailable');
    }
    this.servicesReady = true;
    this.bootHint = '';
    console.info('WristGitBoot: F22-services-initialized');
    this.restoreAuth().catch(() => { console.warn('WristGitBoot: account-unavailable'); });
    this.consumeShared();
    this.load().catch(() => { console.warn('WristGitBoot: feed-unavailable'); });
    this.scheduleDefaultEnhanced();
    if (this.enhanced) { this.focusSurface(); }
  }

  private scheduleDefaultEnhanced(): void {
    if (!this.fullReady || !this.servicesReady || this.defaultApplied || this.enhancedTimer >= 0) { return; }
    this.enhancedTimer = setTimeout(() => {
      this.enhancedTimer = -1;
      this.defaultApplied = true;
      if (!this.enhanced) { this.tryEnhanced(); }
    }, 180);
  }

  onPageShow(): void {
    if (!this.fullReady) {
      console.warn('WristGitBoot: F11-mount-failed');
      this.activateFull();
      return;
    }
    if (this.servicesReady) { this.consumeShared(); this.scheduleDefaultEnhanced(); }
    else { this.scheduleServices(); }
    if (this.screen.kind === 'otpCode' && !this.floorOpen) { this.startOtpClock(); }
    if (this.enhanced) { this.focusSurface(); }
  }

  private consumeShared(): void {
    try {
      this.sharedSlug = AppStorage.get<string>('wristGitShared') ?? '';
      if (!this.sharedSlug) { return; }
      AppStorage.setOrCreate('wristGitShared', '');
      this.sharedChanged();
    } catch (_) { console.warn('WristGitBoot: share-unavailable'); }
  }

  onPageHide(): void {
    if (this.bootTimer >= 0) { clearTimeout(this.bootTimer); this.bootTimer = -1; }
    if (this.enhancedTimer >= 0) { clearTimeout(this.enhancedTimer); this.enhancedTimer = -1; }
    this.cancelFocus();
    this.crown.reset();
    this.touchDown = false;
    this.touchReset();
    this.clearFloorTimer();
    this.floorOpen = false;
    this.floorVisible = false;
    this.floorProgress = 0;
    this.floorCloseArmed = false;
    this.tokenDraft = '';
    this.otpDraft = '';
    this.stopOtpClock();
    this.cancelMark();
  }

  aboutToDisappear(): void {
    this.onPageHide();
    this.serial++;
    this.authGeneration++;
  }

  private sharedChanged(): void {
    const slug = exactRepo(this.sharedSlug);
    if (!slug) { return; }
    const next = new Screen('shared', '打开 GitHub 仓库？');
    next.slug = slug;
    this.sharedSlug = '';
    this.open(next);
  }

  private message(error: Object, fallback: string): string {
    if (!(error instanceof GitHubError)) { return fallback; }
    const seconds = Math.ceil((error.retryAt - Date.now()) / 1000);
    if (seconds > 0) {
      return `GitHub 已限流 · ${seconds >= 60 ? `${Math.ceil(seconds / 60)} 分钟` : `${seconds} 秒`}后可重试`;
    }
    return error.message;
  }

  private async restoreAuth(): Promise<void> {
    const epoch = this.authGeneration;
    try {
      const token = await Vault.loadToken();
      if (epoch !== this.authGeneration) { return; }
      if (token) {
        GitHub.setToken(token);
        this.login = (this.prefs?.getSync('github_login', '') as string) || '已连接';
      }
    } catch (_) {
      if (this.screen.kind === 'settings') { this.screen.hint = '手表安全存储暂不可用，请解锁后重试'; }
    } finally {
      if (epoch === this.authGeneration) {
        this.authReady = true;
        if (this.login && (['notifications', 'starred', 'repo'].includes(this.screen.kind) ||
          (['home', 'search'].includes(this.screen.kind) && !this.screen.loaded))) { this.refresh(); }
      }
    }
  }

  private deviceClientId(): string {
    const custom = this.oauthClientDraft.trim();
    return /^[A-Za-z0-9]{10,40}$/.test(custom) ? custom : DEVICE_CLIENT_ID;
  }

  private openDeviceAuth(): void {
    this.open(new Screen('deviceAuth', '扫码连接'));
    this.startDeviceAuth();
  }

  private async startDeviceAuth(): Promise<void> {
    if (this.screen.kind !== 'deviceAuth' || this.actionBusy) { return; }
    this.actionBusy = true;
    const gen = ++this.deviceGen;
    this.screen.deviceStatus = '正在生成验证码…';
    this.screen.userCode = '';
    this.qrSymbol = undefined;
    this.qrCache = '';
    this.qrCell = 0;
    try {
      const session = await DeviceAuth.start(this.deviceClientId(), DEVICE_SCOPE);
      if (gen !== this.deviceGen || this.screen.kind !== 'deviceAuth') { return; }
      this.deviceSession = session;
      this.screen.userCode = session.userCode;
      this.qrSymbol = encodeQrText(DeviceAuth.verificationUrl(session.userCode), QrEcc.LOW);
      this.screen.deviceStatus = '用手机扫码，或在浏览器输入验证码';
      this.actionBusy = false;
      this.devicePoll(gen);
    } catch (e) {
      if (gen === this.deviceGen && this.screen.kind === 'deviceAuth') {
        this.screen.deviceStatus = this.message(e as Object, '无法开始扫码连接');
        this.actionBusy = false;
      }
    }
  }

  private async devicePoll(gen: number): Promise<void> {
    const session = this.deviceSession;
    if (session === undefined) { return; }
    try {
      const token = await DeviceAuth.poll(session, this.deviceClientId(),
        () => gen === this.deviceGen && this.screen.kind === 'deviceAuth' && !this.actionBusy,
        (state: string) => {
          if (gen === this.deviceGen && this.screen.kind === 'deviceAuth') { this.screen.deviceStatus = state; }
        });
      if (gen !== this.deviceGen || this.screen.kind !== 'deviceAuth') { return; }
      await this.finishDeviceAuth(token);
    } catch (e) {
      if (gen === this.deviceGen && this.screen.kind === 'deviceAuth') {
        this.screen.deviceStatus = this.message(e as Object, '扫码连接失败');
      }
    }
  }

  private async finishDeviceAuth(token: string): Promise<void> {
    this.actionBusy = true;
    const gen = this.deviceGen;
    const serial = this.serial;
    this.screen.deviceStatus = '授权完成，正在验证账户…';
    try {
      const user = await GitHub.validateToken(token);
      if (gen !== this.deviceGen || serial !== this.serial || this.screen.kind !== 'deviceAuth') { return; }
      await Vault.saveToken(token);
      GitHub.setToken(token);
      const switched = !!this.login && this.login.toLowerCase() !== user.login.toLowerCase();
      this.login = user.login;
      this.roots.clear();
      if (switched) { this.history = []; }
      try {
        this.prefs?.putSync('github_login', user.login);
        await this.prefs?.flush();
      } catch (_) {}
      this.screen.deviceStatus = `已连接 · @${user.login}`;
    } catch (e) {
      this.screen.deviceStatus = this.message(e as Object, '授权完成但无法保存到手表');
    } finally { this.actionBusy = false; }
  }

  private cancelDeviceAuth(): void {
    this.deviceGen++;
    this.deviceSession = undefined;
    this.screen.userCode = '';
    this.qrSymbol = undefined;
    this.qrCache = '';
    this.screen.deviceStatus = '已取消扫码连接';
  }

  private qrCommands(cell: number): string {
    const qr = this.qrSymbol;
    if (qr === undefined || cell <= 0) { return ''; }
    const key = `${qr.size}-${cell}`;
    if (this.qrCacheFor !== key) {
      this.qrCache = qrPathCommands(qr, cell, 2);
      this.qrCacheFor = key;
    }
    return this.qrCache;
  }

  private qrBoxModules(): number {
    return this.qrSymbol === undefined ? 1 : this.qrSymbol.size + 8;
  }

  private async saveOauthClientDraft(): Promise<void> {
    try {
      this.prefs?.putSync('oauth_client_id', this.oauthClientDraft.trim());
      await this.prefs?.flush();
    } catch (_) {}
  }

  private async authenticate(): Promise<void> {
    if (this.actionBusy || !this.authReady) { return; }
    const token = this.tokenDraft.trim();
    this.tokenDraft = '';
    this.clearKeyboardFocus();
    if (!/^[A-Za-z0-9_]{20,240}$/.test(token)) {
      this.screen.hint = '请输入 GitHub 个人访问令牌';
      return;
    }
    this.actionBusy = true;
    const epoch = ++this.authGeneration;
    const serial = this.serial;
    try {
      const user = await GitHub.validateToken(token);
      if (epoch !== this.authGeneration || serial !== this.serial) { return; }
      await Vault.saveToken(token);
      if (epoch !== this.authGeneration) { return; }
      GitHub.setToken(token);
      const switchedAccount = !!this.login && this.login.toLowerCase() !== user.login.toLowerCase();
      this.login = user.login;
      this.roots.clear();
      if (switchedAccount) { this.history = []; }
      try {
        this.prefs?.putSync('github_login', user.login);
        await this.prefs?.flush();
      } catch (_) {} // The credential is already safely stored; this is just the display name.
      if (serial === this.serial) { this.screen.hint = '令牌已验证，仅保存在手表安全存储'; }
    } catch (e) {
      if (serial === this.serial) { this.screen.hint = this.message(e as Object, '无法保存令牌，已保留原登录状态'); }
    } finally { this.actionBusy = false; }
  }

  private async disconnect(): Promise<void> {
    if (this.actionBusy) { return; }
    this.actionBusy = true;
    this.pendingAction = '';
    const serial = this.serial;
    this.authGeneration++;
    try {
      await Vault.clearToken();
      GitHub.setToken('');
      this.login = '';
      this.roots.clear();
      this.history = [];
      try {
        this.prefs?.deleteSync('github_login');
        await this.prefs?.flush();
      } catch (_) {}
      if (serial === this.serial) { this.screen.hint = '已从这块手表移除 GitHub 令牌'; }
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '无法移除令牌，请先解锁手表后重试'; }
    } finally { this.actionBusy = false; }
  }

  private refresh(): void {
    GitHub.clearCache();
    this.serial++;
    this.screen.busy = false;
    this.screen.loaded = false;
    this.screen.error = '';
    this.screen.more = false;
    this.screen.page = 1;
    this.load();
  }

  onBackPress(): boolean {
    if (this.guideOpen) { this.finishGuide(false); return true; }
    if (this.floorOpen) { this.setFloor(false); return true; }
    return this.back();
  }

  private cancelFocus(): void {
    this.focusTicket++;
    if (this.focusTimer >= 0) { clearTimeout(this.focusTimer); }
    this.focusTimer = -1;
  }

  private clearKeyboardFocus(): void {
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_) {}
  }

  private focusSurface(): void {
    this.cancelFocus();
    if (!this.enhanced || this.searchEditing || this.guideOpen) { return; }
    const ticket = this.focusTicket;
    const id = this.floorOpen ? FLOOR_SCROLL_ID : MAIN_SCROLL_ID;
    this.focusTimer = setTimeout(() => {
      this.focusTimer = -1;
      if (ticket !== this.focusTicket || this.searchEditing || this.guideOpen) { return; }
      try { this.getUIContext().getFocusController().requestFocus(id); } catch (_) {}
    }, 65);
  }

  private editorFocus(active: boolean): void {
    this.searchEditing = active;
    if (active) { this.cancelFocus(); this.crown.reset(); this.touchReset(); }
  }

  private onCrown(event: CrownEvent): void {
    if (!this.enhanced || this.searchEditing || this.floorOpen || this.guideOpen || this.touchDown || this.pullFromTop) { return; }
    if (![CrownAction.BEGIN, CrownAction.UPDATE, CrownAction.END].includes(event.action)) { return; }
    const y = this.scroller?.currentOffset()?.yOffset;
    const limit = crownScrollRange(this.viewportHeight, this.contentHeight);
    if (y === undefined || limit < 0) { return; }
    if (event.degree !== 0) { this.crown.apply(event.degree, y, limit); }
    if (event.action === CrownAction.END) { this.crown.settle(); }
    event.stopPropagation();
  }

  private beginTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.touchDown = true;
      this.crown.reset();
      const y = this.scroller?.currentOffset()?.yOffset ?? Number.POSITIVE_INFINITY;
      this.pullFromTop = y <= 1 && allowsQuickFloor(this.screen.kind) && !this.searchEditing && !this.floorOpen && !this.guideOpen;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchDown = false;
      if (event.type === TouchType.Cancel) { this.touchReset(); this.cancelFloorPreview(); }
    }
  }

  private touchReset(): void {
    this.pullFromTop = false;
    if (this.fingerY !== 0) {
      this.uiAnimate(180, () => { this.fingerY = 0; });
    }
  }

  private clearFloorTimer(): void {
    this.floorEpoch++;
    if (this.floorTimer >= 0) { clearTimeout(this.floorTimer); }
    this.floorTimer = -1;
  }

  private animateFloor(target: number, duration: number): void {
    try {
      this.getUIContext().animateTo({ duration, curve: Curve.EaseOut }, () => { this.floorProgress = target; });
    } catch (_) { this.floorProgress = target; }
  }

  private mountFloor(): void {
    if (this.floorVisible) { return; }
    this.floorKind = this.screen.kind;
    this.floorProgress = 0;
    this.floorVisible = true;
  }

  private previewFloor(offset: number): void {
    if (this.floorOpen || this.guideOpen || !allowsQuickFloor(this.screen.kind)) { return; }
    const progress = floorReveal(offset);
    if (progress > 0) { this.mountFloor(); }
    if (this.floorVisible) { this.floorProgress = progress; }
  }

  private setFloor(open: boolean): void {
    if ((open && (this.floorOpen || !allowsQuickFloor(this.screen.kind))) || (!open && !this.floorVisible) || this.guideOpen) { return; }
    const wasOpen = this.floorOpen;
    const fresh = !this.floorVisible;
    this.clearFloorTimer();
    const ticket = this.floorEpoch;
    this.crown.reset();
    this.touchReset();
    this.floorCloseArmed = false;
    if (open) {
      this.mountFloor();
      this.clearKeyboardFocus();
      this.searchEditing = false;
      this.cancelMark();
      if (this.screen.kind === 'otpCode') { this.stopOtpClock(); }
    }
    this.floorOpen = open;
    if (open && fresh) {
      // Mount an invisible frame before committing the fade for tap-to-open.
      this.floorTimer = setTimeout(() => {
        this.floorTimer = -1;
        if (ticket === this.floorEpoch) { this.animateFloor(1, 230); }
      }, 24);
    } else {
      this.animateFloor(open ? 1 : 0, open ? 180 : 195);
    }
    if (!open) {
      this.floorTimer = setTimeout(() => {
        this.floorTimer = -1;
        if (ticket === this.floorEpoch) { this.floorVisible = false; }
      }, 210);
      if (wasOpen && this.screen.kind === 'otpCode') { this.startOtpClock(); }
    }
    if (open || wasOpen) { this.focusSurface(); }
  }

  private cancelFloorPreview(): void {
    if (this.floorVisible && !this.floorOpen) { this.setFloor(false); }
  }

  private beginFloorExit(allowed: boolean): void {
    this.floorCloseArmed = this.floorOpen && allowed;
  }

  private updateFloorExit(event: GestureEvent): void {
    if (!this.floorCloseArmed) { return; }
    this.floorProgress = pullAccepted(true, event.offsetX, -event.offsetY) ? 1 - floorReveal(-event.offsetY) : 1;
  }

  private finishFloorExit(event?: GestureEvent): void {
    if (!this.floorCloseArmed) { return; }
    this.floorCloseArmed = false;
    if (event !== undefined && closesFloor(true, event.offsetX, event.offsetY)) { this.setFloor(false); }
    else { this.animateFloor(1, 160); }
  }

  private showGuide(): void {
    if (this.floorOpen) { this.setFloor(false); }
    this.cancelFocus();
    this.crown.reset();
    this.clearKeyboardFocus();
    this.guideOpen = true;
  }

  private finishGuide(tryFloor: boolean): void {
    this.guideOpen = false;
    this.guideHint = false;
    try {
      this.prefs?.putSync('guide_03_seen', true);
      this.prefs?.flush().catch(() => {});
    } catch (_) {}
    if (tryFloor) { this.setFloor(true); } else { this.focusSurface(); }
  }

  private appearance(dark: boolean): void {
    if (this.dark === dark) { return; }
    this.uiAnimate(180, () => { this.dark = dark; });
    try {
      this.prefs?.putSync('appearance_dark', dark);
      this.prefs?.flush().catch(() => {});
    } catch (_) {}
  }

  private scrollToOffset(offset: number): void {
    const ticket = this.serial;
    setTimeout(() => {
      if (ticket === this.serial) {
        this.scroller?.scrollTo({ xOffset: 0, yOffset: offset, animation: false });
      }
    }, 40);
  }

  private leave(keepFloor: boolean = false): void {
    if (!keepFloor && this.floorOpen) { this.setFloor(false); }
    this.cancelFocus();
    this.crown.reset();
    this.touchReset();
    this.pendingAction = '';
    this.deviceGen++;
    this.deviceSession = undefined;
    this.qrZoom = false;
    this.tokenDraft = '';
    this.otpDraft = '';
    this.searchEditing = false;
    this.searchInputOpen = false;
    this.stopOtpClock();
    this.cancelMark();
  }

  private open(next: Screen): void {
    this.screen.offset = this.scroller?.currentOffset()?.yOffset ?? 0;
    this.history.push(this.screen);
    this.swap(next);
  }

  private swap(next: Screen, keepFloor: boolean = false): void {
    this.leave(keepFloor);
    this.serial++;
    this.uiAnimate(240, () => { this.screen = next; });
    this.load();
    this.scrollToOffset(0);
    if (next.kind === 'otpCode' && !this.floorOpen) { this.startOtpClock(); }
    if (!keepFloor) { this.focusSurface(); }
  }

  private back(): boolean {
    const prior = this.history.pop();
    if (prior === undefined) {
      if (this.screen.kind !== 'home') {
        this.root(0);
        return true;
      }
      return false;
    }
    this.leave();
    this.serial++;
    this.uiAnimate(265, () => { this.screen = prior; });
    if (this.screen.kind === 'otpCode') { this.startOtpClock(); }
    if (this.screen.kind === 'group') { this.groupDraft = this.screen.query; }
    if (this.screen.busy) { this.screen.busy = false; }
    if (!this.screen.loaded) { this.load(); }
    this.scrollToOffset(prior.offset);
    this.focusSurface();
    return true;
  }

  private root(index: number): void {
    const kind = ROOT_KINDS[index];
    if (!kind || this.screen.kind === kind) { return; }
    this.clearKeyboardFocus();
    this.searchEditing = false;
    if (ROOT_KINDS.includes(this.screen.kind)) {
      this.screen.offset = this.scroller?.currentOffset()?.yOffset ?? 0;
      this.screen.busy = false;
      this.roots.set(this.screen.kind, this.screen);
    }
    this.history = [];
    const next = this.roots.get(kind) ?? new Screen(kind, ROOT_TABS[index].title);
    this.swap(next);
    this.scrollToOffset(next.offset);
  }

  private usesRepoDock(): boolean {
    return this.screen.repo !== undefined && REPO_KINDS.includes(this.screen.kind) && !this.screen.path;
  }

  private async pasteRepository(): Promise<void> {
    const serial = this.serial;
    try {
      const clipboard = await pasteboard.getSystemPasteboard().getData();
      if (serial !== this.serial) { return; }
      const text = clipboard.getPrimaryText();
      if (!text || text.length > 2048 || !exactRepo(text)) {
        this.screen.hint = '剪贴板中没有 GitHub 仓库链接或 owner/repo';
        return;
      }
      this.sharedSlug = text;
      this.sharedChanged();
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '无法读取本次复制内容，可在输入框中粘贴'; }
    }
  }

  private submit(): void {
    const q = this.input.trim();
    if (!q) {
      this.screen.hint = '请输入关键词或仓库名';
      return;
    }
    this.clearKeyboardFocus();
    this.searchEditing = false;
    this.searchInputOpen = false;
    this.focusSurface();
    const slug = exactRepo(q);
    if (slug) {
      this.openRepo(slug, undefined);
    } else if (q.includes('://')) {
      this.screen.hint = '请输入 GitHub 仓库链接';
    } else {
      this.screen.query = q;
      this.screen.page = 1;
      this.screen.repos = [];
      this.screen.more = false;
      this.screen.hint = '';
      this.serial++;
      this.screen.busy = false;
      this.screen.loaded = false;
      this.load();
      this.scrollToOffset(0);
    }
  }

  private home(tab: number, month: boolean): void {
    if (this.screen.tab === tab && this.screen.month === month) {
      return;
    }
    const next = new Screen('home', '首页');
    next.tab = tab;
    next.month = month;
    this.swap(next, this.floorOpen);
  }

  private openRepo(slug: string, repo: Repo | undefined): void {
    const next = new Screen('repo', '仓库');
    next.slug = slug;
    next.repo = repo;
    this.open(next);
  }

  private fromRepo(kind: string, title: string, ref: string = ''): Screen {
    const next = new Screen(kind, title);
    next.repo = this.screen.repo;
    next.slug = this.screen.slug;
    next.ref = ref || this.screen.ref || this.screen.repo?.default_branch || 'HEAD';
    return next;
  }

  private repoTab(kind: string, title: string): void {
    if (this.screen.kind === kind) {
      return;
    }
    if (kind === 'repo') {
      this.back();
      return;
    }
    const next = this.fromRepo(kind, title);
    if (this.screen.kind === 'repo') {
      this.open(next);
    } else {
      this.swap(next);
    }
  }

  private treeItem(item: TreeItem): void {
    if (item.type === 'dir') {
      const next = this.fromRepo('tree', item.name);
      next.path = item.path;
      this.open(next);
    } else {
      const next = this.fromRepo('file', item.name);
      next.path = item.path;
      if (item.type !== 'file' || item.size > FILE_MAX) {
        next.hint = item.type !== 'file' ? '手表暂不支持子模块或符号链接' : '文件超过 128 KB，无法在手表预览';
        next.loaded = true;
      }
      this.open(next);
    }
  }

  private pickBranch(branch: Branch): void {
    // Replace the underlying directory with the root of the chosen branch.
    this.history.pop();
    this.swap(this.fromRepo('tree', '代码', branch.name));
  }

  private openRelease(release: Release): void {
    const next = this.fromRepo('release', release.tag_name);
    next.release = release;
    next.markdown = release.body ?? '';
    next.loaded = true;
    this.open(next);
  }

  private isSaved(slug: string): boolean {
    return this.favorites.some((repo: Repo) => repo.full_name.toLowerCase() === slug.toLowerCase());
  }

  private shallowRepo(repo: Repo): Repo {
    return {
      id: repo.id, name: repo.name, full_name: repo.full_name, description: repo.description,
      stargazers_count: repo.stargazers_count, forks_count: repo.forks_count, open_issues_count: repo.open_issues_count,
      language: repo.language, default_branch: repo.default_branch
    };
  }

  private async persistCollection(repos: Repo[], groups: FavoriteGroup[]): Promise<boolean> {
    const prefs = this.prefs;
    if (this.actionBusy) { return false; }
    if (prefs === undefined) { this.saveError = '本机收藏不可用'; return false; }
    this.actionBusy = true;
    this.saveError = '';
    try {
      const data: SavedCollection = { repos, groups };
      prefs.putSync('favorites_v2', JSON.stringify(data));
      await prefs.flush();
      this.favorites = repos;
      this.groups = groups;
      return true;
    } catch (_) {
      this.saveError = '未能保存收藏改动';
      return false;
    } finally { this.actionBusy = false; }
  }

  private async toggleSave(repo: Repo): Promise<void> {
    if (this.isSaved(repo.full_name)) {
      const slug = repo.full_name.toLowerCase();
      const remaining = this.favorites.filter((saved: Repo) => saved.full_name.toLowerCase() !== slug);
      await this.persistCollection(remaining, removeFromGroups(this.groups, slug));
    } else if (this.favorites.length >= 100) {
      this.saveError = '手表最多保存 100 个仓库';
    } else {
      await this.persistCollection([this.shallowRepo(repo)].concat(this.favorites), this.groups);
    }
  }

  private async assignGroup(repo: Repo, group: FavoriteGroup): Promise<void> {
    const isSaved = this.isSaved(repo.full_name);
    if (!isSaved && this.favorites.length >= 100) { this.saveError = '手表最多保存 100 个仓库'; return; }
    const repos = isSaved ? this.favorites : [this.shallowRepo(repo)].concat(this.favorites);
    await this.persistCollection(repos, setMembership(this.groups, group.name, repo.full_name, !belongs(group, repo.full_name)));
  }

  private showGroups(repo?: Repo): void {
    this.groupDraft = '';
    this.saveError = '';
    const next = new Screen(repo === undefined ? 'groups' : 'groupPicker', '收藏分组');
    next.repo = repo;
    this.open(next);
  }

  private async saveGroup(rename: boolean = false): Promise<void> {
    const name = groupName(this.groupDraft);
    if (!name) { this.saveError = '请输入分组名称'; return; }
    if (this.groups.some((group: FavoriteGroup) => group.name.toLowerCase() === name.toLowerCase() &&
      (!rename || group.name !== this.screen.query))) { this.saveError = '已有同名分组'; return; }
    if (!rename && this.groups.length >= 16) { this.saveError = '最多创建 16 个分组'; return; }
    const previous = this.screen.query;
    const serial = this.serial;
    const target = this.screen.repo;
    const newGroups = rename ? this.groups.map((group: FavoriteGroup) => group.name === previous ?
      new FavoriteGroup(name, group.slugs) : group) : this.groups.concat([new FavoriteGroup(name)]);
    if (target !== undefined && !rename) {
      if (!this.isSaved(target.full_name) && this.favorites.length >= 100) { this.saveError = '手表最多保存 100 个仓库'; return; }
      const repos = this.isSaved(target.full_name) ? this.favorites : [this.shallowRepo(target)].concat(this.favorites);
      if (!(await this.persistCollection(repos, setMembership(newGroups, name, target.full_name, true)))) { return; }
    } else if (!(await this.persistCollection(this.favorites, newGroups))) { return; }
    if (serial === this.serial) {
      this.groupDraft = '';
      if (rename) { this.screen.query = name; this.screen.title = name; }
    }
  }

  private openGroup(group: FavoriteGroup): void {
    this.groupDraft = group.name;
    const next = new Screen('group', group.name);
    next.query = group.name;
    this.open(next);
  }

  private groupRepos(): Repo[] {
    const group = this.groups.find((entry: FavoriteGroup) => entry.name === this.screen.query);
    return group === undefined ? [] : this.favorites.filter((repo: Repo) => belongs(group, repo.full_name));
  }

  private async deleteGroup(): Promise<void> {
    const serial = this.serial;
    const name = this.screen.query;
    if (await this.persistCollection(this.favorites, this.groups.filter((group: FavoriteGroup) => group.name !== name))) {
      if (serial === this.serial) { this.back(); }
    }
  }

  private noticesFilter(tab: number, reason: number): void {
    if (this.screen.tab === tab && this.screen.reason === reason) { return; }
    const next = new Screen('notifications', '通知');
    next.tab = tab;
    next.reason = reason;
    this.swap(next);
  }

  private visibleNotices(): GitHubNotification[] {
    const reason = this.screen.reason;
    if (this.screen.tab === 2) {
      return this.screen.notifications.filter((notice: GitHubNotification) => notice.reason === 'subscribed' || notice.subject.type === 'Release');
    }
    return this.screen.notifications.filter((notice: GitHubNotification) => reason === 0 ||
      (reason === 1 && notice.reason === 'author') || (reason === 2 && notice.reason === 'assign') ||
      (reason === 3 && ['mention', 'team_mention'].includes(notice.reason)));
  }

  private viewThreads(pull: boolean, closed: boolean): void {
    const next = this.fromRepo('threads', pull ? 'Pull Requests' : 'Issues');
    next.pull = pull;
    next.tab = closed ? 1 : 0;
    if (this.screen.kind === 'threads') { this.swap(next); }
    else { this.open(next); }
  }

  private openThread(thread: RepoThread): void {
    const next = this.fromRepo('issue', this.screen.pull ? 'Pull Request' : 'Issue');
    next.pull = this.screen.pull;
    next.issueNumber = thread.number;
    this.open(next);
  }

  private openNotice(notice: GitHubNotification): void {
    const jump = GitHub.notificationJump(notice);
    const next = new Screen('issue', jump.type === 'PullRequest' ? 'Pull Request' : '通知详情');
    next.slug = jump.slug;
    next.title = jump.type === 'Issue' ? 'Issue' : jump.type === 'Release' ? '发布通知' : next.title;
    next.query = jump.webUrl;
    next.issueNumber = jump.number;
    next.pull = jump.type === 'PullRequest';
    next.notification = notice;
    this.open(next);
  }

  private cancelMark(): void {
    if (this.markTimer >= 0) { clearTimeout(this.markTimer); }
    this.markTimer = -1;
    if (this.pendingAction === 'markWaiting') { this.pendingAction = ''; }
  }

  private markLater(): void {
    if (this.markTimer >= 0 || this.actionBusy) { return; }
    this.pendingAction = 'markWaiting';
    this.markTimer = setTimeout(() => {
      this.markTimer = -1;
      if (this.screen.kind === 'notifications') { this.markRead(); }
    }, 4500);
  }

  private async markRead(notice?: GitHubNotification): Promise<void> {
    if (!this.login || this.actionBusy) { return; }
    this.pendingAction = '';
    this.actionBusy = true;
    const serial = this.serial;
    try {
      if (notice === undefined) {
        await GitHub.markNotificationsRead();
        if (serial === this.serial) {
          this.screen.hint = '所有通知已标为已读';
          this.screen.notifications = [];
          this.refresh();
        }
      } else {
        await GitHub.markNotificationRead(notice.id);
        const prior = this.history[this.history.length - 1];
        if (prior && prior.kind === 'notifications') {
          prior.notifications = prior.notifications.filter((item: GitHubNotification) => item.id !== notice.id);
          prior.loaded = false;
        }
        if (serial === this.serial) { this.screen.hint = '已标记为已读'; this.screen.notification = undefined; }
      }
    } catch (e) {
      if (serial === this.serial) { this.screen.hint = this.message(e as Object, '标记失败，请检查手表网络'); }
    } finally { this.actionBusy = false; }
  }

  private async repoAction(action: string): Promise<void> {
    if (this.actionBusy || !this.login || !this.screen.slug) { return; }
    this.actionBusy = true;
    this.pendingAction = '';
    const serial = this.serial;
    const slug = this.screen.slug;
    const target = action === 'star' ? !this.screen.starred : !this.screen.watching;
    try {
      if (action === 'star') {
        await GitHub.setStarred(slug, target);
        if (serial === this.serial) { this.screen.starred = target; this.screen.hasStarsState = true; }
      } else if (action === 'watch') {
        await GitHub.setWatching(slug, target);
        if (serial === this.serial) { this.screen.watching = target; this.screen.hasWatchState = true; }
      } else {
        const forked = await GitHub.fork(slug);
        if (serial === this.serial) { this.screen.hint = `Fork 已提交：${forked.full_name}`; }
      }
    } catch (e) {
      if (serial === this.serial) { this.screen.hint = this.message(e as Object, '操作未确认，请刷新后检查状态'); }
    } finally { this.actionBusy = false; }
  }

  private async openGitHub(url: string): Promise<void> {
    if (!/^https:\/\/github\.com\/[A-Za-z0-9_.\/-]+(?:\?[^#\s]*)?(?:#[^\s]*)?$/i.test(url)) { return; }
    const serial = this.serial;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ctx.openLink(url);
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '此手表没有可打开 GitHub 链接的应用'; }
    }
  }

  private async load(append: boolean = false): Promise<void> {
    if (this.screen.busy || (this.screen.loaded && !append)) {
      return;
    }
    const kind = this.screen.kind;
    if (!['home', 'search', 'repo', 'readme', 'file', 'tree', 'branches', 'releases', 'notifications', 'issue', 'starred', 'threads'].includes(kind) ||
      (kind === 'search' && !this.screen.query) || (['notifications', 'starred'].includes(kind) && !this.login) ||
      (kind === 'issue' && this.screen.issueNumber < 1 && this.screen.notification?.subject.type !== 'Release')) {
      return;
    }
    const ticket = ++this.serial;
    this.screen.error = '';
    this.screen.busy = true;
    const page = append ? this.screen.page + 1 : 1;
    const slug = this.screen.slug;
    const path = this.screen.path;
    const ref = this.screen.ref;
    try {
      if (kind === 'home' || kind === 'search') {
        const tab = this.screen.tab;
        const q = kind === 'home' ? listQuery(tab, this.screen.month) : this.screen.query;
        const sort = kind === 'search' ? '' : (tab === 1 ? 'stars' : 'updated');
        const result = await GitHub.search(q, sort, page);
        if (ticket !== this.serial) { return; }
        const combined = append ? this.screen.repos.slice() : [];
        for (const repo of result.items) {
          if (!combined.some((item: Repo) => item.id === repo.id)) { combined.push(repo); }
        }
        this.screen.repos = combined;
        this.screen.more = result.items.length === PAGE_SIZE && page * PAGE_SIZE < Math.min(1000, result.total_count);
      } else if (kind === 'repo') {
        if (this.screen.repo === undefined) {
          const repo = await GitHub.repo(slug);
          if (ticket !== this.serial) { return; }
          this.screen.repo = repo;
          this.screen.slug = repo.full_name;
        }
        // A failed optional chart must not block the summary or the other tabs.
        try {
          const language = await GitHub.languages(this.screen.slug);
          if (ticket !== this.serial) { return; }
          this.screen.language = language;
        } catch (_) {}
        if (ticket !== this.serial) { return; }
        if (this.login) {
          await Promise.all([this.loadRepoToggle(ticket, true), this.loadRepoToggle(ticket, false)]);
        }
      } else if (kind === 'readme' || kind === 'file') {
        const text = kind === 'readme' ? await GitHub.readme(slug) : await GitHub.file(slug, path, ref);
        if (ticket !== this.serial) { return; }
        if (kind === 'file' && (text.includes('\u0000') || text.slice(0, 512).includes('\ufffd'))) {
          this.screen.hint = '这是二进制或非 UTF-8 文件，无法预览';
        } else if (kind === 'readme') {
          this.screen.markdown = text;
        } else {
          this.screen.parts = textPages(text);
        }
      } else if (kind === 'tree') {
        const items = await GitHub.contents(slug, path, ref);
        if (ticket !== this.serial) { return; }
        this.screen.tree = items;
      } else if (kind === 'branches') {
        const branches = await GitHub.branches(slug, page);
        if (ticket !== this.serial) { return; }
        this.screen.branches = append ? this.screen.branches.concat(branches) : branches;
        this.screen.more = branches.length === PAGE_SIZE;
      } else if (kind === 'releases') {
        const releases = await GitHub.releases(slug, page);
        if (ticket !== this.serial) { return; }
        this.screen.releases = append ? this.screen.releases.concat(releases) : releases;
        this.screen.more = releases.length === PAGE_SIZE;
      } else if (kind === 'notifications') {
        const items = await GitHub.notifications(page, { all: this.screen.tab !== 0 });
        if (ticket !== this.serial) { return; }
        const unique = append ? this.screen.notifications.slice() : [];
        for (const item of items) {
          if (!unique.some((old: GitHubNotification) => old.id === item.id)) { unique.push(item); }
        }
        this.screen.notifications = unique;
        this.screen.more = items.length === PAGE_SIZE;
      } else if (kind === 'starred') {
        const items = await GitHub.starred(page);
        if (ticket !== this.serial) { return; }
        this.screen.repos = append ? this.screen.repos.concat(items) : items;
        this.screen.more = items.length === PAGE_SIZE;
      } else if (kind === 'threads') {
        const found = await GitHub.repoThreads(slug, this.screen.pull, this.screen.tab === 1, page);
        if (ticket !== this.serial) { return; }
        const combined = append ? this.screen.threads.slice() : [];
        for (const thread of found.items) {
          if (!combined.some((old: RepoThread) => old.number === thread.number)) { combined.push(thread); }
        }
        this.screen.threads = combined;
        this.screen.more = found.more;
      } else if (kind === 'issue') {
        const notice = this.screen.notification;
        if (notice?.subject.type === 'Release') {
          const release = await GitHub.noticeRelease(notice);
          if (ticket !== this.serial) { return; }
          this.screen.release = release;
          this.screen.markdown = release?.body ?? '';
        } else {
          const number = this.screen.issueNumber;
          if (!append) {
            const issue = await GitHub.issueOrPullDetail(slug, number, this.screen.pull);
            if (ticket !== this.serial) { return; }
            this.screen.issue = issue;
            this.screen.markdown = issue.body ?? '';
            this.screen.query = issue.html_url;
          }
          const noticeTask = !append && notice !== undefined ? this.loadTargetComment(ticket, notice) : Promise.resolve();
          try {
            const comments = await GitHub.issueComments(slug, number, page);
            if (ticket !== this.serial) { return; }
            this.screen.comments = append ? this.screen.comments.concat(comments) : comments;
            this.screen.more = comments.length === PAGE_SIZE;
          } catch (error) {
            if (append) { throw error as Error; }
            if (ticket === this.serial) { this.screen.hint = '讨论暂时无法读取，可刷新重试'; }
          }
          await noticeTask;
        }
      }
      if (ticket === this.serial) {
        this.screen.loaded = true;
        this.screen.page = page;
      }
    } catch (e) {
      if (ticket === this.serial) {
        this.screen.error = this.message(e as Object, '加载失败，请检查手表是否能连接 GitHub');
      }
    } finally {
      if (ticket === this.serial) {
        this.screen.busy = false;
      }
    }
  }

  private async loadTargetComment(ticket: number, notice: GitHubNotification): Promise<void> {
    try {
      const comment = await GitHub.noticeComment(notice);
      if (ticket === this.serial) { this.screen.targetComment = comment; }
    } catch (_) {} // The ordinary Issue/PR discussion remains available.
  }

  private openComment(comment: IssueComment): void {
    const next = this.fromRepo('comment', '讨论回复');
    next.title = comment.login ? `@${comment.login}` : next.title;
    next.query = comment.html_url;
    next.markdown = comment.body;
    this.open(next);
  }

  private async loadRepoToggle(ticket: number, star: boolean): Promise<void> {
    const slug = this.screen.slug;
    try {
      const value = star ? await GitHub.isStarred(slug) : await GitHub.isWatching(slug);
      if (ticket !== this.serial) { return; }
      if (star) { this.screen.starred = value; this.screen.hasStarsState = true; }
      else { this.screen.watching = value; this.screen.hasWatchState = true; }
    } catch (_) {}
  }

  private prepareTransfer(spec?: DownloadSpec): void {
    this.downloadSpec = spec;
    this.open(new Screen('transfer', '下载'));
  }

  private sourceDownload(repo: Repo): void {
    if (repo.private) { this.screen.hint = '私有仓库暂不支持直接下载'; return; }
    try {
      this.prepareTransfer(Downloads.sourceZip(repo.full_name, this.screen.ref || repo.default_branch || 'HEAD'));
    } catch (_) { this.screen.hint = '这个分支暂时无法下载'; }
  }

  private releaseDownload(asset: Asset): void {
    const release = this.screen.release;
    if (release === undefined) { return; }
    if (this.screen.repo?.private) { this.screen.hint = '私有附件暂不支持直接下载'; return; }
    try {
      this.prepareTransfer(Downloads.releaseAsset(this.screen.slug, release.tag_name, asset.name, asset.size));
    } catch (_) { this.screen.hint = '附件无法下载，可能超过手表容量限制'; }
  }

  private async transferAction(action: string): Promise<void> {
    const downloads = this.downloads;
    if (downloads === undefined) { return; }
    const serial = this.serial;
    try {
      if (action === 'start' && this.downloadSpec !== undefined) { await downloads.start(this.downloadSpec); }
      else if (action === 'pause') { await downloads.pause(); }
      else if (action === 'resume') { await downloads.resume(); }
      else if (action === 'cancel') { await downloads.cancel(); }
      else if (action === 'retry') { await downloads.retry(); }
      else if (action === 'export') {
        const saved = await downloads.exportFile();
        if (serial === this.serial) { this.screen.hint = saved ? '已导出文件' : '文件仍保存在应用内；本机可能没有文件保存器'; }
      }
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '下载操作失败，请检查网络或可用空间'; }
    }
  }

  private async testSpeed(custom: boolean): Promise<void> {
    const downloads = this.downloads;
    if (downloads === undefined || this.actionBusy) { return; }
    const url = this.mirrorDraft.trim();
    if (custom && !url) { this.screen.hint = '请输入一个公开 HTTPS 下载文件地址'; return; }
    this.actionBusy = true;
    const serial = this.serial;
    this.screen.hint = '正在测试下载连接…';
    try {
      const result = await downloads.speedTest(custom ? url : undefined);
      if (custom) {
        this.mirror = url;
        this.prefs?.putSync('speed_endpoint', url);
        await this.prefs?.flush();
      }
      if (serial === this.serial) {
        this.screen.hint = `${result.source}\n${sizeLabel(result.bytesPerSecond)}/s · ${result.elapsedMs} ms`;
      }
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '测速失败；请检查网络，或确认地址支持直连和 Range'; }
    } finally { this.actionBusy = false; }
  }

  private async fetchOtp(): Promise<void> {
    const serial = this.serial;
    try {
      const entries = await Vault.listTotp();
      if (serial === this.serial) { this.otpEntries = entries; }
    } catch (_) {
      if (serial === this.serial) { this.otpEntries = []; this.screen.hint = '无法读取验证码，请解锁手表后重试'; }
    }
  }

  private openOtp(): void {
    this.open(new Screen('otp', '双因素验证码'));
    this.fetchOtp();
  }

  private async saveOtp(): Promise<void> {
    if (this.actionBusy) { return; }
    const seed = this.otpDraft.trim();
    this.otpDraft = '';
    this.clearKeyboardFocus();
    if (!seed) { this.screen.hint = '请输入 Base32 密钥或 otpauth 链接'; return; }
    this.actionBusy = true;
    const serial = this.serial;
    try {
      await Vault.saveTotp(this.otpTitle.trim(), seed);
      if (serial === this.serial) { this.back(); this.fetchOtp(); }
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '无法添加；请检查账户名称、密钥格式及安全存储'; }
    } finally { this.actionBusy = false; }
  }

  private async removeOtp(): Promise<void> {
    if (this.actionBusy) { return; }
    this.actionBusy = true;
    const serial = this.serial;
    try {
      await Vault.removeTotp(this.screen.query);
      if (serial === this.serial) { this.back(); this.fetchOtp(); }
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '无法移除验证码'; }
    } finally { this.actionBusy = false; }
  }

  private openOtpCode(entry: TotpAccount): void {
    const next = new Screen('otpCode', entry.label);
    next.query = entry.id;
    this.open(next);
  }

  private startOtpClock(): void {
    this.stopOtpClock();
    this.tickOtp();
    this.otpTimer = setInterval(() => { this.tickOtp(); }, 350);
  }

  private stopOtpClock(): void {
    if (this.otpTimer >= 0) { clearInterval(this.otpTimer); }
    this.otpTimer = -1;
    this.otpExpires = 0;
    this.otpValue = '';
    this.otpRemaining = 0;
  }

  private async tickOtp(): Promise<void> {
    if (this.screen.kind !== 'otpCode') { return; }
    const now = Date.now();
    if (this.otpExpires > now) {
      this.otpRemaining = Math.ceil((this.otpExpires - now) / 1000);
      return;
    }
    this.otpValue = '';
    this.otpRemaining = 0;
    if (this.otpLoading) { return; }
    this.otpLoading = true;
    const serial = this.serial;
    try {
      const code = await Vault.codeFor(this.screen.query, now);
      if (serial !== this.serial || this.otpTimer < 0) { return; }
      this.otpExpires = (Math.floor(now / (code.period * 1000)) + 1) * code.period * 1000;
      if (this.otpExpires > Date.now()) { this.otpValue = code.code; this.otpRemaining = code.remainingSeconds; }
    } catch (_) {
      if (serial === this.serial) { this.screen.hint = '验证码不可用，请检查手表时间和锁屏状态'; this.stopOtpClock(); }
    } finally { this.otpLoading = false; }
  }

  private jump(page: number): void {
    this.screen.page = page;
    this.scrollToOffset(0);
  }

  @Builder
  pill(label: string, selected: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule })
      .fontSize(12).fontWeight(FontWeight.Medium)
      .fontColor(selected ? this.theme().accentText : this.theme().blue).backgroundColor(selected ? this.theme().blue : this.theme().pale)
      .height(34).padding({ left: 8, right: 8 }).layoutWeight(1)
      .onClick(action)
  }

  @Builder
  actionButton(label: string, enabled: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule }).fontSize(12).fontColor(this.theme().blue).backgroundColor(this.theme().pale)
      .width('91%').height(35).enabled(enabled).onClick(action)
  }

  @Builder
  quiet(message: string) {
    Text(message).fontSize(12).fontColor(this.theme().muted).lineHeight(18).textAlign(TextAlign.Center)
      .width('100%').padding({ top: 9, bottom: 9, left: 8, right: 8 })
  }

  @Builder
  header() {
    if (this.screen.kind === 'home') {
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Blank().width(13).height(2).borderRadius(1).backgroundColor(this.theme().blue)
          Text('WRIST / GIT').fontSize(9).fontWeight(FontWeight.Bold).letterSpacing(1.5).fontColor(this.theme().blue)
        }.width('100%')
        Row({ space: 5 }) {
          Text('腕上 Git').fontSize(27).fontWeight(FontWeight.Bold).letterSpacing(-0.9).fontColor(this.theme().ink)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Stack() {
            if (this.enhanced) {
              Circle().width(32).height(32).fill('#F5F8FC')
              Image($r('app.media.github_invertocat')).width(19).height(19).objectFit(ImageFit.Contain)
            } else {
              Text('Git').fontSize(10).fontWeight(FontWeight.Bold).fontColor(this.theme().blue)
            }
          }.width(32).height(32).focusable(true).accessibilityText('GitHub 集成 · 打开腕上 Git 项目')
            .onClick(() => { this.openGitHub('https://github.com/chx404/wrist-git-watch'); })
        }.width('100%').alignItems(VerticalAlign.Center)
        Text('用一块表，逛开源。').fontSize(11).fontColor(this.theme().muted).width('100%')
        if (this.guideHint) {
          Button('新手指南 ›', { type: ButtonType.Capsule }).height(27).fontSize(11)
            .fontColor(this.theme().blue).backgroundColor(this.theme().pale).onClick(() => this.showGuide())
        }
      }.width('75%').alignItems(HorizontalAlign.Start).padding({ top: 3, bottom: 3 })
    } else {
      if (!ROOT_KINDS.includes(this.screen.kind)) {
        Button('‹ 返回', { type: ButtonType.Capsule })
          .fontSize(12).fontColor(this.theme().blue).backgroundColor(this.theme().pale).height(32)
          .padding({ left: 14, right: 14 }).onClick(() => { this.back(); })
      }
      Text(this.screen.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.theme().ink).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center).width('72%')
      if (this.screen.slug && this.screen.kind !== 'file') {
        Text(this.screen.slug).fontSize(11).fontColor(this.theme().muted).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center).width('78%')
      }
    }
  }

  @Builder
  repoCard(repo: Repo) {
    Row({ space: 8 }) {
      Text(repo.name.slice(0, 1).toUpperCase()).width(24).height(24)
        .textAlign(TextAlign.Center).fontColor(this.theme().blue).backgroundColor(this.theme().pale).borderRadius(7)
        .fontSize(12).fontWeight(FontWeight.Bold)
      Column({ space: 3 }) {
        Text(repo.full_name).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.theme().ink)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (repo.description) {
          Text(repo.description).fontSize(11).lineHeight(15).fontColor(this.theme().muted)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        Text(`★ ${compact(repo.stargazers_count)}${repo.language ? '  ·  ' + repo.language : ''}`)
          .fontSize(10).fontColor(this.theme().blue).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(16).fontColor(this.theme().muted)
    }
    .width('100%').constraintSize({ minHeight: 53 }).padding({ left: 8, right: 8, top: 7, bottom: 7 })
    .alignItems(VerticalAlign.Center).backgroundColor(this.theme().card).borderRadius(13).border({ width: 1, color: this.theme().border })
    .focusable(true).onClick(() => this.openRepo(repo.full_name, repo))
  }

  @Builder
  repoSummary(repo: Repo) {
    Column({ space: 8 }) {
      Text(repo.name).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.theme().ink).wordBreak(WordBreak.BREAK_ALL)
      Text(repo.description || '此仓库没有说明').fontSize(12).lineHeight(18).fontColor(this.theme().muted)
      Text(`★ ${compact(repo.stargazers_count)}   ·   Fork ${compact(repo.forks_count)}`)
        .fontSize(12).fontColor(this.theme().blue).fontWeight(FontWeight.Medium)
      Text(`Issues / PR ${compact(repo.open_issues_count)}  ·  ${repo.default_branch}`)
        .fontSize(11).fontColor(this.theme().muted).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.screen.language.length > 0) {
        Row() {
          ForEach(this.screen.language, (item: LanguageSlice, index: number) => {
            Row().width(`${item.share}%`).height(5).backgroundColor(this.theme().chart[index])
          }, (item: LanguageSlice) => item.name)
        }.width('100%').borderRadius(3).clip(true)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.screen.language, (item: LanguageSlice, index: number) => {
            Text(`● ${item.name} ${Math.round(item.share)}%`).fontSize(10).fontColor(this.theme().chart[index])
              .margin({ right: 8, bottom: 3 })
          }, (item: LanguageSlice) => item.name)
        }.width('100%')
      } else if (repo.language) {
        Text(repo.language).fontSize(11).fontColor(this.theme().muted)
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(11).backgroundColor(this.theme().card)
      .borderRadius(15).border({ width: 1, color: this.theme().border })
    if (!repo.private) {
      Button(this.isSaved(repo.full_name) ? '★ 已收藏 · 点击取消' : '☆ 收藏到手表', { type: ButtonType.Capsule })
        .fontSize(12).fontColor(this.theme().blue).backgroundColor(this.theme().pale).height(36).width('88%')
        .enabled(!this.actionBusy).onClick(() => { this.toggleSave(repo); })
      this.actionButton('加入收藏分组', !this.actionBusy, () => this.showGroups(repo))
    }
    if (this.login) {
      Row({ space: 5 }) {
        this.pill(this.screen.starred ? '取消 Star' : 'Star', this.screen.starred, () => {
          if (this.screen.hasStarsState) { this.repoAction('star'); }
          else { this.screen.hint = '未读到星标状态，请刷新或检查令牌权限'; }
        })
        this.pill(this.screen.watching ? '退订' : '订阅', this.screen.watching, () => {
          if (this.screen.hasWatchState) { this.repoAction('watch'); }
          else { this.screen.hint = '未读到订阅状态，请刷新或检查令牌权限'; }
        })
      }.width('100%')
      if (this.pendingAction === 'fork') {
        this.quiet(`Fork 到 @${this.login}？`)
        this.actionButton('确认创建 Fork', !this.actionBusy, () => { this.repoAction('fork'); })
        this.actionButton('取消', true, () => { this.pendingAction = ''; })
      } else { this.actionButton('Fork 到我的账户', !this.actionBusy, () => { this.pendingAction = 'fork'; }) }
    } else {
      this.actionButton('连接 GitHub 以 Star / 订阅', this.authReady, () => this.open(new Screen('settings', '连接与设置')))
    }
    Row({ space: 5 }) {
      this.pill('Issues', false, () => this.viewThreads(false, false))
      this.pill('PR', false, () => this.viewThreads(true, false))
    }.width('100%')
    if (!repo.private) { this.actionButton('下载源码 ZIP', true, () => this.sourceDownload(repo)) }
    this.actionButton('仓库链接与 Clone 地址', true, () => this.open(this.fromRepo('links', '仓库链接')))
    this.actionButton('刷新仓库', !this.screen.busy && !this.actionBusy, () => this.refresh())
    if (this.saveError) { this.quiet(this.saveError) }
  }

  private openSearchInput(): void {
    if (this.screen.kind !== 'search' || this.floorOpen || this.guideOpen) { return; }
    this.searchInputOpen = true;
    this.cancelFocus();
    const ticket = this.serial;
    setTimeout(() => {
      if (ticket !== this.serial || !this.searchInputOpen || this.touchDown || this.floorOpen) { return; }
      try { this.getUIContext().getFocusController().requestFocus('wrist-repo-input'); } catch (_) {}
    }, 75);
  }

  @Builder
  searchBox() {
    Column({ space: 7 }) {
      if (this.searchInputOpen) {
        TextInput({ placeholder: '关键词 / owner/repo', text: this.input })
          .id('wrist-repo-input').width('100%').height(36).fontSize(13).fontColor(this.theme().ink).placeholderColor(this.theme().muted)
          .backgroundColor(this.theme().card).borderRadius(18).border({ width: 1, color: this.theme().border })
          .maxLength(250).enterKeyType(EnterKeyType.Search).focusOnTouch(false)
          .onChange((value: string) => { this.input = value; }).onSubmit(() => this.submit())
          .onClick(() => this.openSearchInput())
          .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
        Row({ space: 5 }) {
          this.pill('搜索', true, () => this.submit())
          this.pill('收起', false, () => {
            this.clearKeyboardFocus();
            this.searchInputOpen = false;
            this.editorFocus(false);
            this.focusSurface();
          })
        }.width('100%')
      } else {
        Button(this.input ? `编辑：${this.input}` : '输入关键词或仓库名 ›', { type: ButtonType.Capsule })
          .fontSize(12).fontColor(this.theme().blue).height(32).width('90%').backgroundColor(this.theme().pale)
          .onClick(() => this.openSearchInput())
      }
      PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
        .fontSize(12).width('85%').height(33).backgroundColor(this.theme().pale).fontColor(this.theme().blue)
        .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
          if (result === PasteButtonOnClickResult.SUCCESS) { this.pasteRepository(); }
          else { this.screen.hint = '系统没有授权这次粘贴，可在输入框中手动输入'; }
        })
      if (!this.screen.query && !this.screen.hint) { this.quiet('也可输入 GitHub 仓库链接') }
    }.width('100%')
  }

  @Builder
  qrZoomOverlay() {
    Stack() {
      Column() {
        if (this.qrZoomCell > 0 && this.qrSymbol !== undefined) {
          Path({ width: this.qrBoxModules() * this.qrZoomCell, height: this.qrBoxModules() * this.qrZoomCell,
            commands: this.qrCommands(this.qrZoomCell) }).fill('#000000')
        }
        Text('点按收起').fontSize(11).fontColor('#000000').margin({ top: 10 })
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
      .padding(12).clip(true)
      .onClick(() => { this.qrZoom = false; this.qrZoomCell = 0; })
      .onAreaChange((_old: Area, next: Area) => {
        const edge = Math.min(Number(next.width), Number(next.height));
        const modules = this.qrBoxModules();
        if (Number.isFinite(edge) && edge > 24 && modules > 1) {
          const cell = Math.max(1, Math.floor((edge - 24) / modules));
          if (cell !== this.qrZoomCell) { this.qrZoomCell = cell; }
        }
      })
  }

  @Builder
  deviceAuthBody() {
    if (this.screen.deviceStatus) { this.quiet(this.screen.deviceStatus) }
    if (this.screen.userCode) {
      Text('验证码').fontSize(10).fontColor(this.theme().muted)
      Text(this.screen.userCode).fontSize(25).fontWeight(FontWeight.Bold).letterSpacing(2)
        .fontFamily('monospace').fontColor(this.theme().ink).copyOption(CopyOptions.LocalDevice)
      Stack() {
        Column().width('100%').height('100%').backgroundColor('#FFFFFF')
        if (this.qrCell > 0 && this.qrSymbol !== undefined) {
          Path({ width: this.qrBoxModules() * this.qrCell, height: this.qrBoxModules() * this.qrCell,
            commands: this.qrCommands(this.qrCell) }).fill('#000000')
        }
      }.width('96%').aspectRatio(1).borderRadius(10).clip(true).backgroundColor('#FFFFFF').padding(8)
        .onClick(() => { if (this.qrSymbol !== undefined) { this.qrZoom = true; } })
        .onAreaChange((_old: Area, next: Area) => {
          const width = Number(next.width);
          const modules = this.qrBoxModules();
          if (Number.isFinite(width) && width > 8 && modules > 1) {
            const cell = Math.max(1, Math.floor((width - 16) / modules));
            if (cell !== this.qrCell) { this.qrCell = cell; }
          }
        })
      Text('用手机扫一扫，在手机上点「授权」').fontSize(11).fontColor(this.theme().muted).textAlign(TextAlign.Center)
      Text('点按二维码可全屏放大').fontSize(10).fontColor(this.theme().muted).textAlign(TextAlign.Center)
      Text(DeviceAuth.verificationUrl(this.screen.userCode)).fontSize(9).fontColor(this.theme().blue)
        .copyOption(CopyOptions.LocalDevice).width('90%').textAlign(TextAlign.Center)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    if (!this.screen.userCode && !this.screen.deviceStatus.includes('失败') && !this.screen.deviceStatus.includes('取消') &&
      !this.screen.deviceStatus.includes('过期')) {
      this.quiet('即将显示二维码和验证码')
    }
    this.actionButton('重新生成验证码', !this.actionBusy && this.screen.deviceStatus !== '', () => this.startDeviceAuth())
    this.actionButton('取消扫码连接', true, () => this.cancelDeviceAuth())
    this.quiet('验证码和二维码不含任何令牌；令牌只在授权完成后由 GitHub 发给手表。')
  }

  @Builder
  rowCard(badge: string, name: string, note: string, action: () => void) {
    Row({ space: 8 }) {
      Text(badge).width(21).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.theme().blue).textAlign(TextAlign.Center)
      Column({ space: 3 }) {
        Text(name).fontSize(13).fontColor(this.theme().ink).fontWeight(FontWeight.Medium)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (note) {
          Text(note).fontSize(10).fontColor(this.theme().muted).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(15).fontColor(this.theme().muted)
    }.width('100%').constraintSize({ minHeight: 42 }).padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(this.theme().card).borderRadius(12).border({ width: 1, color: this.theme().border }).focusable(true).onClick(action)
  }

  @Builder
  pageControl(count: number) {
    if (count > 1) {
      Row({ space: 5 }) {
        Button('‹', { type: ButtonType.Capsule }).width(38).height(33).fontSize(15).fontColor(this.theme().blue)
          .backgroundColor(this.theme().pale).enabled(this.screen.page > 1).onClick(() => this.jump(this.screen.page - 1))
        Text(`${this.screen.page} / ${count}`).fontSize(11).fontColor(this.theme().muted).layoutWeight(1).textAlign(TextAlign.Center)
        Button('›', { type: ButtonType.Capsule }).width(38).height(33).fontSize(15).fontColor(this.theme().blue)
          .backgroundColor(this.theme().pale).enabled(this.screen.page < count).onClick(() => this.jump(this.screen.page + 1))
      }.width('87%')
    }
  }

  private jumpAnchor(anchor: string): void {
    const ticket = this.serial;
    setTimeout(() => {
      if (ticket !== this.serial) { return; }
      try {
        const ui = this.getUIContext();
        const info = ui.getComponentUtils().getRectangleById(`markdown-anchor-${anchor}`);
        if (info.size.height > 0) {
          const current = this.scroller?.currentOffset()?.yOffset ?? 0;
          this.scroller?.scrollTo({ xOffset: 0, yOffset: Math.max(0, current + ui.px2vp(info.windowOffset.y) - 45), animation: false });
          return;
        }
      } catch (_) {}
      this.scrollToOffset(0);
    }, 70);
  }

  @Builder
  formatted(markdown: string) {
    MarkdownView({ markdown, embedded: true, dark: this.dark,
      repoSlug: this.screen.kind === 'readme' ? this.screen.slug : '',
      repoRef: this.screen.kind === 'readme' ? (this.screen.repo?.default_branch || 'HEAD') : '',
      onPageChange: (_page: number) => this.scrollToOffset(0),
      onAnchor: (anchor: string, _page: number) => this.jumpAnchor(anchor) })
  }

  @Builder
  settingsBody() {
    this.quiet(this.authReady ? (this.login ? `GitHub · @${this.login}` : 'GitHub · 游客模式') : '正在读取本机安全存储')
    TextInput({ placeholder: 'GitHub 个人访问令牌', text: this.tokenDraft })
      .width('100%').height(37).fontSize(12).fontColor(this.theme().ink).placeholderColor(this.theme().muted).backgroundColor(this.theme().card)
      .type(InputType.Password).showPasswordIcon(false).enableAutoFill(false).maxLength(240)
      .onChange((value: string) => { this.tokenDraft = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false)).onSubmit(() => { this.authenticate(); })
    this.actionButton(this.login ? '验证并更新令牌' : '验证并连接 GitHub', this.authReady && !this.actionBusy, () => { this.authenticate(); })
    this.quiet('通知通常需要 classic 令牌的 notifications 权限；私库或账户操作按需授权。令牌不上传到第三方。')
    this.actionButton('扫码连接 GitHub（推荐）', !this.actionBusy, () => this.openDeviceAuth())
    TextInput({ placeholder: '自定义 OAuth Client ID（可选）', text: this.oauthClientDraft })
      .width('100%').height(35).fontSize(12).fontColor(this.theme().ink).placeholderColor(this.theme().muted)
      .backgroundColor(this.theme().card).maxLength(40).enableAutoFill(false)
      .onChange((value: string) => { this.oauthClientDraft = value; })
      .onFocus(() => this.editorFocus(true))
      .onBlur(() => { this.editorFocus(false); this.saveOauthClientDraft(); })
    this.quiet('扫码连接默认使用 GitHub CLI 的公开 Client ID；可注册自己的 OAuth 应用后在这里填写。')
    if (this.login) {
      if (this.pendingAction === 'disconnect') {
        this.actionButton('确认移除本机令牌', !this.actionBusy, () => { this.disconnect(); })
        this.actionButton('取消', true, () => { this.pendingAction = ''; })
      } else { this.actionButton('登出（仅本机）', !this.actionBusy, () => { this.pendingAction = 'disconnect'; }) }
    }
    this.actionButton('本机双因素验证码', !this.actionBusy, () => this.openOtp())
    this.actionButton('网络与下载测速', true, () => {
      this.mirrorDraft = this.mirror;
      this.open(new Screen('speed', '连接测试'));
    })
    this.actionButton('下载任务', true, () => this.prepareTransfer())
    this.themePills()
    this.actionButton('重看新手教程', true, () => this.showGuide())
    this.actionButton(this.enhanced ? '关闭横滑分页与自定义表冠' : '启用横滑分页与表冠 · F30', true, () => this.tryEnhanced())
    this.quiet('腕上 Git 0.3.11 · 完整版')
  }

  @Builder
  speedBody() {
    this.actionButton('测速 · GitHub 官方', !this.actionBusy, () => { this.testSpeed(false); })
    this.quiet('也可以手动测试公开 HTTPS 下载源；不附带账号、令牌或仓库数据。')
    TextInput({ placeholder: 'https:// 下载测试地址', text: this.mirrorDraft })
      .width('100%').height(37).fontSize(12).fontColor(this.theme().ink).placeholderColor(this.theme().muted).backgroundColor(this.theme().card)
      .maxLength(240).enableAutoFill(false).onChange((value: string) => { this.mirrorDraft = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
    this.actionButton('测速 · 这个地址', !this.actionBusy, () => { this.testSpeed(true); })
    this.quiet('仅测试速度；GitHub 下载默认使用官方地址。')
  }

  @Builder
  otpBody() {
    if (this.screen.kind === 'otp') {
      ForEach(this.otpEntries, (entry: TotpAccount) => {
        this.rowCard('◈', entry.label, entry.issuer, () => this.openOtpCode(entry))
      }, (entry: TotpAccount) => entry.id)
      if (this.otpEntries.length === 0) { this.quiet('没有添加账户。密钥存入手表系统安全存储。') }
      this.actionButton('添加验证码账户', !this.actionBusy, () => {
        this.otpTitle = '';
        this.open(new Screen('otpAdd', '添加验证码'));
      })
    } else if (this.screen.kind === 'otpAdd') {
      TextInput({ placeholder: '账户名（URI 可省略）', text: this.otpTitle })
        .width('100%').height(35).fontSize(12).backgroundColor(this.theme().card).fontColor(this.theme().ink).maxLength(48)
        .onChange((value: string) => { this.otpTitle = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
      TextInput({ placeholder: 'Base32 密钥或 otpauth', text: this.otpDraft })
        .width('100%').height(36).fontSize(12).backgroundColor(this.theme().card).fontColor(this.theme().ink)
        .maxLength(512).type(InputType.Password).showPasswordIcon(false).enableAutoFill(false)
        .onChange((value: string) => { this.otpDraft = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
      this.actionButton('保存在这块手表', !this.actionBusy, () => { this.saveOtp(); })
      this.quiet('建议为手表设置锁屏密码。')
    } else {
      Text(this.otpValue || '— — —').fontFamily('monospace').fontSize(27).letterSpacing(2)
        .fontColor(this.theme().blue).fontWeight(FontWeight.Bold).privacySensitive(true).copyOption(CopyOptions.None)
      if (this.otpRemaining > 0) { this.quiet(`剩余 ${this.otpRemaining} 秒`) }
      if (this.pendingAction === 'removeOtp') {
        this.actionButton('确认删除本机密钥', !this.actionBusy, () => { this.removeOtp(); })
        this.actionButton('取消', true, () => { this.pendingAction = ''; })
      } else { this.actionButton('移除账户', !this.actionBusy, () => { this.pendingAction = 'removeOtp'; }) }
    }
  }

  @Builder
  transferBody() {
    if (this.download !== undefined) {
      if (this.download.name) { this.quiet(this.download.name) }
      if (this.download.phase === 'idle' && this.downloadSpec === undefined) { this.quiet('没有下载任务') }
      if (this.download.message) { this.quiet(this.download.message) }
      if (['starting', 'downloading', 'paused', 'cancelling'].includes(this.download.phase)) {
        Text(`${sizeLabel(this.download.receivedBytes)}${this.download.totalBytes >= 0 ? ' / ' + sizeLabel(this.download.totalBytes) : ''}`)
          .fontSize(13).fontColor(this.theme().blue).fontWeight(FontWeight.Medium)
        if (this.download.totalBytes > 0) {
          Progress({ value: this.download.receivedBytes, total: this.download.totalBytes, type: ProgressType.Linear })
            .width('86%').color(this.theme().blue)
        }
        if (this.download.phase === 'downloading') { this.actionButton('暂停', true, () => { this.transferAction('pause'); }) }
        if (this.download.phase === 'paused') { this.actionButton('继续', true, () => { this.transferAction('resume'); }) }
        if (this.download.phase !== 'cancelling') { this.actionButton('取消下载', true, () => { this.transferAction('cancel'); }) }
      } else {
        if (this.download.phase === 'completed') { this.actionButton('导出已下载文件', true, () => { this.transferAction('export'); }) }
        if (this.download.phase === 'failed' || this.download.phase === 'cancelled') {
          this.actionButton('重试上个任务', true, () => { this.transferAction('retry'); })
        }
        if (this.downloadSpec !== undefined) {
          this.quiet(this.downloadSpec.assetName || `${this.downloadSpec.slug} · 源码 ZIP`)
          this.actionButton('开始下载', true, () => { this.transferAction('start'); })
        }
      }
      this.quiet('公开文件 · 最大 32 MB · 同时只下载一个')
    }
  }

  @Builder
  document() {
    if (this.screen.kind === 'file') {
      this.quiet(this.screen.ref)
      if (this.screen.parts.length > 0) {
        this.actionButton(this.screen.tab === 0 ? '自动换行 · 点击切换' : '横向滚动 · 点击切换', true, () => {
          this.screen.tab = this.screen.tab === 0 ? 1 : 0;
        })
        this.pageControl(this.screen.parts.length)
        if (this.screen.tab === 0) {
          Text(this.screen.parts[this.screen.page - 1]).fontSize(11).lineHeight(17).fontFamily('monospace')
            .fontColor(this.theme().ink).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            .width('100%').padding(10).backgroundColor(this.theme().card).borderRadius(13).border({ width: 1, color: this.theme().border })
        } else {
          Scroll() {
            Text(this.screen.parts[this.screen.page - 1]).fontSize(11).lineHeight(17).fontFamily('monospace')
              .fontColor(this.theme().ink).copyOption(CopyOptions.LocalDevice).padding(10)
          }.scrollable(ScrollDirection.Horizontal).width('100%').align(Alignment.TopStart)
            .backgroundColor(this.theme().card).borderRadius(13).border({ width: 1, color: this.theme().border })
        }
        this.pageControl(this.screen.parts.length)
      }
    } else if (this.screen.kind === 'readme') {
      if (this.screen.markdown || this.screen.loaded) { this.formatted(this.screen.markdown) }
    } else if (this.screen.kind === 'release' && this.screen.release !== undefined) {
      Text(this.screen.release.name || this.screen.release.tag_name).fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.theme().ink).width('100%').wordBreak(WordBreak.BREAK_ALL)
      this.quiet(`${this.screen.release.published_at?.slice(0, 10) ?? ''}${this.screen.release.prerelease ? ' · 预发布' : ''}`)
      if (this.screen.release.assets.length > 0) {
        this.actionButton(`附件 · ${this.screen.release.assets.length} 个`, true, () => {
          const next = this.fromRepo('assets', '发布附件');
          next.release = this.screen.release;
          this.open(next);
        })
      }
      this.formatted(this.screen.markdown)
    }
  }

  @Builder
  noticesBody() {
    if (!this.authReady) {
      this.quiet('正在读取 GitHub 登录状态')
    } else if (!this.login) {
      this.quiet('登录后在腕上看 Issue、PR 和订阅更新。')
      this.actionButton('连接 GitHub', true, () => this.open(new Screen('settings', '连接与设置')))
    } else {
      Row({ space: 4 }) {
        this.pill('未读', this.screen.tab === 0, () => this.noticesFilter(0, this.screen.reason))
        this.pill('全部', this.screen.tab === 1, () => this.noticesFilter(1, this.screen.reason))
        this.pill('订阅', this.screen.tab === 2, () => this.noticesFilter(2, 0))
      }.width('100%')
      if (this.screen.tab !== 2) {
        Row({ space: 4 }) {
          this.pill('所有', this.screen.reason === 0, () => this.noticesFilter(this.screen.tab, 0))
          this.pill('我创建', this.screen.reason === 1, () => this.noticesFilter(this.screen.tab, 1))
        }.width('95%')
        Row({ space: 4 }) {
          this.pill('被指派', this.screen.reason === 2, () => this.noticesFilter(this.screen.tab, 2))
          this.pill('提及我', this.screen.reason === 3, () => this.noticesFilter(this.screen.tab, 3))
        }.width('95%')
      }
      if (this.screen.hint) { this.quiet(this.screen.hint) }
      if (this.pendingAction === 'markWaiting') {
        this.quiet('即将标记全部已读；可先撤销。')
        this.actionButton('撤销', true, () => this.cancelMark())
      } else if (this.pendingAction === 'markAll') {
        this.quiet('将所有 GitHub 通知标为已读，不限当前筛选。')
        this.actionButton('确认全部已读', !this.actionBusy, () => this.markLater())
        this.actionButton('取消', true, () => { this.pendingAction = ''; })
      } else {
        this.actionButton('全部标为已读', !this.actionBusy && !this.screen.busy, () => { this.pendingAction = 'markAll'; })
      }
      ForEach(this.visibleNotices(), (notice: GitHubNotification) => {
        this.rowCard(notice.unread ? '●' : '○', notice.subject.title,
          `${notice.subject.type === 'PullRequest' ? 'PR' : notice.subject.type} · ${notice.repository.full_name}`,
          () => this.openNotice(notice))
      }, (notice: GitHubNotification) => notice.id)
      if (this.screen.loaded && this.visibleNotices().length === 0) {
        this.quiet(this.screen.more ? '这页没有符合筛选的通知，可以继续加载。' : '没有符合筛选的通知。')
      }
      this.actionButton('刷新通知', !this.screen.busy && !this.actionBusy && !this.pendingAction, () => this.refresh())
    }
  }

  @Builder
  threadsBody() {
    Row({ space: 4 }) {
      this.pill('未关闭', this.screen.tab === 0, () => { if (this.screen.tab !== 0) { this.viewThreads(this.screen.pull, false); } })
      this.pill('已关闭', this.screen.tab === 1, () => { if (this.screen.tab !== 1) { this.viewThreads(this.screen.pull, true); } })
    }.width('100%')
    ForEach(this.screen.threads, (thread: RepoThread) => {
      this.rowCard(this.screen.pull ? '⇄' : '◉', thread.title, `#${thread.number} · ${thread.updated_at.slice(0, 10)}`,
        () => this.openThread(thread))
    }, (thread: RepoThread) => `${thread.number}`)
    if (this.screen.loaded && this.screen.threads.length === 0) {
      this.quiet(this.screen.more ? '当前页没有匹配项目，可以继续加载。' : '没有匹配项目。')
    }
  }

  @Builder
  issueBody() {
    if (this.screen.notification !== undefined && this.screen.notification.unread) {
      this.actionButton('将此通知标为已读', !this.actionBusy && !this.screen.busy, () => { this.markRead(this.screen.notification); })
    }
    if (this.screen.targetComment !== undefined) {
      this.actionButton('跳到通知对应的评论', true, () => {
        if (this.screen.targetComment !== undefined) { this.openComment(this.screen.targetComment); }
      })
    }
    if (this.screen.release !== undefined) {
      Text(this.screen.release.name || this.screen.release.tag_name).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme().ink)
        .width('100%').wordBreak(WordBreak.BREAK_ALL)
      this.formatted(this.screen.markdown)
    } else if (this.screen.issue !== undefined) {
      Text(this.screen.issue.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme().ink)
        .width('100%').wordBreak(WordBreak.BREAK_ALL)
      this.quiet(`#${this.screen.issue.number} · @${this.screen.issue.login} · ${this.screen.issue.merged ? '已合并' : this.screen.issue.state}`)
      if (this.screen.markdown) { this.formatted(this.screen.markdown) }
      if (this.screen.comments.length > 0) {
        this.quiet('讨论')
        ForEach(this.screen.comments, (comment: IssueComment) => {
          this.rowCard('↳', `@${comment.login}`, comment.body.replace(/\s+/g, ' ').slice(0, 112), () => this.openComment(comment))
        }, (comment: IssueComment) => `${comment.id}`)
      }
    } else if (this.screen.notification !== undefined) {
      this.quiet(this.screen.notification.subject.title)
    }
    if (this.screen.issueNumber > 0) {
      this.actionButton('刷新讨论', !this.screen.busy, () => this.refresh())
    }
    if (this.screen.slug) { this.actionButton('打开仓库', true, () => this.openRepo(this.screen.slug, undefined)) }
    if (this.screen.query) { this.actionButton('在 GitHub 查看', true, () => { this.openGitHub(this.screen.query); }) }
  }

  @Builder
  groupsBody() {
    if (this.screen.kind === 'group') {
      ForEach(this.groupRepos(), (repo: Repo) => { this.repoCard(repo) }, (repo: Repo) => `${repo.id}`)
      if (!this.groupRepos().length) { this.quiet('这个分组没有收藏。') }
    } else {
      ForEach(this.groups, (group: FavoriteGroup) => {
        if (this.screen.kind === 'groupPicker' && this.screen.repo !== undefined) {
          this.groupChoice(group, this.screen.repo)
        } else { this.rowCard('▰', group.name, `${group.slugs.length} 个仓库`, () => this.openGroup(group)) }
      }, (group: FavoriteGroup) => group.name)
      if (!this.groups.length) { this.quiet('还没有分组。') }
    }
    TextInput({ placeholder: this.screen.kind === 'group' ? '新的分组名' : '新建分组名称', text: this.groupDraft })
      .width('100%').height(35).fontSize(12).fontColor(this.theme().ink).backgroundColor(this.theme().card).maxLength(24)
      .onChange((value: string) => { this.groupDraft = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
    this.actionButton(this.screen.kind === 'group' ? '保存分组名' : '新建分组', !this.actionBusy, () => {
      this.saveGroup(this.screen.kind === 'group');
    })
    if (this.screen.kind === 'group') {
      if (this.pendingAction === 'deleteGroup') {
        this.actionButton('确认删除分组，保留仓库', !this.actionBusy, () => { this.deleteGroup(); })
        this.actionButton('取消', true, () => { this.pendingAction = ''; })
      } else { this.actionButton('删除分组', !this.actionBusy, () => { this.pendingAction = 'deleteGroup'; }) }
    }
    if (this.saveError) { this.quiet(this.saveError) }
  }

  @Builder
  groupChoice(group: FavoriteGroup, repo: Repo) {
    this.rowCard(belongs(group, repo.full_name) ? '✓' : '＋', group.name, `${group.slugs.length} 个仓库`, () => {
      this.assignGroup(repo, group);
    })
  }

  @Builder
  linksBody() {
    this.quiet('GitHub 仓库地址')
    Text(`https://github.com/${this.screen.slug}`).fontSize(12).fontColor(this.theme().blue).wordBreak(WordBreak.BREAK_ALL)
      .copyOption(CopyOptions.LocalDevice).width('100%')
    this.quiet('Git Clone（长按可复制）')
    Text(`https://github.com/${this.screen.slug}.git`).fontSize(12).fontColor(this.theme().ink).wordBreak(WordBreak.BREAK_ALL)
      .copyOption(CopyOptions.LocalDevice).width('100%')
    if (this.screen.repo?.homepage) {
      this.quiet('项目主页')
      Text(this.screen.repo?.homepage ?? '').fontSize(12).fontColor(this.theme().ink).wordBreak(WordBreak.BREAK_ALL)
        .copyOption(CopyOptions.LocalDevice).width('100%')
    }
    this.actionButton('在 GitHub 查看', true, () => { this.openGitHub(`https://github.com/${this.screen.slug}`); })
  }

  @Builder
  body() {
    if (this.screen.kind === 'home') {
      Row({ space: 5 }) {
        Text(this.screen.tab === 0 ? '探索' : this.screen.tab === 1 ? (this.screen.month ? '本月榜单' : '本周榜单') : '最新')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.theme().ink)
        Blank().layoutWeight(1)
        Text(this.screen.tab === 1 ? '总星数' : '最近更新').fontSize(10).fontColor(this.theme().muted)
      }.width('100%').padding({ left: 4, right: 4, top: 5, bottom: 4 })
    }
    if (this.screen.kind === 'search') { this.searchBox() }
    if (this.screen.kind === 'notifications') { this.noticesBody() }
    if (this.screen.kind === 'threads') { this.threadsBody() }
    if (this.screen.kind === 'issue') { this.issueBody() }
    if (this.screen.kind === 'comment') {
      this.formatted(this.screen.markdown)
      if (this.screen.query) { this.actionButton('在 GitHub 查看', true, () => { this.openGitHub(this.screen.query); }) }
    }
    if (this.screen.kind === 'shared') {
      this.quiet('仅在你确认后访问 GitHub。')
      this.actionButton('打开这个仓库', true, () => {
        const next = new Screen('repo', '仓库');
        next.slug = this.screen.slug;
        this.swap(next);
      })
    }
    if (this.screen.kind === 'settings') { this.settingsBody() }
    if (this.screen.kind === 'deviceAuth') { this.deviceAuthBody() }
    if (this.screen.kind === 'speed') { this.speedBody() }
    if (this.screen.kind === 'transfer') { this.transferBody() }
    if (['otp', 'otpAdd', 'otpCode'].includes(this.screen.kind)) { this.otpBody() }
    if (['groups', 'group', 'groupPicker'].includes(this.screen.kind)) { this.groupsBody() }
    if (this.screen.kind === 'links') { this.linksBody() }
    if (this.screen.kind === 'saved') {
      this.actionButton('管理本机收藏分组', true, () => this.showGroups())
      this.actionButton('GitHub 星标', this.authReady, () => this.open(new Screen('starred', 'GitHub 星标')))
    }
    if (this.screen.kind === 'starred') {
      if (this.login) {
        this.actionButton('刷新 GitHub 星标', !this.screen.busy, () => this.refresh())
      } else { this.actionButton('连接 GitHub', this.authReady, () => this.open(new Screen('settings', '连接与设置'))) }
    }
    if (['home', 'search', 'saved', 'starred'].includes(this.screen.kind)) {
      ForEach(this.screen.kind === 'saved' ? this.favorites : this.screen.repos, (repo: Repo) => {
        this.repoCard(repo)
      }, (repo: Repo) => `${repo.id}`)
      if (this.screen.kind === 'saved' && this.favorites.length === 0) {
        this.quiet(this.saveError || '还没有收藏\n打开仓库后点「收藏到手表」')
      } else if (this.screen.loaded && this.screen.repos.length === 0 && this.screen.kind !== 'saved') {
        this.quiet('没有找到仓库')
      }
    }
    if (this.screen.kind === 'repo' && this.screen.repo !== undefined) { this.repoSummary(this.screen.repo) }
    if (this.screen.kind === 'readme' || this.screen.kind === 'file' || this.screen.kind === 'release') {
      this.document()
    }
    if (this.screen.kind === 'assets' && this.screen.release !== undefined) {
      this.pageControl(Math.ceil(this.screen.release.assets.length / DIR_PAGE))
      ForEach(this.screen.release.assets.slice((this.screen.page - 1) * DIR_PAGE, this.screen.page * DIR_PAGE), (asset: Asset) => {
        this.rowCard('↓', asset.name, sizeLabel(asset.size), () => this.releaseDownload(asset))
      }, (asset: Asset) => `${asset.id ?? asset.name}`)
      this.pageControl(Math.ceil(this.screen.release.assets.length / DIR_PAGE))
    }
    if (this.screen.kind === 'releases') {
      ForEach(this.screen.releases, (release: Release) => {
        this.rowCard('↗', release.name || release.tag_name,
          `${release.published_at?.slice(0, 10) ?? ''}${release.prerelease ? ' · 预发布' : ''}`,
          () => this.openRelease(release))
      }, (release: Release) => `${release.id}`)
      if (this.screen.loaded && this.screen.releases.length === 0) { this.quiet('还没有发布记录') }
    }
    if (this.screen.kind === 'tree') {
      if (this.screen.path) {
        this.quiet(`${this.screen.ref} · ${this.screen.path}`)
      } else {
        Button(`⑂ ${this.screen.ref} · 切换分支`, { type: ButtonType.Capsule }).fontSize(11).fontColor(this.theme().blue)
          .backgroundColor(this.theme().pale).width('90%').height(34).onClick(() => this.open(this.fromRepo('branches', '分支')))
      }
      if (!this.screen.path && this.screen.repo !== undefined && !this.screen.repo.private) {
        this.actionButton('下载当前分支 ZIP', true, () => {
          if (this.screen.repo !== undefined) { this.sourceDownload(this.screen.repo); }
        })
      }
      this.pageControl(Math.ceil(this.screen.tree.length / DIR_PAGE))
      ForEach(this.screen.tree.slice((this.screen.page - 1) * DIR_PAGE, this.screen.page * DIR_PAGE), (item: TreeItem) => {
        this.rowCard(item.type === 'dir' ? '▰' : '≡', item.name, item.type === 'file' ? sizeLabel(item.size) : '',
          () => this.treeItem(item))
      }, (item: TreeItem) => item.path)
      if (this.screen.loaded && this.screen.tree.length === 0) { this.quiet('目录为空') }
      this.pageControl(Math.ceil(this.screen.tree.length / DIR_PAGE))
    }
    if (this.screen.kind === 'branches') {
      ForEach(this.screen.branches, (branch: Branch) => {
        this.rowCard('⑂', branch.name, branch.name === this.screen.ref ? '当前分支' : '', () => this.pickBranch(branch))
      }, (branch: Branch) => branch.name)
      if (this.screen.loaded && this.screen.branches.length === 0) { this.quiet('没有可用分支') }
    }
    if (this.screen.hint && this.screen.kind !== 'notifications') { this.quiet(this.screen.hint) }
    if (this.screen.busy) {
      LoadingProgress().width(24).height(24).color(this.theme().blue).margin({ top: 7 })
      this.quiet('正在加载')
    } else if (this.screen.error) {
      this.quiet(this.screen.error)
      Button('重试', { type: ButtonType.Capsule }).fontSize(12).fontColor(this.theme().blue).backgroundColor(this.theme().pale)
        .width('70%').height(34).onClick(() => this.load(this.screen.loaded))
    } else if (this.screen.more) {
      Button('加载更多', { type: ButtonType.Capsule }).fontSize(12).fontColor(this.theme().blue).backgroundColor(this.theme().pale)
        .width('78%').height(34).onClick(() => this.load(true))
    }
  }

  private floorActionEnabled(id: string): boolean {
    if (id === 'refresh') {
      return !this.screen.busy && !this.actionBusy &&
        (!['notifications', 'starred'].includes(this.screen.kind) || !!this.login) &&
        (this.screen.kind !== 'issue' || this.screen.issueNumber > 0 || this.screen.notification?.subject.type === 'Release');
    }
    if (id === 'source') { return this.screen.repo !== undefined && !this.screen.repo.private; }
    if (id === 'target') { return this.screen.targetComment !== undefined; }
    if (id === 'assets') { return (this.screen.release?.assets.length ?? 0) > 0; }
    if (id === 'transferState') { return ['downloading', 'paused', 'completed', 'failed', 'cancelled'].includes(this.download?.phase ?? ''); }
    if (id === 'officialSpeed') { return !this.actionBusy; }
    return true;
  }

  private handleFloor(id: string): void {
    if (!this.floorActionEnabled(id)) { return; }
    if (id === 'guide') { this.showGuide(); return; }
    this.setFloor(false);
    if (id === 'top' || id === 'bottom') {
      this.scroller?.scrollEdge(id === 'top' ? Edge.Top : Edge.Bottom);
    } else if (id === 'back') { this.back(); }
    else if (id === 'refresh') { this.refresh(); }
    else if (id === 'search') { this.root(1); }
    else if (id === 'saved') { this.root(3); }
    else if (id === 'settings') { this.open(new Screen('settings', '连接与设置')); }
    else if (id === 'input') {
      const serial = this.serial;
      setTimeout(() => { if (serial === this.serial) { this.openSearchInput(); } }, 220);
    } else if (id === 'clearSearch') {
      this.input = '';
      this.swap(new Screen('search', '搜索'));
    } else if (id === 'groups') { this.showGroups(); }
    else if (id === 'starred') { this.open(new Screen('starred', 'GitHub 星标')); }
    else if (id === 'noticesUnread') { this.noticesFilter(0, 0); }
    else if (id === 'noticesAll') { this.noticesFilter(1, 0); }
    else if (id === 'noticesSubs') { this.noticesFilter(2, 0); }
    else if (id === 'issues') { this.viewThreads(false, false); }
    else if (id === 'pulls') { this.viewThreads(true, false); }
    else if (id === 'threadsOpen' || id === 'threadsClosed') { this.viewThreads(this.screen.pull, id === 'threadsClosed'); }
    else if (id === 'links') { this.open(this.fromRepo('links', '仓库链接')); }
    else if (id === 'source') {
      if (this.screen.repo !== undefined) { this.sourceDownload(this.screen.repo); }
    } else if (id === 'branches') { this.open(this.fromRepo('branches', '分支')); }
    else if (id === 'wrap') { this.screen.tab = this.screen.tab === 0 ? 1 : 0; }
    else if (id === 'target') {
      if (this.screen.targetComment !== undefined) { this.openComment(this.screen.targetComment); }
    } else if (id === 'web') {
      let url = `https://github.com/${this.screen.slug}`;
      if (this.screen.kind === 'releases') { url += '/releases'; }
      else if (['issue', 'comment'].includes(this.screen.kind) && this.screen.query) { url = this.screen.query; }
      this.openGitHub(url);
    } else if (id === 'assets') {
      const next = this.fromRepo('assets', '发布附件');
      next.release = this.screen.release;
      this.open(next);
    } else if (id === 'transfers') { this.prepareTransfer(); }
    else if (id === 'transferState') {
      if (this.download?.phase === 'downloading') { this.transferAction('pause'); }
      else if (this.download?.phase === 'paused') { this.transferAction('resume'); }
      else if (this.download?.phase === 'completed') { this.transferAction('export'); }
      else { this.transferAction('retry'); }
    } else if (id === 'speed') {
      this.mirrorDraft = this.mirror;
      this.open(new Screen('speed', '连接测试'));
    } else if (id === 'officialSpeed') { this.testSpeed(false); }
    else if (id === 'otp') { this.openOtp(); }
    else if (id === 'newOtp') {
      this.otpTitle = '';
      this.open(new Screen('otpAdd', '添加验证码'));
    } else if (id === 'otpRefresh') { this.fetchOtp(); }
    else if (id === 'deviceRegen') { this.startDeviceAuth(); }
    else if (id === 'acceptShared') {
      const next = new Screen('repo', '仓库');
      next.slug = this.screen.slug;
      this.swap(next);
    }
  }

  @Builder
  floorCue() {
    Button({ type: ButtonType.Capsule }) {
      Column({ space: 2 }) {
        Blank().width(19).height(2).backgroundColor(this.theme().blue).borderRadius(1)
        Text('⌄').height(9).fontSize(13).fontColor(this.theme().blue).textAlign(TextAlign.Center)
      }.justifyContent(FlexAlign.Center).width('100%')
    }.width(45).height(22).padding(0).backgroundColor(Color.Transparent).accessibilityText('打开快捷面板，也可以在页首向下滑')
      .onClick(() => this.setFloor(true))
  }

  @Builder
  themePills() {
    Row({ space: 5 }) {
      this.pill('浅色', !this.dark, () => this.appearance(false))
      this.pill('黑色', this.dark, () => this.appearance(true))
    }.width('100%')
  }

  @Builder
  floorPill(label: string, selected: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule }).layoutWeight(1).height(33).fontSize(12).padding(3)
      .fontColor(selected ? this.floorTheme().accentText : this.floorTheme().blue)
      .backgroundColor(selected ? this.floorTheme().blue : this.floorTheme().pale).onClick(action)
  }

  @Builder
  floorRow(item: FloorAction) {
    Row({ space: 8 }) {
      Text(item.symbol).width(20).fontSize(12).fontColor(this.floorTheme().blue).textAlign(TextAlign.Center)
      Text(item.id === 'transferState' ? this.transferFloorLabel() : item.title).fontSize(12).layoutWeight(1)
        .fontColor(this.floorTheme().ink).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('›').fontSize(14).fontColor(this.floorTheme().muted)
    }.width('100%').height(37).padding({ left: 8, right: 8 }).borderRadius(11)
      .backgroundColor(this.floorTheme().card).border({ width: 1, color: this.floorTheme().border })
      .focusable(this.floorOpen).onClick(() => this.handleFloor(item.id))
  }

  @Builder
  floorDrawer(copy: FloorCopy) {
    Scroll(this.floorScroller) {
      Column({ space: 7 }) {
        Column({ space: 4 }) {
          Text('负一屏   /   QUICK TOOLS').fontSize(8).fontWeight(FontWeight.Bold).letterSpacing(0.8).fontColor(this.floorTheme().blue)
          Text(copy.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.floorTheme().ink)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(copy.note).fontSize(11).lineHeight(16).fontColor(this.floorTheme().muted).width('87%').textAlign(TextAlign.Center)
        }.width('100%').alignItems(HorizontalAlign.Center).padding({ top: 1, bottom: 4 })
        if (this.floorKind === 'home') {
          Row({ space: 4 }) {
            this.floorPill('探索', this.screen.tab === 0, () => this.home(0, this.screen.month))
            this.floorPill('榜单', this.screen.tab === 1, () => this.home(1, this.screen.month))
            this.floorPill('最新', this.screen.tab === 2, () => this.home(2, this.screen.month))
          }.width('100%')
          if (this.screen.tab === 1) {
            Row({ space: 5 }) {
              this.floorPill('本周', !this.screen.month, () => this.home(1, false))
              this.floorPill('本月', this.screen.month, () => this.home(1, true))
            }.width('100%')
          }
        }
        ForEach(copy.actions, (item: FloorAction) => {
          if (this.floorActionEnabled(item.id)) { this.floorRow(item) }
        }, (item: FloorAction) => item.id)
        Text('主页面外观').width('100%').fontSize(10).fontWeight(FontWeight.Bold).fontColor(this.floorTheme().muted).margin({ top: 4 })
        Row({ space: 5 }) {
          this.floorPill('浅色', !this.dark, () => this.appearance(false))
          this.floorPill('黑色', this.dark, () => this.appearance(true))
        }.width('100%')
      }.width('74%').padding({ top: 20, bottom: 33 })
    }.id(FLOOR_SCROLL_ID).width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .focusable(this.floorOpen).defaultFocus(this.floorOpen).digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          try { this.floorPanFromEnd = this.floorScroller?.isAtEnd() ?? false; } catch (_) { this.floorPanFromEnd = false; }
        }
      })
      .parallelGesture(PanGesture({ direction: PanDirection.Vertical, distance: 7 })
        .onActionStart(() => this.beginFloorExit(this.floorPanFromEnd))
        .onActionUpdate((event: GestureEvent) => this.updateFloorExit(event))
        .onActionEnd((event: GestureEvent) => this.finishFloorExit(event))
        .onActionCancel(() => this.finishFloorExit()))
  }

  @Builder
  floorOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.floorDrawer(floorCopy(this.floorKind))
      Column({ space: 1 }) {
        Text('⌃').fontSize(9).height(9).fontWeight(FontWeight.Bold).fontColor(this.floorTheme().muted)
        Blank().width(23).height(2).borderRadius(1).backgroundColor(this.floorTheme().blue)
      }.width(65).height(26).margin({ bottom: 4 }).justifyContent(FlexAlign.End)
        .padding({ bottom: 3 }).backgroundColor(Color.Transparent).accessibilityText('从这里向上滑动返回页面')
        .gesture(PanGesture({ direction: PanDirection.Vertical, distance: 5 })
          .onActionStart(() => this.beginFloorExit(true))
          .onActionUpdate((event: GestureEvent) => this.updateFloorExit(event))
          .onActionEnd((event: GestureEvent) => this.finishFloorExit(event))
          .onActionCancel(() => this.finishFloorExit()))
    }.width('100%').height('100%')
      .linearGradient({ angle: 164, colors: [[this.floorTheme().glow, 0], [this.floorTheme().bg, 0.62], [this.floorTheme().low, 1]] })
      .opacity(this.floorProgress).translate({ y: floorRise(this.floorProgress) })
      .hitTestBehavior(this.floorOpen ? HitTestMode.Default : HitTestMode.None)
  }

  private transferFloorLabel(): string {
    if (this.download?.phase === 'downloading') { return '暂停下载'; }
    if (this.download?.phase === 'paused') { return '继续下载'; }
    if (this.download?.phase === 'completed') { return '导出已下载文件'; }
    return '重试上个任务';
  }

  private dockSelect(index: number): void {
    if (this.usesRepoDock()) { this.repoTab(REPO_KINDS[index], REPO_TITLES[index]); }
    else { this.root(index); }
  }

  @Builder
  shell() {
    Column({ space: 8 }) {
      Text('腕上 Git').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#F5F8FF')
      Text('未能打开完整界面').fontSize(12).fontColor('#A8C9F7')
      Button('重试').fontSize(12).height(32).width('68%')
        .backgroundColor('#1B304F').fontColor('#A8C9F7').onClick(() => this.activateFull())
      if (this.bootHint) { Text(this.bootHint).fontSize(11).fontColor('#C4D3E6').width('75%').textAlign(TextAlign.Center) }
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#0D1117')
  }

  @Builder
  fullContents() {
    if (allowsQuickFloor(this.screen.kind)) { this.floorCue() }
    this.header()
    Column({ space: 7 }) {
      if (this.screen.kind === 'home' && !this.servicesReady) {
        this.actionButton('读取本机数据并联网 · F20', !this.bootHint, () => this.scheduleServices())
        Text(this.bootHint || '兼容界面已打开 · F11').fontSize(10).fontColor(this.theme().muted).textAlign(TextAlign.Center)
      }
      this.body()
    }.width(this.screen.kind === 'deviceAuth' ? '92%' : '80%')
  }

  @Builder
  compatibleScroll() {
    Scroll(this.scroller) {
      Column({ space: 7 }) { this.fullContents() }.width('100%').padding({ top: 25, bottom: 68 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  @Builder
  nativeScroll(inPager: boolean) {
    Scroll(this.scroller) {
      Column({ space: 7 }) { this.fullContents() }
        .width('100%').padding({ top: '9%', bottom: inPager ? 31 : 46 })
        .translate({ y: this.crownY + this.fingerY })
        .onAreaChange((_previous: Area, next: Area) => {
          const h = Number(next.height);
          if (Number.isFinite(h) && h >= 0 && h !== this.contentHeight) { this.contentHeight = h; this.crown.reset(); }
        })
    }.id(MAIN_SCROLL_ID).width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .focusable(!this.floorOpen && !this.guideOpen).defaultFocus(true)
      .onAreaChange((_previous: Area, next: Area) => {
        const h = Number(next.height);
        if (Number.isFinite(h) && h > 0 && h !== this.viewportHeight) { this.viewportHeight = h; this.crown.reset(); }
      })
      .onBlur(() => this.crown.reset())
      .onDigitalCrown((event: CrownEvent) => this.onCrown(event))
      .onTouch((event: TouchEvent) => this.beginTouch(event))
      .parallelGesture(PanGesture({ direction: PanDirection.Vertical, distance: 7 })
        .onActionUpdate((event: GestureEvent) => {
          if (pullAccepted(this.pullFromTop, event.offsetX, event.offsetY)) {
            this.fingerY = pullDistance(event.offsetY);
            this.previewFloor(event.offsetY);
          } else if (this.fingerY > 0) { this.fingerY = 0; this.previewFloor(0); }
        })
        .onActionEnd((event: GestureEvent) => {
          if (opensFloor(this.pullFromTop, event.offsetX, event.offsetY)) { this.setFloor(true); }
          else { this.touchReset(); this.cancelFloorPreview(); }
        }).onActionCancel(() => { this.touchReset(); this.cancelFloorPreview(); }))
  }

  private pagerIndex(group: number): number {
    return Math.max(0, (group === 1 ? ROOT_KINDS : REPO_KINDS).indexOf(this.screen.kind));
  }

  private pagerGroup(): number {
    return ROOT_KINDS.includes(this.screen.kind) ? 1 : this.usesRepoDock() ? 2 : 0;
  }

  private pagerCommit(group: number, index: number): void {
    if (group !== this.pagerGroup() || index < 0 || index >= ROOT_KINDS.length || index === this.pagerIndex(group)) { return; }
    this.dockSelect(index);
  }

  private pagerTap(group: number, index: number): void {
    if (group !== this.pagerGroup() || index === this.pagerIndex(group) || this.searchEditing || this.floorVisible || this.guideOpen) { return; }
    try {
      const controller = group === 1 ? this.rootPager : this.repoPager;
      if (controller !== undefined) { controller.changeIndex(index, true); }
      else { this.pagerCommit(group, index); }
    } catch (_) { this.pagerCommit(group, index); }
  }

  private cachedSlugs(index: number): Repo[] {
    return (index === 3 ? this.favorites : this.roots.get(ROOT_KINDS[index])?.repos ?? []).slice(0, 3);
  }

  @Builder
  pagerPreview(group: number, tab: WatchTab, index: number) {
    // The focused page retains the real Scroll and input. Adjacent pages render
    // a non-focusable preview while Swiper is in transit, never a second editor.
    Column({ space: 9 }) {
      Text(tab.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.theme().ink)
      if (group === 2) {
        Text(this.screen.slug).fontSize(11).fontColor(this.theme().muted).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      } else if (this.cachedSlugs(index).length > 0) {
        ForEach(this.cachedSlugs(index), (repo: Repo) => {
          Text(repo.full_name).fontSize(11).fontColor(this.theme().ink).textAlign(TextAlign.Center)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('77%').padding(8)
            .borderRadius(9).backgroundColor(this.theme().card)
        }, (repo: Repo) => `${repo.id}`)
      } else {
        Text(index === 0 ? '腕上 Git' : index === 1 ? '输入关键词或仓库名' : index === 2 ? 'GitHub 通知' : '本机收藏')
          .fontSize(11).fontColor(this.theme().muted)
      }
    }.width('100%').height('100%').padding({ top: 50 })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }

  @Builder
  pageRail(group: number, tabs: WatchTab[]) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        ForEach(tabs, (tab: WatchTab, index: number) => {
          Row() {
            Text('').width(4).height(4).borderRadius(2).backgroundColor(this.dark ? '#626262' : '#A5ABB4')
          }.width(10).height(14).justifyContent(FlexAlign.Center)
            .accessibilityText(tab.title).onClick(() => this.pagerTap(group, index))
        }, (tab: WatchTab) => tab.key)
      }.height(14).padding({ left: 2, right: 2 })
      Row().width(10).height(4).borderRadius(2).backgroundColor(this.dark ? '#FFFFFF' : this.theme().ink)
        .position({ x: 2, y: 5 }).translate({ x: this.pagerProgress * 10, y: 0 })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }.width(tabs.length * 10 + 4).height(14)
  }

  @Builder
  nativePager(group: number, tabs: WatchTab[]) {
    Column() {
      Swiper(group === 1 ? this.rootPager : this.repoPager) {
        ForEach(tabs, (tab: WatchTab, index: number) => {
          Column() {
            if (this.pagerIndex(group) === index) { this.nativeScroll(true) }
            else { this.pagerPreview(group, tab, index) }
          }.width('100%').height('100%')
        }, (tab: WatchTab) => tab.key)
      }.index(this.pagerIndex(group)).indicator(false).loop(false).cachedCount(1)
        .disableSwipe(this.searchEditing || this.guideOpen || this.floorVisible)
        .onAppear(() => { this.pagerProgress = this.pagerIndex(group); })
        .onContentDidScroll((_selectedIndex: number, index: number, position: number, _mainAxisLength: number) => {
          if (this.pagerGroup() === group) { this.pagerProgress = watchPageProgress(index, position, tabs.length); }
        })
        .onChange((index: number) => this.pagerCommit(group, index))
        .onAnimationEnd((index: number, _event: SwiperAnimationEvent) => {
          if (group === this.pagerGroup()) {
            this.pagerCommit(group, index);
            this.pagerProgress = this.pagerIndex(group);
            this.focusSurface();
          }
        })
        .layoutWeight(1).width('100%')
      if (!this.searchEditing) {
        Row() { this.pageRail(group, tabs) }
          .width('100%').height(14).justifyContent(FlexAlign.Center).margin({ top: 1, bottom: 2 })
      }
    }.width('100%').height('100%')
  }

  @Builder
  simpleDock(tabs: WatchTab[], active: number) {
    Row({ space: 2 }) {
      ForEach(tabs, (tab: WatchTab, i: number) => {
        Button(tab.title).layoutWeight(1).height(27).fontSize(10).padding(0)
          .fontColor(i === active ? this.theme().accentText : this.theme().blue)
          .backgroundColor(i === active ? this.theme().blue : this.theme().pale)
          .onClick(() => this.dockSelect(i))
      }, (tab: WatchTab) => tab.key)
    }.width('70%').margin({ bottom: 25 }).backgroundColor(this.theme().card).borderRadius(16).padding(3)
  }

  build() {
    if (!this.fullReady) {
      this.shell()
    } else {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.enhanced && ROOT_KINDS.includes(this.screen.kind)) {
          this.nativePager(1, ROOT_TABS)
        } else if (this.enhanced && this.usesRepoDock()) {
          this.nativePager(2, REPO_TABS)
        } else if (this.enhanced) {
          this.nativeScroll(false)
        } else {
          this.compatibleScroll()
          if (!this.floorOpen && !this.guideOpen && !this.searchEditing && this.pagerGroup() !== 0) {
            this.simpleDock(this.usesRepoDock() ? REPO_TABS : ROOT_TABS, this.pagerIndex(this.pagerGroup()))
          }
        }
        if (this.floorVisible) { this.floorOverlay() }
        if (this.guideOpen) { WristGuide({ dark: this.dark, onFinish: (tryFloor: boolean) => this.finishGuide(tryFloor) }) }
        if (this.screen.kind === 'deviceAuth' && this.qrZoom) { this.qrZoomOverlay() }
      }.width('100%').height('100%').backgroundColor(this.theme().bg)
    }
  }

}

interface SavedCollection {
  repos: Repo[];
  groups: FavoriteGroup[];
}
