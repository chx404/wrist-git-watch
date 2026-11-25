import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { curves } from '@kit.ArkUI';
import lazy { pasteboard } from '@kit.BasicServicesKit';
import { Asset, Branch, GitHub, GitHubError, GitHubNotification, IssueComment, IssueOrPullDetail, LanguageSlice, Release, Repo, RepoThread, TreeItem } from '../common/GitHub';
import { compact, exactRepo, listQuery, PAGE_SIZE, sizeLabel, textPages } from '../common/Logic';
import { belongs, FavoriteGroup, groupName, removeFromGroups, setMembership } from '../common/Collection';
import { Downloads, DownloadSpec, DownloadStatus } from '../common/Downloads';
import { TotpAccount, Vault } from '../common/Vault';
import { DockTab, GlassDock } from '../components/GlassDock';
import { MarkdownView } from '../components/MarkdownView';
import { WristGuide } from '../components/WristGuide';
import { DAY_LOOK, Look, NIGHT_LOOK } from '../common/Look';
import { FloorAction, FloorCopy, floorCopy, opensFloor, pullAccepted, pullDistance } from '../common/QuickFloor';
import { CrownMotion, crownScrollRange } from '../common/CrownMotion';

const MAIN_SCROLL_ID: string = 'wrist-main-scroll';
const FLOOR_SCROLL_ID: string = 'wrist-floor-scroll';
const FILE_MAX: number = 128 * 1024;
const DIR_PAGE: number = 12;
const ROOT_KINDS: string[] = ['home', 'search', 'notifications', 'saved'];
const ROOT_TABS: DockTab[] = [new DockTab('首页', 'home'), new DockTab('搜索', 'search'), new DockTab('通知', 'notices'), new DockTab('收藏', 'saved')];
const REPO_KINDS: string[] = ['repo', 'readme', 'tree', 'releases'];
const REPO_TABS: DockTab[] = [new DockTab('概览', 'overview'), new DockTab('文档', 'readme'), new DockTab('代码', 'tree'), new DockTab('发布', 'releases')];
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
  constructor(kind: string, title: string) {
    this.kind = kind;
    this.title = title;
  }
}

