export class FloorAction {
  readonly id: string;
  readonly title: string;
  readonly symbol: string;
  constructor(id: string, title: string, symbol: string) {
    this.id = id;
    this.title = title;
    this.symbol = symbol;
  }
}

export class FloorCopy {
  readonly title: string;
  readonly note: string;
  readonly actions: FloorAction[];
  constructor(title: string, note: string, actions: FloorAction[]) {
    this.title = title;
    this.note = note;
    this.actions = actions;
  }
}

export function pullAccepted(atTop: boolean, x: number, y: number): boolean {
  return atTop && y > 0 && y > Math.abs(x) * 1.25;
}

export function pullDistance(raw: number): number {
  return Math.min(44, Math.max(0, raw) * 0.45);
}

export function opensFloor(atTop: boolean, x: number, y: number): boolean {
  return pullAccepted(atTop, x, y) && y >= 36;
}

export function floorCopy(kind: string): FloorCopy {
  switch (kind) {
    case 'home': return new FloorCopy('发现', '选择首页内容与榜单周期', [
      new FloorAction('refresh', '刷新首页', '↻'), new FloorAction('search', '搜索仓库', '⌕'),
      new FloorAction('settings', '连接与设置', '⚙'), new FloorAction('guide', '新手教程', '?')]);
    case 'search': return new FloorCopy('搜索工具', '支持关键词、owner/repo 或 GitHub 链接', [
      new FloorAction('input', '输入关键词', '⌕'), new FloorAction('clearSearch', '清空搜索', '×'), new FloorAction('guide', '输入格式指南', '?')]);
    case 'notifications': return new FloorCopy('消息中心', '查看待处理通知、订阅和刷新选项', [
      new FloorAction('noticesUnread', '查看未读', '●'), new FloorAction('noticesAll', '查看全部', '≡'),
      new FloorAction('noticesSubs', '查看订阅', '◈'), new FloorAction('refresh', '刷新通知', '↻')]);
    case 'saved': return new FloorCopy('收藏管理', '本机收藏与 GitHub 星标分开保存', [
      new FloorAction('groups', '管理收藏分组', '▦'), new FloorAction('starred', 'GitHub 星标', '☆')]);
    case 'starred': return new FloorCopy('GitHub 星标', '查看账户在 GitHub 的星标', [
      new FloorAction('refresh', '刷新星标', '↻'), new FloorAction('settings', '连接 GitHub', '⚙')]);
    case 'repo': return new FloorCopy('仓库工具', '快速打开讨论、链接或下载', [
      new FloorAction('issues', '查看 Issues', '◉'), new FloorAction('pulls', '查看 Pull Requests', '⇄'),
      new FloorAction('links', '仓库链接与 Clone', '↗'), new FloorAction('source', '下载源码 ZIP', '↓'), new FloorAction('refresh', '刷新仓库', '↻')]);
    case 'readme': return new FloorCopy('阅读工具', '支持锚点、顺滑翻页与图片预览', [
      new FloorAction('top', '文档开头', '↑'), new FloorAction('bottom', '文档末尾', '↓'),
      new FloorAction('refresh', '重新加载文档', '↻'), new FloorAction('web', '在 GitHub 查看仓库', '↗')]);
    case 'tree': return new FloorCopy('代码工具', '当前分支、目录与源码', [
      new FloorAction('branches', '切换分支', '⑂'), new FloorAction('source', '下载当前分支 ZIP', '↓'), new FloorAction('refresh', '刷新目录', '↻')]);
    case 'branches': return new FloorCopy('分支列表', '选择一个分支后返回代码目录', [
      new FloorAction('refresh', '刷新分支', '↻'), new FloorAction('back', '返回代码目录', '‹')]);
    case 'file': return new FloorCopy('文件工具', '表冠滚动；代码支持横读', [
      new FloorAction('wrap', '切换换行／横读', '≡'), new FloorAction('top', '当前页开头', '↑'), new FloorAction('bottom', '当前页末尾', '↓')]);
    case 'threads': return new FloorCopy('讨论筛选', '快速切换问题或 PR 的状态', [
      new FloorAction('threadsOpen', '查看未关闭', '◉'), new FloorAction('threadsClosed', '查看已关闭', '✓'), new FloorAction('refresh', '刷新讨论列表', '↻')]);
    case 'issue': return new FloorCopy('讨论工具', '正文、通知对应评论与 GitHub 链接', [
      new FloorAction('target', '打开通知对应评论', '↳'), new FloorAction('refresh', '刷新讨论', '↻'), new FloorAction('web', '在 GitHub 查看', '↗')]);
    case 'comment': return new FloorCopy('评论工具', '查看原始讨论或返回上一页', [
      new FloorAction('web', '在 GitHub 查看', '↗'), new FloorAction('back', '返回讨论', '‹')]);
    case 'releases': return new FloorCopy('版本工具', '在表上跟踪公开发行版本', [
      new FloorAction('refresh', '刷新 Releases', '↻'), new FloorAction('web', '在 GitHub 查看 Releases', '↗')]);
    case 'release': return new FloorCopy('版本详情', '快速到达附件，或浏览其他版本', [
      new FloorAction('assets', '查看版本附件', '↓'), new FloorAction('back', '返回版本列表', '‹')]);
    case 'assets': return new FloorCopy('附件工具', '下载公开附件；同时只传输一个任务', [
      new FloorAction('transfers', '查看下载任务', '↓'), new FloorAction('back', '返回版本说明', '‹')]);
    case 'transfer': return new FloorCopy('下载控制', '根据当前任务状态提供下载操作', [
      new FloorAction('transferState', '暂停、继续或导出', '↓'), new FloorAction('speed', '连接测速', '↻')]);
    case 'groups': return new FloorCopy('分组工具', '分组只保存在手表', [
      new FloorAction('bottom', '到新建分组', '+'), new FloorAction('saved', '返回本机收藏', '☆')]);
    case 'groupPicker': return new FloorCopy('收藏到分组', '选择已有分组，也可新建', [
      new FloorAction('bottom', '到新建分组', '+'), new FloorAction('back', '返回仓库', '‹')]);
    case 'group': return new FloorCopy('分组详情', '重命名或移除分组不会同步到 GitHub', [
      new FloorAction('bottom', '到分组设置', '⚙'), new FloorAction('back', '返回分组列表', '‹')]);
    case 'settings': return new FloorCopy('连接与外观', '切换外观、重看教程或检查连接', [
      new FloorAction('speed', '网络与下载测速', '↻'), new FloorAction('otp', '双因素验证码', '◈'),
      new FloorAction('transfers', '下载任务', '↓'), new FloorAction('guide', '重新看新手教程', '?')]);
    case 'speed': return new FloorCopy('连接诊断', '只向你选定的测速地址发出匿名下载请求', [
      new FloorAction('officialSpeed', '测试 GitHub 官方连接', '↻'), new FloorAction('back', '返回设置', '‹')]);
    case 'otp': return new FloorCopy('验证码工具', '密钥和验证码不会离开手表', [
      new FloorAction('newOtp', '添加验证码账户', '+'), new FloorAction('otpRefresh', '刷新本机账户', '↻')]);
    case 'otpAdd': return new FloorCopy('安全提示', '手表支持 Base32 密钥和 otpauth 链接；不要分享密钥', [
      new FloorAction('back', '放弃输入并返回', '‹')]);
    case 'otpCode': return new FloorCopy('验证码隐私', '打开这个面板时会隐藏验证码', [
      new FloorAction('back', '返回账户列表', '‹')]);
    case 'links': return new FloorCopy('仓库链接', '长按正文里的链接可复制', [
      new FloorAction('web', '在 GitHub 查看仓库', '↗'), new FloorAction('back', '返回仓库', '‹')]);
    case 'shared': return new FloorCopy('分享链接', '确认之后才会打开仓库', [
      new FloorAction('acceptShared', '打开这个仓库', '↗'), new FloorAction('back', '取消并返回', '‹')]);
    default: return new FloorCopy('快捷面板', '回到当前页面开头，或切换外观', []);
  }
}
