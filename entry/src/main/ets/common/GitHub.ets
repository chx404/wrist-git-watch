import { PAGE_SIZE, urlPath } from './Logic';
import { API_ORIGIN, GitHubError, NetMethod, NetRest } from './NetRest';

export { GitHubError } from './NetRest';

export interface Repo {
  id: number;
  name: string;
  full_name: string;
  description: string | null;
  stargazers_count: number;
  forks_count: number;
  open_issues_count: number;
  language: string | null;
  default_branch: string;
  topics?: string[];
  private?: boolean;
  html_url?: string;
  homepage?: string | null;
  clone_url?: string;
}

export interface SearchResult {
  items: Repo[];
  total_count: number;
}

export interface TreeItem {
  name: string;
  path: string;
  type: string;
  size: number;
}

export interface Branch {
  name: string;
}

export interface Asset {
  name: string;
  size: number;
  id?: number;
  url?: string;
  browser_download_url?: string;
  content_type?: string;
  download_count?: number;
  digest?: string | null;
  created_at?: string;
  updated_at?: string;
  label?: string | null;
  state?: string;
}

export interface AssetMetadata {
  id: number;
  name: string;
  size: number;
  downloadUrl: string;
  apiUrl: string;
  contentType: string;
  downloadCount: number;
  digest: string;
  createdAt: string;
  updatedAt: string;
  label: string;
  state: string;
}

export interface GitHubUser {
  login: string;
  id: number;
  name?: string | null;
  avatar_url?: string;
  html_url?: string;
}

export interface NotificationFilter {
  all?: boolean;
  participating?: boolean;
  since?: string;
  before?: string;
  repo?: string;
}

export interface NotificationSubject {
  title: string;
  type: string;
  url: string | null;
  latest_comment_url: string | null;
}

export interface NotificationRepository {
  id: number;
  name: string;
  full_name: string;
  html_url?: string;
}

export interface GitHubNotification {
  id: string;
  unread: boolean;
  reason: string;
  updated_at: string;
  last_read_at?: string | null;
  subject: NotificationSubject;
  repository: NotificationRepository;
}

export interface NotificationJump {
  slug: string;
  type: string;
  title: string;
  number: number;
  apiUrl: string;
  webUrl: string;
}

export interface IssueOrPullDetail {
  title: string;
  body: string | null;
  state: string;
  login: string;
  number: number;
  html_url: string;
  merged?: boolean;
}

export interface IssueComment {
  id: number;
  body: string;
  login: string;
  created_at: string;
  html_url: string;
}

export interface RepoThread {
  number: number;
  title: string;
  state: string;
  updated_at: string;
  pull_request?: Object;
}

export interface RepoThreadPage {
  items: RepoThread[];
  more: boolean;
}

interface GitHubAuthor {
  login: string;
}

interface IssueResponse {
  title: string;
  body: string | null;
  state: string;
  number: number;
  html_url: string;
  user: GitHubAuthor | null;
  merged?: boolean;
}

interface CommentResponse {
  id: number;
  body: string;
  created_at: string;
  html_url: string;
  user: GitHubAuthor | null;
}

interface WebLinkResponse {
  html_url?: string;
}

interface WatchResponse {
  subscribed: boolean;
  ignored: boolean;
}

export interface Release {
  id: number;
  name: string | null;
  tag_name: string;
  published_at: string | null;
  body: string | null;
  prerelease: boolean;
  assets: Asset[];
}

export class LanguageSlice {
  name: string;
  share: number;
  constructor(name: string, share: number) {
    this.name = name;
    this.share = share;
  }
}

export class GitHub {
  private static get(path: string, raw: boolean = false): Promise<string> {
    return NetRest.get(path, raw);
  }