@Entry
@Component
struct Index {
  @State private screen: Screen = new Screen('home', '首页');
  @State private input: string = '';
  @State private favorites: Repo[] = [];
  @State private saveError: string = '';
  @State private searchEditing: boolean = false;
  @State private dark: boolean = false;
  @State private floorOpen: boolean = false;
  @State private guideOpen: boolean = false;
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
  @StorageLink('wristGitShared') @Watch('sharedChanged') private sharedSlug: string = '';
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
  private scroller: Scroller = new Scroller();
  private floorScroller: Scroller = new Scroller();
  private viewportHeight: number = 0;
  private contentHeight: number = -1;
  private pullFromTop: boolean = false;
  private touchDown: boolean = false;
  private focusTicket: number = 0;
  private focusTimer: number = -1;
  private crown: CrownMotion = new CrownMotion((y: number) => {
    this.scroller.scrollTo({ xOffset: 0, yOffset: y, animation: false });
  }, (y: number) => { this.crownY = y; }, () => {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.31, 0.74, 0.12) }, () => { this.crownY = 0; });
  });

  private get look(): Look { return this.dark ? NIGHT_LOOK : DAY_LOOK; }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.downloads = new Downloads(ctx, (state: DownloadStatus) => { this.download = state; });
    this.download = this.downloads.status();
    try {
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
      this.dark = this.prefs.getSync('appearance_dark', false) as boolean;
      this.guideOpen = !(this.prefs.getSync('guide_03_seen', false) as boolean) && !this.sharedSlug;
    } catch (_) {
      this.saveError = '无法读取本机设置';
    }
    this.restoreAuth();
    this.load();
  }

  onPageShow(): void {
    if (this.sharedSlug) { this.sharedChanged(); }
    if (this.screen.kind === 'otpCode' && !this.floorOpen) { this.startOtpClock(); }
    this.focusSurface();
  }

  onPageHide(): void {
    this.cancelFocus();
    this.crown.reset();
    this.touchDown = false;
    this.touchReset();
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

  private async authenticate(): Promise<void> {
    if (this.actionBusy || !this.authReady) { return; }
    const token = this.tokenDraft.trim();
    this.tokenDraft = '';
    this.getUIContext().getFocusController().clearFocus();
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

  private focusSurface(): void {
    this.cancelFocus();
    if (this.searchEditing || this.guideOpen) { return; }
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
    if (this.searchEditing || this.floorOpen || this.guideOpen || this.touchDown || this.pullFromTop) { return; }
    if (![CrownAction.BEGIN, CrownAction.UPDATE, CrownAction.END].includes(event.action)) { return; }
    const y = this.scroller.currentOffset()?.yOffset;
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
      const y = this.scroller.currentOffset()?.yOffset ?? Number.POSITIVE_INFINITY;
      this.pullFromTop = y <= 1 && !this.searchEditing && !this.floorOpen && !this.guideOpen;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchDown = false;
      if (event.type === TouchType.Cancel) { this.touchReset(); }
    }
  }

  private touchReset(): void {
    this.pullFromTop = false;
    if (this.fingerY !== 0) {
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.fingerY = 0; });
    }
  }

  private setFloor(open: boolean): void {
    if (this.floorOpen === open || this.guideOpen) { return; }
    this.crown.reset();
    this.touchReset();
    this.getUIContext().getFocusController().clearFocus();
    this.searchEditing = false;
    if (open) {
      this.cancelMark();
      if (this.screen.kind === 'otpCode') { this.stopOtpClock(); }
    }
    this.getUIContext().animateTo({ duration: open ? 240 : 185, curve: Curve.EaseOut }, () => { this.floorOpen = open; });
    if (!open && this.screen.kind === 'otpCode') { this.startOtpClock(); }
    this.focusSurface();
  }

  private showGuide(): void {
    if (this.floorOpen) { this.setFloor(false); }
    this.cancelFocus();
    this.crown.reset();
    this.getUIContext().getFocusController().clearFocus();
    this.guideOpen = true;
  }

  private finishGuide(tryFloor: boolean): void {
    this.guideOpen = false;
    try {
      this.prefs?.putSync('guide_03_seen', true);
      this.prefs?.flush().catch(() => {});
    } catch (_) {}
    if (tryFloor) { this.setFloor(true); } else { this.focusSurface(); }
  }

  private appearance(dark: boolean): void {
    if (this.dark === dark) { return; }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.dark = dark; });
    try {
      this.prefs?.putSync('appearance_dark', dark);
      this.prefs?.flush().catch(() => {});
    } catch (_) {}
  }

  private scrollToOffset(offset: number): void {
    const ticket = this.serial;
    setTimeout(() => {
      if (ticket === this.serial) {
        this.scroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false });
      }
    }, 40);
  }

  private leave(keepFloor: boolean = false): void {
    if (!keepFloor && this.floorOpen) { this.setFloor(false); }
    this.cancelFocus();
    this.crown.reset();
    this.touchReset();
    this.pendingAction = '';
    this.tokenDraft = '';
    this.otpDraft = '';
    this.searchEditing = false;
    this.stopOtpClock();
    this.cancelMark();
  }

  private open(next: Screen): void {
    this.screen.offset = this.scroller.currentOffset()?.yOffset ?? 0;
    this.history.push(this.screen);
    this.swap(next);
  }

  private swap(next: Screen, keepFloor: boolean = false): void {
    this.leave(keepFloor);
    this.serial++;
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, () => { this.screen = next; });
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
    this.getUIContext().animateTo({ duration: 265, curve: Curve.EaseOut }, () => { this.screen = prior; });
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
    this.getUIContext().getFocusController().clearFocus();
    this.searchEditing = false;
    if (ROOT_KINDS.includes(this.screen.kind)) {
      this.screen.offset = this.scroller.currentOffset()?.yOffset ?? 0;
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
    this.getUIContext().getFocusController().clearFocus();
    this.searchEditing = false;
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
    this.getUIContext().getFocusController().clearFocus();
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
      .fontColor(selected ? this.look.accentText : this.look.blue).backgroundColor(selected ? this.look.blue : this.look.pale)
      .height(34).padding({ left: 8, right: 8 }).layoutWeight(1)
      .onClick(action)
  }

  @Builder
  actionButton(label: string, enabled: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule }).fontSize(12).fontColor(this.look.blue).backgroundColor(this.look.pale)
      .width('91%').height(35).enabled(enabled).onClick(action)
  }

  @Builder
  quiet(message: string) {
    Text(message).fontSize(12).fontColor(this.look.muted).lineHeight(18).textAlign(TextAlign.Center)
      .width('100%').padding({ top: 9, bottom: 9, left: 8, right: 8 })
  }

  @Builder
  header() {
    if (this.screen.kind === 'home') {
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Blank().width(13).height(2).borderRadius(1).backgroundColor(this.look.blue)
          Text('WRIST / GIT').fontSize(9).fontWeight(FontWeight.Bold).letterSpacing(1.5).fontColor(this.look.blue)
        }.width('100%')
        Row({ space: 5 }) {
          Text('腕上 Git').fontSize(27).fontWeight(FontWeight.Bold).letterSpacing(-0.9).fontColor(this.look.ink)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Stack() {
            Circle().width(32).height(32).fill('#F5F8FC')
            Image($r('app.media.github_invertocat')).width(19).height(19).objectFit(ImageFit.Contain)
          }.width(32).height(32).focusable(true).accessibilityText('GitHub 集成 · 打开腕上 Git 项目')
            .onClick(() => { this.openGitHub('https://github.com/chx404/wrist-git-watch'); })
        }.width('100%').alignItems(VerticalAlign.Center)
        Text('用一块表，逛开源。').fontSize(11).fontColor(this.look.muted).width('100%')
      }.width('75%').alignItems(HorizontalAlign.Start).padding({ top: 3, bottom: 3 })
    } else {
      if (!ROOT_KINDS.includes(this.screen.kind)) {
        Button('‹ 返回', { type: ButtonType.Capsule })
          .fontSize(12).fontColor(this.look.blue).backgroundColor(this.look.pale).height(32)
          .padding({ left: 14, right: 14 }).onClick(() => { this.back(); })
      }
      Text(this.screen.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.look.ink).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center).width('72%')
      if (this.screen.slug && this.screen.kind !== 'file') {
        Text(this.screen.slug).fontSize(11).fontColor(this.look.muted).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center).width('78%')
      }
    }
  }

  @Builder
  repoCard(repo: Repo) {
    Row({ space: 8 }) {
      Text(repo.name.slice(0, 1).toUpperCase()).width(24).height(24)
        .textAlign(TextAlign.Center).fontColor(this.look.blue).backgroundColor(this.look.pale).borderRadius(7)
        .fontSize(12).fontWeight(FontWeight.Bold)
      Column({ space: 3 }) {
        Text(repo.full_name).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.look.ink)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (repo.description) {
          Text(repo.description).fontSize(11).lineHeight(15).fontColor(this.look.muted)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        Text(`★ ${compact(repo.stargazers_count)}${repo.language ? '  ·  ' + repo.language : ''}`)
          .fontSize(10).fontColor(this.look.blue).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(16).fontColor(this.look.muted)
    }
    .width('100%').constraintSize({ minHeight: 53 }).padding({ left: 8, right: 8, top: 7, bottom: 7 })
    .alignItems(VerticalAlign.Center).backgroundColor(this.look.card).borderRadius(13).border({ width: 1, color: this.look.border })
    .focusable(true).onClick(() => this.openRepo(repo.full_name, repo))
  }

  @Builder
  repoSummary(repo: Repo) {
    Column({ space: 8 }) {
      Text(repo.name).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.look.ink).wordBreak(WordBreak.BREAK_ALL)
      Text(repo.description || '此仓库没有说明').fontSize(12).lineHeight(18).fontColor(this.look.muted)
      Text(`★ ${compact(repo.stargazers_count)}   ·   Fork ${compact(repo.forks_count)}`)
        .fontSize(12).fontColor(this.look.blue).fontWeight(FontWeight.Medium)
      Text(`Issues / PR ${compact(repo.open_issues_count)}  ·  ${repo.default_branch}`)
        .fontSize(11).fontColor(this.look.muted).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.screen.language.length > 0) {
        Row() {
          ForEach(this.screen.language, (item: LanguageSlice, index: number) => {
            Row().width(`${item.share}%`).height(5).backgroundColor(this.look.chart[index])
          }, (item: LanguageSlice) => item.name)
        }.width('100%').borderRadius(3).clip(true)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.screen.language, (item: LanguageSlice, index: number) => {
            Text(`● ${item.name} ${Math.round(item.share)}%`).fontSize(10).fontColor(this.look.chart[index])
              .margin({ right: 8, bottom: 3 })
          }, (item: LanguageSlice) => item.name)
        }.width('100%')
      } else if (repo.language) {
        Text(repo.language).fontSize(11).fontColor(this.look.muted)
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(11).backgroundColor(this.look.card)
      .borderRadius(15).border({ width: 1, color: this.look.border })
    if (!repo.private) {
      Button(this.isSaved(repo.full_name) ? '★ 已收藏 · 点击取消' : '☆ 收藏到手表', { type: ButtonType.Capsule })
        .fontSize(12).fontColor(this.look.blue).backgroundColor(this.look.pale).height(36).width('88%')
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

  @Builder
  searchBox() {
    Column({ space: 7 }) {
      TextInput({ placeholder: '关键词 / owner/repo', text: this.input })
        .id('wrist-repo-input').width('100%').height(37).fontSize(13).fontColor(this.look.ink).placeholderColor(this.look.muted)
        .backgroundColor(this.look.card).borderRadius(18).border({ width: 1, color: this.look.border })
        .maxLength(250).enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => { this.input = value; }).onSubmit(() => this.submit())
        .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
      Button('搜索仓库', { type: ButtonType.Capsule }).fontSize(12).fontColor(this.look.accentText).height(35)
        .width('85%').backgroundColor(this.look.blue).onClick(() => this.submit())
      PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
        .fontSize(12).width('85%').height(33).backgroundColor(this.look.pale).fontColor(this.look.blue)
        .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
          if (result === PasteButtonOnClickResult.SUCCESS) { this.pasteRepository(); }
          else { this.screen.hint = '系统没有授权这次粘贴，可在输入框中手动输入'; }
        })
      if (!this.screen.query && !this.screen.hint) { this.quiet('也可输入 GitHub 仓库链接') }
    }.width('100%')
  }

  @Builder
  rowCard(badge: string, name: string, note: string, action: () => void) {
    Row({ space: 8 }) {
      Text(badge).width(21).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.look.blue).textAlign(TextAlign.Center)
      Column({ space: 3 }) {
        Text(name).fontSize(13).fontColor(this.look.ink).fontWeight(FontWeight.Medium)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (note) {
          Text(note).fontSize(10).fontColor(this.look.muted).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(15).fontColor(this.look.muted)
    }.width('100%').constraintSize({ minHeight: 42 }).padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(this.look.card).borderRadius(12).border({ width: 1, color: this.look.border }).focusable(true).onClick(action)
  }

  @Builder
  pageControl(count: number) {
    if (count > 1) {
      Row({ space: 5 }) {
        Button('‹', { type: ButtonType.Capsule }).width(38).height(33).fontSize(15).fontColor(this.look.blue)
          .backgroundColor(this.look.pale).enabled(this.screen.page > 1).onClick(() => this.jump(this.screen.page - 1))
        Text(`${this.screen.page} / ${count}`).fontSize(11).fontColor(this.look.muted).layoutWeight(1).textAlign(TextAlign.Center)
        Button('›', { type: ButtonType.Capsule }).width(38).height(33).fontSize(15).fontColor(this.look.blue)
          .backgroundColor(this.look.pale).enabled(this.screen.page < count).onClick(() => this.jump(this.screen.page + 1))
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
          const current = this.scroller.currentOffset()?.yOffset ?? 0;
          this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, current + ui.px2vp(info.windowOffset.y) - 45), animation: false });
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
      .width('100%').height(37).fontSize(12).fontColor(this.look.ink).placeholderColor(this.look.muted).backgroundColor(this.look.card)
      .type(InputType.Password).showPasswordIcon(false).enableAutoFill(false).maxLength(240)
      .onChange((value: string) => { this.tokenDraft = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false)).onSubmit(() => { this.authenticate(); })
    this.actionButton(this.login ? '验证并更新令牌' : '验证并连接 GitHub', this.authReady && !this.actionBusy, () => { this.authenticate(); })
    this.quiet('通知通常需要 classic 令牌的 notifications 权限；私库或账户操作按需授权。令牌不上传到第三方。')
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
    this.quiet('腕上 Git 0.3 · 非官方 GitHub 客户端')
  }

  @Builder
  speedBody() {
    this.actionButton('测速 · GitHub 官方', !this.actionBusy, () => { this.testSpeed(false); })
    this.quiet('也可以手动测试公开 HTTPS 下载源；不附带账号、令牌或仓库数据。')
    TextInput({ placeholder: 'https:// 下载测试地址', text: this.mirrorDraft })
      .width('100%').height(37).fontSize(12).fontColor(this.look.ink).placeholderColor(this.look.muted).backgroundColor(this.look.card)
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
        .width('100%').height(35).fontSize(12).backgroundColor(this.look.card).fontColor(this.look.ink).maxLength(48)
        .onChange((value: string) => { this.otpTitle = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
      TextInput({ placeholder: 'Base32 密钥或 otpauth', text: this.otpDraft })
        .width('100%').height(36).fontSize(12).backgroundColor(this.look.card).fontColor(this.look.ink)
        .maxLength(512).type(InputType.Password).showPasswordIcon(false).enableAutoFill(false)
        .onChange((value: string) => { this.otpDraft = value; })
      .onFocus(() => this.editorFocus(true)).onBlur(() => this.editorFocus(false))
      this.actionButton('保存在这块手表', !this.actionBusy, () => { this.saveOtp(); })
      this.quiet('建议为手表设置锁屏密码。')
    } else {
      Text(this.otpValue || '— — —').fontFamily('monospace').fontSize(27).letterSpacing(2)
        .fontColor(this.look.blue).fontWeight(FontWeight.Bold).privacySensitive(true).copyOption(CopyOptions.None)
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
          .fontSize(13).fontColor(this.look.blue).fontWeight(FontWeight.Medium)
        if (this.download.totalBytes > 0) {
          Progress({ value: this.download.receivedBytes, total: this.download.totalBytes, type: ProgressType.Linear })
            .width('86%').color(this.look.blue)
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
            .fontColor(this.look.ink).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            .width('100%').padding(10).backgroundColor(this.look.card).borderRadius(13).border({ width: 1, color: this.look.border })
        } else {
          Scroll() {
            Text(this.screen.parts[this.screen.page - 1]).fontSize(11).lineHeight(17).fontFamily('monospace')
              .fontColor(this.look.ink).copyOption(CopyOptions.LocalDevice).padding(10)
          }.scrollable(ScrollDirection.Horizontal).width('100%').align(Alignment.TopStart)
            .backgroundColor(this.look.card).borderRadius(13).border({ width: 1, color: this.look.border })
        }
        this.pageControl(this.screen.parts.length)
      }
    } else if (this.screen.kind === 'readme') {
      if (this.screen.markdown || this.screen.loaded) { this.formatted(this.screen.markdown) }
    } else if (this.screen.kind === 'release' && this.screen.release !== undefined) {
      Text(this.screen.release.name || this.screen.release.tag_name).fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.look.ink).width('100%').wordBreak(WordBreak.BREAK_ALL)
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
      Text(this.screen.release.name || this.screen.release.tag_name).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.look.ink)
        .width('100%').wordBreak(WordBreak.BREAK_ALL)
      this.formatted(this.screen.markdown)
    } else if (this.screen.issue !== undefined) {
      Text(this.screen.issue.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.look.ink)
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
      .width('100%').height(35).fontSize(12).fontColor(this.look.ink).backgroundColor(this.look.card).maxLength(24)
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
    Text(`https://github.com/${this.screen.slug}`).fontSize(12).fontColor(this.look.blue).wordBreak(WordBreak.BREAK_ALL)
      .copyOption(CopyOptions.LocalDevice).width('100%')
    this.quiet('Git Clone（长按可复制）')
    Text(`https://github.com/${this.screen.slug}.git`).fontSize(12).fontColor(this.look.ink).wordBreak(WordBreak.BREAK_ALL)
      .copyOption(CopyOptions.LocalDevice).width('100%')
    if (this.screen.repo?.homepage) {
      this.quiet('项目主页')
      Text(this.screen.repo?.homepage ?? '').fontSize(12).fontColor(this.look.ink).wordBreak(WordBreak.BREAK_ALL)
        .copyOption(CopyOptions.LocalDevice).width('100%')
    }
    this.actionButton('在 GitHub 查看', true, () => { this.openGitHub(`https://github.com/${this.screen.slug}`); })
  }

  @Builder
  body() {
    if (this.screen.kind === 'home') {
      Row({ space: 5 }) {
        Text(this.screen.tab === 0 ? '探索' : this.screen.tab === 1 ? (this.screen.month ? '本月榜单' : '本周榜单') : '最新')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.look.ink)
        Blank().layoutWeight(1)
        Text(this.screen.tab === 1 ? '总星数' : '最近更新').fontSize(10).fontColor(this.look.muted)
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
        Button(`⑂ ${this.screen.ref} · 切换分支`, { type: ButtonType.Capsule }).fontSize(11).fontColor(this.look.blue)
          .backgroundColor(this.look.pale).width('90%').height(34).onClick(() => this.open(this.fromRepo('branches', '分支')))
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
      LoadingProgress().width(24).height(24).color(this.look.blue).margin({ top: 7 })
      this.quiet('正在加载')
    } else if (this.screen.error) {
      this.quiet(this.screen.error)
      Button('重试', { type: ButtonType.Capsule }).fontSize(12).fontColor(this.look.blue).backgroundColor(this.look.pale)
        .width('70%').height(34).onClick(() => this.load(this.screen.loaded))
    } else if (this.screen.more) {
      Button('加载更多', { type: ButtonType.Capsule }).fontSize(12).fontColor(this.look.blue).backgroundColor(this.look.pale)
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
      this.scroller.scrollEdge(id === 'top' ? Edge.Top : Edge.Bottom);
    } else if (id === 'back') { this.back(); }
    else if (id === 'refresh') { this.refresh(); }
    else if (id === 'search') { this.root(1); }
    else if (id === 'saved') { this.root(3); }
    else if (id === 'settings') { this.open(new Screen('settings', '连接与设置')); }
    else if (id === 'input') {
      this.cancelFocus();
      const serial = this.serial;
      setTimeout(() => {
        if (serial === this.serial && !this.floorOpen && !this.guideOpen) {
          try { this.getUIContext().getFocusController().requestFocus('wrist-repo-input'); } catch (_) {}
        }
      }, 200);
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
        Blank().width(19).height(2).backgroundColor(this.look.blue).borderRadius(1)
        Text('⌄').height(9).fontSize(13).fontColor(this.look.blue).textAlign(TextAlign.Center)
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
  floorDrawer(copy: FloorCopy) {
    Scroll(this.floorScroller) {
      Column({ space: 7 }) {
        Button('⌃ 返回页面', { type: ButtonType.Capsule }).height(29).fontSize(11).padding({ left: 12, right: 12 })
          .fontColor(this.look.blue).backgroundColor(this.look.pale).onClick(() => this.setFloor(false))
        Column({ space: 4 }) {
          Text('负一屏   /   QUICK TOOLS').fontSize(8).fontWeight(FontWeight.Bold).letterSpacing(0.8).fontColor(this.look.blue)
          Text(copy.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.look.ink).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(copy.note).fontSize(11).lineHeight(16).fontColor(this.look.muted).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 3, bottom: 4 })
        if (this.screen.kind === 'home') {
          Row({ space: 4 }) {
            this.pill('探索', this.screen.tab === 0, () => this.home(0, this.screen.month))
            this.pill('榜单', this.screen.tab === 1, () => this.home(1, this.screen.month))
            this.pill('最新', this.screen.tab === 2, () => this.home(2, this.screen.month))
          }.width('100%')
          if (this.screen.tab === 1) {
            Row({ space: 5 }) {
              this.pill('本周', !this.screen.month, () => this.home(1, false))
              this.pill('本月', this.screen.month, () => this.home(1, true))
            }.width('100%')
          }
        }
        ForEach(copy.actions, (item: FloorAction) => {
          if (this.floorActionEnabled(item.id)) {
            this.rowCard(item.symbol, item.id === 'transferState' ? this.transferFloorLabel() : item.title, '', () => this.handleFloor(item.id))
          }
        }, (item: FloorAction) => item.id)
        Text('外观').width('100%').fontSize(10).fontWeight(FontWeight.Bold).fontColor(this.look.muted).margin({ top: 4 })
        this.themePills()
      }.width('76%').padding({ top: 24, bottom: 38 })
    }.id(FLOOR_SCROLL_ID).width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .focusable(true).defaultFocus(true).digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .linearGradient({ angle: 164, colors: [[this.look.glow, 0], [this.look.bg, 0.62], [this.look.low, 1]] })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -36 })))
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

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll(this.scroller) {
        Column({ space: 7 }) {
          this.floorCue()
          this.header()
          Column({ space: 7 }) { this.body() }.width('80%')
        }.width('100%').padding({ top: '9%', bottom: ROOT_KINDS.includes(this.screen.kind) || this.usesRepoDock() ? 58 : 46 })
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
            } else if (this.fingerY > 0) { this.fingerY = 0; }
          })
          .onActionEnd((event: GestureEvent) => {
            if (opensFloor(this.pullFromTop, event.offsetX, event.offsetY)) { this.setFloor(true); }
            else { this.touchReset(); }
          }).onActionCancel(() => this.touchReset()))
      if (!this.floorOpen && !this.guideOpen && !this.searchEditing && (ROOT_KINDS.includes(this.screen.kind) || this.usesRepoDock())) {
        GlassDock({ tabs: this.usesRepoDock() ? REPO_TABS : ROOT_TABS,
          selected: this.usesRepoDock() ? REPO_KINDS.indexOf(this.screen.kind) : ROOT_KINDS.indexOf(this.screen.kind),
          dark: this.dark, onSelect: (index: number) => this.dockSelect(index) })
          .width('62%').height(46).margin({ bottom: 5 })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 11 })))
      }
      if (this.floorOpen) { this.floorDrawer(floorCopy(this.screen.kind)) }
      if (this.guideOpen) { WristGuide({ dark: this.dark, onFinish: (tryFloor: boolean) => this.finishGuide(tryFloor) }) }
    }.width('100%').height('100%').clip(true)
      .linearGradient({ angle: 158, colors: [[this.look.glow, 0], [this.look.bg, 0.55], [this.look.low, 1]] })
  }
}

interface SavedCollection {
  repos: Repo[];
  groups: FavoriteGroup[];
}