  private static slugPath(slug: string): string {
    if (!/^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9_.-]{1,100}$/.test(slug) || /\/\.{1,2}$/.test(slug)) {
      throw new GitHubError(0, '仓库名称无效');
    }
    return urlPath(slug);
  }

  private static filePath(path: string): string {
    if (path.split('/').some((part: string) => !part || part === '.' || part === '..')) {
      throw new GitHubError(0, '文件路径无效');
    }
    return urlPath(path);
  }

  private static idPath(id: number): string {
    if (!Number.isSafeInteger(id) || id < 1) {
      throw new GitHubError(0, 'GitHub 编号无效');
    }
    return `${id}`;
  }

  private static webUrl(value: string | null | undefined): string {
    return typeof value === 'string' && /^https:\/\/github\.com\/[!-~]+$/.test(value) &&
      !value.includes('\\') ? value : '';
  }

  static setToken(token: string): void {
    NetRest.setToken(token);
  }

  static clearCache(): void {
    NetRest.clearCache();
  }

  static async validateToken(token: string): Promise<GitHubUser> {
    const user = JSON.parse(await NetRest.validateToken(token)) as GitHubUser;
    if (!user || typeof user.login !== 'string' || !user.login || !Number.isSafeInteger(user.id) || user.id < 1) {
      throw new GitHubError(0, 'GitHub 返回了无效的账户资料');
    }
    return user;
  }

  static async search(q: string, sort: string, page: number): Promise<SearchResult> {
    const order = sort ? `&sort=${encodeURIComponent(sort)}&order=desc` : '';
    return JSON.parse(await GitHub.get(`/search/repositories?q=${encodeURIComponent(q)}${order}&per_page=${PAGE_SIZE}&page=${page}`)) as SearchResult;
  }

  static async repo(slug: string): Promise<Repo> {
    return JSON.parse(await GitHub.get(`/repos/${GitHub.slugPath(slug)}`)) as Repo;
  }

  static async languages(slug: string): Promise<LanguageSlice[]> {
    const bytes = JSON.parse(await GitHub.get(`/repos/${GitHub.slugPath(slug)}/languages`)) as Record<string, number>;
    const names = Object.keys(bytes).sort((a: string, b: string) => bytes[b] - bytes[a]);
    let total = 0;
    for (const n of names) {
      total += bytes[n];
    }
    if (total <= 0) {
      return [];
    }
    const slices: LanguageSlice[] = [];
    let included = 0;
    const count = names.length > 4 ? 3 : names.length;
    for (let i = 0; i < count; i++) {
      included += bytes[names[i]];
      slices.push(new LanguageSlice(names[i], bytes[names[i]] * 100 / total));
    }
    if (count < names.length) {
      slices.push(new LanguageSlice('其他', (total - included) * 100 / total));
    }
    return slices;
  }

  static readme(slug: string): Promise<string> {
    return GitHub.get(`/repos/${GitHub.slugPath(slug)}/readme`, true);
  }

  static async contents(slug: string, path: string, ref: string): Promise<TreeItem[]> {
    const route = `/repos/${GitHub.slugPath(slug)}/contents${path ? `/${GitHub.filePath(path)}` : ''}`;
    const data = JSON.parse(await GitHub.get(`${route}?ref=${encodeURIComponent(ref)}`)) as TreeItem[];
    if (!Array.isArray(data)) {
      throw new GitHubError(0, '此目录无法浏览');
    }
    return data.sort((a: TreeItem, b: TreeItem) => {
      if ((a.type === 'dir') !== (b.type === 'dir')) {
        return a.type === 'dir' ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
  }

  static file(slug: string, path: string, ref: string): Promise<string> {
    return GitHub.get(`/repos/${GitHub.slugPath(slug)}/contents/${GitHub.filePath(path)}?ref=${encodeURIComponent(ref)}`, true);
  }

  static async branches(slug: string, page: number): Promise<Branch[]> {
    return JSON.parse(await GitHub.get(`/repos/${GitHub.slugPath(slug)}/branches?per_page=${PAGE_SIZE}&page=${page}`)) as Branch[];
  }

  static async releases(slug: string, page: number): Promise<Release[]> {
    return JSON.parse(await GitHub.get(`/repos/${GitHub.slugPath(slug)}/releases?per_page=${PAGE_SIZE}&page=${page}`)) as Release[];
  }

  static async asset(slug: string, id: number): Promise<Asset> {
    const route = `/repos/${GitHub.slugPath(slug)}/releases/assets/${GitHub.idPath(id)}`;
    return JSON.parse(await GitHub.get(route)) as Asset;
  }

  static assetDownloadUrl(asset: Asset): string {
    const url = GitHub.webUrl(asset.browser_download_url);
    return /^https:\/\/github\.com\/[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+\/releases\/download\/[^?#]+$/.test(url)
      ? url : '';
  }

  static assetMetadata(asset: Asset): AssetMetadata {
    const api = asset.url ?? '';
    const safeApi = /^https:\/\/api\.github\.com\/(?:repos\/[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+|repositories\/[0-9]+)\/releases\/assets\/[0-9]+$/.test(api);
    return {
      id: asset.id ?? 0,
      name: asset.name,
      size: asset.size,
      downloadUrl: GitHub.assetDownloadUrl(asset),
      apiUrl: safeApi ? api : '',
      contentType: asset.content_type ?? '',
      downloadCount: asset.download_count ?? 0,
      digest: asset.digest ?? '',
      createdAt: asset.created_at ?? '',
      updatedAt: asset.updated_at ?? '',
      label: asset.label ?? '',
      state: asset.state ?? ''
    };
  }

  static async notifications(page: number, filter?: NotificationFilter): Promise<GitHubNotification[]> {
    const route = filter?.repo ? `/repos/${GitHub.slugPath(filter.repo)}/notifications` : '/notifications';
    let query = `per_page=${PAGE_SIZE}&page=${GitHub.idPath(page)}`;
    if (filter?.all) {
      query += '&all=true';
    }
    if (filter?.participating) {
      query += '&participating=true';
    }
    if (filter?.since) {
      query += `&since=${encodeURIComponent(filter.since)}`;
    }
    if (filter?.before) {
      query += `&before=${encodeURIComponent(filter.before)}`;
    }
    return JSON.parse(await NetRest.get(`${route}?${query}`, false, true)) as GitHubNotification[];
  }

  static async markNotificationRead(id: string): Promise<void> {
    if (!/^[1-9][0-9]{0,19}$/.test(id)) {
      throw new GitHubError(0, '通知编号无效');
    }
    await NetRest.write(`/notifications/threads/${id}`, NetMethod.PATCH, [205, 204]);
  }

  static async markNotificationsRead(repo?: string): Promise<void> {
    const route = repo ? `/repos/${GitHub.slugPath(repo)}/notifications` : '/notifications';
    await NetRest.write(route, NetMethod.PUT, [202, 205, 204], '{}');
  }

  static notificationJump(notification: GitHubNotification): NotificationJump {
    const type = notification.subject.type;
    const title = notification.subject.title;
    const slug = notification.repository.full_name;
    const path = GitHub.slugPath(slug);
    const root = `https://github.com/${path}`;
    const jump: NotificationJump = { slug: slug, type: type, title: title, number: 0, apiUrl: '', webUrl: root };
    const subjectUrl = notification.subject.url ?? '';
    const match = /^https:\/\/api\.github\.com\/(repos\/[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+|repositories\/[0-9]+)\/(issues|pulls|releases|commits|discussions|actions\/runs)\/([A-Za-z0-9]+)$/.exec(subjectUrl);
    const sameRepo = match && (match[1].toLowerCase() === `repos/${path.toLowerCase()}` ||
      match[1] === `repositories/${notification.repository.id}`);
    if (!match || !sameRepo) {
      return jump;
    }
    const area = match[2];
    const id = match[3];
    const number = Number(id);
    const numeric = /^[1-9][0-9]*$/.test(id) && Number.isSafeInteger(number);
    if (numeric && ((type === 'Issue' && area === 'issues') || (type === 'PullRequest' && area === 'pulls'))) {
      jump.number = number;
      jump.webUrl = `${root}/${type === 'Issue' ? 'issues' : 'pull'}/${id}`;
    } else if (type === 'Release' && area === 'releases' && numeric) {
      jump.webUrl = `${root}/releases`;
    } else if (type === 'Commit' && area === 'commits' && /^[0-9a-f]{7,64}$/i.test(id)) {
      jump.webUrl = `${root}/commit/${id}`;
    } else if (type === 'Discussion' && area === 'discussions' && numeric) {
      jump.webUrl = `${root}/discussions/${id}`;
    } else if ((type === 'CheckSuite' || type === 'WorkflowRun') && area === 'actions/runs' && numeric) {
      jump.webUrl = `${root}/actions/runs/${id}`;
    } else {
      return jump;
    }
    jump.apiUrl = `${API_ORIGIN}/repos/${path}/${area}/${id}`;
    return jump;
  }

  static async resolveNotificationJump(notification: GitHubNotification): Promise<NotificationJump> {
    const jump = GitHub.notificationJump(notification);
    if (jump.apiUrl) {
      const route = jump.apiUrl.slice(API_ORIGIN.length);
      const item = JSON.parse(await GitHub.get(route)) as WebLinkResponse;
      const webUrl = GitHub.webUrl(item.html_url);
      if (webUrl) {
        jump.webUrl = webUrl;
      }
    }
    return jump;
  }

  static async repoThreads(slug: string, pull: boolean, closed: boolean, page: number): Promise<RepoThreadPage> {
    const root = `/repos/${GitHub.slugPath(slug)}/${pull ? 'pulls' : 'issues'}`;
    const state = closed ? 'closed' : 'open';
    const raw = JSON.parse(await GitHub.get(`${root}?state=${state}&sort=updated&direction=desc&per_page=${PAGE_SIZE}&page=${GitHub.idPath(page)}`)) as RepoThread[];
    return { items: pull ? raw : raw.filter((row: RepoThread) => row.pull_request === undefined), more: raw.length === PAGE_SIZE };
  }

  static async issueOrPullDetail(slug: string, number: number, pull: boolean): Promise<IssueOrPullDetail> {
    const route = `/repos/${GitHub.slugPath(slug)}/${pull ? 'pulls' : 'issues'}/${GitHub.idPath(number)}`;
    const data = JSON.parse(await GitHub.get(route)) as IssueResponse;
    return {
      title: data.title,
      body: data.body,
      state: data.state,
      login: data.user?.login ?? '',
      number: data.number,
      html_url: GitHub.webUrl(data.html_url),
      merged: data.merged
    };
  }

  private static commentView(comment: CommentResponse): IssueComment {
    return {
      id: comment.id, body: comment.body, login: comment.user?.login ?? '',
      created_at: comment.created_at, html_url: GitHub.webUrl(comment.html_url)
    };
  }

  static noticeCommentPath(notice: GitHubNotification): string {
    const slug = GitHub.slugPath(notice.repository.full_name);
    const url = notice.subject.latest_comment_url ?? '';
    const match = /^https:\/\/api\.github\.com\/(repos\/[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+|repositories\/[0-9]+)\/(issues|pulls)\/comments\/([1-9][0-9]{0,19})$/.exec(url);
    if (!match || (match[1].toLowerCase() !== `repos/${slug.toLowerCase()}` && match[1] !== `repositories/${notice.repository.id}`)) {
      return '';
    }
    return `/repos/${slug}/${match[2]}/comments/${match[3]}`;
  }

  static async noticeComment(notice: GitHubNotification): Promise<IssueComment | undefined> {
    const path = GitHub.noticeCommentPath(notice);
    if (!path) { return undefined; }
    return GitHub.commentView(JSON.parse(await GitHub.get(path)) as CommentResponse);
  }

  static async noticeRelease(notice: GitHubNotification): Promise<Release | undefined> {
    const jump = GitHub.notificationJump(notice);
    if (jump.type !== 'Release' || !jump.apiUrl) { return undefined; }
    return JSON.parse(await GitHub.get(jump.apiUrl.slice(API_ORIGIN.length))) as Release;
  }

  static async issueComments(slug: string, number: number, page: number): Promise<IssueComment[]> {
    // GitHub stores ordinary pull-request conversations in the issue comments endpoint as well.
    const route = `/repos/${GitHub.slugPath(slug)}/issues/${GitHub.idPath(number)}/comments`;
    const data = JSON.parse(await GitHub.get(`${route}?per_page=${PAGE_SIZE}&page=${GitHub.idPath(page)}`)) as CommentResponse[];
    return data.map((comment: CommentResponse): IssueComment => GitHub.commentView(comment));
  }

  static async starred(page: number): Promise<Repo[]> {
    const route = `/user/starred?sort=created&direction=desc&per_page=${PAGE_SIZE}&page=${GitHub.idPath(page)}`;
    return JSON.parse(await NetRest.get(route, false, true)) as Repo[];
  }

  static async isStarred(slug: string): Promise<boolean> {
    const status = await NetRest.status(`/user/starred/${GitHub.slugPath(slug)}`, [204, 404]);
    return status === 204;
  }

  static async setStarred(slug: string, starred: boolean): Promise<void> {
    await NetRest.write(`/user/starred/${GitHub.slugPath(slug)}`, starred ? NetMethod.PUT : NetMethod.DELETE,
      [204], starred ? '{}' : undefined);
  }

  static async isWatching(slug: string): Promise<boolean> {
    const route = `/repos/${GitHub.slugPath(slug)}/subscription`;
    const result = await NetRest.read(route, false, true, [200, 404]);
    if (result.status === 404) {
      return false;
    }
    const subscription = JSON.parse(result.body) as WatchResponse;
    return subscription.subscribed && !subscription.ignored;
  }

  static async setWatching(slug: string, watching: boolean): Promise<void> {
    const route = `/repos/${GitHub.slugPath(slug)}/subscription`;
    if (watching) {
      await NetRest.write(route, NetMethod.PUT, [200], '{"subscribed":true,"ignored":false}');
    } else {
      await NetRest.write(route, NetMethod.DELETE, [204]);
    }
  }

  static async fork(slug: string): Promise<Repo> {
    // 202 acknowledges the fork, but GitHub may populate it asynchronously.
    const result = await NetRest.write(`/repos/${GitHub.slugPath(slug)}/forks`, NetMethod.POST, [202], '{}');
    return JSON.parse(result.body) as Repo;
  }
}
