/**
 * api.js —— 数据访问的唯一出口
 *
 * 两条纪律（改代码时请守住）：
 *   1. 页面只调这一层，不直接碰 cloud client，更不碰表。
 *      平台把表对前端完全收回权限了，绕过这层只会拿到 42501。
 *   2. 业务失败一律在 call() 里转成 ApiError 抛出，不返回「可能是错的」数据。
 *      因为后端错误是 code 字段、HTTP 恒 200，不抛就会被当成成功。
 */
(function (global) {
'use strict';


const KEY_TOKEN = 'renlu.token';
const KEY_DEVICE = 'renlu.device';
const KEY_GATE = 'renlu.gate';
const KEY_REQID = 'renlu.requestId';
const KEY_NICK = 'renlu.nick';

/** 后端业务码与文案都封装在这里，页面按 code 分支，不解析 message */
class ApiError extends Error {
  constructor(code, message, data) {
    super(message || '请求失败');
    this.name = 'ApiError';
    this.code = code;
    this.data = data ?? null;
  }
  get isAuthLost() { return this.code === 40101; }
  get isGateClosed() { return this.code === 40301; }
  get isNotFound() { return this.code === 40401; }
  get isRateLimited() { return String(this.code).startsWith('429'); }
  get isCloudMissing() { return this.code === 'NO_CLOUD'; }
}

/* ------------------------------------------------------------
   云端客户端注入
   环境未开通时不伪造数据，只让调用明确失败 —— 页面照常渲染结构。
   ------------------------------------------------------------ */

let client = null;

/** 由入口页在初始化 SDK 后调用 */
function bindCloud(c) { client = c; }

function cloudReady() { return Boolean(client); }

/* ------------------------------------------------------------
   本地状态
   ------------------------------------------------------------ */

function uuid() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

/** 设备标识：清缓存即丢，靠恢复码找回（PRD 7.10） */
function getDeviceId() {
  let v = localStorage.getItem(KEY_DEVICE);
  if (!v) {
    v = uuid().replace(/-/g, '').slice(0, 24);
    localStorage.setItem(KEY_DEVICE, v);
  }
  return v;
}

function setDeviceId(v) { localStorage.setItem(KEY_DEVICE, v); }

function getNickname() { return localStorage.getItem(KEY_NICK) || ''; }

/* ------------------------------------------------------------
   预设头像（V1.6）
   8 个单色线稿，纯 SVG 字符串，不引任何外部图片：
     - 教室网络不可靠，外链图挂了头像就是一块空白
     - 匿名产品不放真人照片，库里只存一个代码（leaf / moon / …）
   ------------------------------------------------------------ */

const KEY_AVATAR = 'renlu.avatar';

const AVATARS = [
  { code: 'leaf',  name: '叶子' },
  { code: 'moon',  name: '月亮' },
  { code: 'star',  name: '星星' },
  { code: 'hill',  name: '山丘' },
  { code: 'cloud', name: '云' },
  { code: 'book',  name: '书' },
  { code: 'cat',   name: '猫' },
  { code: 'cup',   name: '茶杯' },
];

const AVATAR_PATHS = {
  leaf:  '<path d="M19.5 4.5C10.5 4.5 4.5 9 4.5 15.5c0 2 1.2 3.5 3 3.5 7 0 12-6 12-14.5z"/><path d="M4.8 19.2C6.6 13.6 10.2 9.8 15 7.2"/>',
  moon:  '<path d="M20.5 13.5A8.8 8.8 0 1 1 10.5 3.4a7.2 7.2 0 0 0 10 10.1z"/>',
  star:  '<path d="M12 3.6l2.5 5.2 5.7.8-4.1 4 1 5.7-5.1-2.7-5.1 2.7 1-5.7-4.1-4 5.7-.8z"/>',
  hill:  '<path d="M3.2 18.4l5.5-8.6 3.4 5.2 2.4-3.3 6.3 6.7z"/><circle cx="17.2" cy="6.4" r="1.7"/>',
  cloud: '<path d="M7.2 17.4h10a3.4 3.4 0 0 0 .3-6.8 5.1 5.1 0 0 0-9.7 1.3 3.3 3.3 0 0 0-.6 5.5z"/>',
  book:  '<path d="M5 5.2h8.4a3.2 3.2 0 0 1 3.2 3.2v11H8.2A3.2 3.2 0 0 1 5 16.2z"/><path d="M16.6 8.6H19v11h-2.4"/><path d="M8.2 8.6h4.4M8.2 11.6h4.4"/>',
  cat:   '<path d="M5.4 10.4V5.6l3.3 2.2a8.4 8.4 0 0 1 6.6 0l3.3-2.2v4.8"/><path d="M5.4 10.4a6.6 6.6 0 0 0 13.2 0"/><circle cx="9.7" cy="11.2" r=".85"/><circle cx="14.3" cy="11.2" r=".85"/>',
  cup:   '<path d="M6 8.6h9.4v7a4 4 0 0 1-4 4h-1.4a4 4 0 0 1-4-4z"/><path d="M15.4 10.4h1.8a2.6 2.6 0 0 1 0 5.2h-1.8"/><path d="M7.6 4.6v1.8M10.7 4v2.4M13.8 4.6v1.8"/>',
};

/** 头像 SVG。未知代码一律回退到叶子，绝不返回空字符串 */
function avatarSvg(code, size) {
  const s = size || 22;
  const key = AVATAR_PATHS[code] ? code : 'leaf';
  return '<svg viewBox="0 0 24 24" width="' + s + '" height="' + s + '" fill="none"' +
    ' stroke="currentColor" stroke-width="1.6" stroke-linecap="round"' +
    ' stroke-linejoin="round" aria-hidden="true">' + AVATAR_PATHS[key] + '</svg>';
}

function getAvatar() { return localStorage.getItem(KEY_AVATAR) || ''; }

/** 昵称与头像一起写本地缓存：导航栏头像不必等接口回来就能画对 */
function setIdentity(nick, avatarCode) {
  if (nick) localStorage.setItem(KEY_NICK, nick);
  if (avatarCode) localStorage.setItem(KEY_AVATAR, avatarCode);
}

const session = {
  get token() { return localStorage.getItem(KEY_TOKEN) || ''; },
  set token(v) {
    if (v) localStorage.setItem(KEY_TOKEN, v);
    else localStorage.removeItem(KEY_TOKEN);
  },
  get gateOk() { return sessionStorage.getItem(KEY_GATE) || ''; },
  set gateOk(v) {
    if (v) sessionStorage.setItem(KEY_GATE, v);
    else sessionStorage.removeItem(KEY_GATE);
  },
  /** 同一份投稿表单复用同一个幂等键；提交成功后清掉（R6-10） */
  get requestId() {
    let v = sessionStorage.getItem(KEY_REQID);
    if (!v) { v = uuid(); sessionStorage.setItem(KEY_REQID, v); }
    return v;
  },
  clearRequestId() { sessionStorage.removeItem(KEY_REQID); },
  clearAll() {
    this.token = '';
    this.gateOk = '';
    this.clearRequestId();
  },
};

/* ------------------------------------------------------------
   统一调用
   ------------------------------------------------------------ */

async function call(fn, params) {
  if (!client) {
    throw new ApiError('NO_CLOUD', '云服务还没开通，页面现在只能看版式，不能真正读写。');
  }

  let res;
  try {
    res = await client.database.rpc(fn, params);
  } catch (e) {
    throw new ApiError('NETWORK', '网络好像断了，检查一下再试', e);
  }

  const { data, error } = res;
  if (error) {
    throw new ApiError('RPC_ERROR', error.message || '服务异常，稍后再试', error);
  }
  if (!data || typeof data.code !== 'number') {
    throw new ApiError('BAD_SHAPE', '服务返回的格式不对，可能是版本不匹配', data);
  }
  if (data.code !== 0) {
    throw new ApiError(data.code, data.message, data.data);
  }
  return data.data;
}

/* ------------------------------------------------------------
   会话引导
   ------------------------------------------------------------ */

/**
 * 保证有可用 token。
 * 有 token → 直接返回；没有 → 直接建号 / 取会话。
 *
 * V1.4 起不再有访问口令：服务端 api_session_init 只在 app_config.gate_pass_hash
 * 非空时才校验 gate_ok，那边已经把 hash 清空了，这里也就不必先去门页换 gate_ok。
 * 观众点开链接直接就是内容，不会看到输入框。
 * 想恢复口令：把 hash 写回 app_config 即可，这条分支会自动重新要求过门。
 */
async function ensureSession() {
  // 云端未接线时先报这个，否则会误报成「需要输口令」，把版式预览卡在门页
  if (!client) {
    throw new ApiError('NO_CLOUD', '云服务还没开通，页面现在只能看版式，不能真正读写。');
  }
  if (session.token) return session.token;

  const d = await api.sessionInit();
  return d.token;
}

/* ------------------------------------------------------------
   接口（与详细设计 4.1 一一对应）
   ------------------------------------------------------------ */

const api = {
  /* A-01 口令校验。通过后拿到短期 gate_ok，用来换正式 token */
  async gateVerify(pass) {
    const d = await call('api_gate_verify', { p_pass: pass });
    session.gateOk = d.gate_ok;
    return d;
  },

  /* A-02 建号 / 取会话，返回 { token, user } */
  async sessionInit() {
    const d = await call('api_session_init', {
      p_device: getDeviceId(),
      p_gate_ok: session.gateOk || null,
    });
    session.token = d.token;
    if (d.user?.device_id) setDeviceId(d.user.device_id);
    // 昵称只用于展示，不参与判权；取不到就退回通用文案
    if (d.user && d.user.nickname) localStorage.setItem(KEY_NICK, d.user.nickname);
    return d;
  },

  /* A-03 主题与条数（条数已排除示例内容，DC-17） */
  async topics() {
    await ensureSession();
    return call('api_topics', { p_token: session.token });
  },

  /* A-04 列表：topic / status / keyword / page / size */
  async list({ topic = null, status = null, keyword = null, page = 1, size = 10 } = {}) {
    await ensureSession();
    return call('api_story_list', {
      p_token: session.token,
      p_topic: topic,
      p_status: status,
      p_keyword: keyword,
      p_page: page,
      p_size: size,
    });
  },

  /* A-05 详情。隐藏内容也返回 code=0，按 data.status 分支 */
  async detail(id) {
    await ensureSession();
    return call('api_story_detail', { p_token: session.token, p_story_id: id });
  },

  /* A-06 发布，带幂等键 */
  async create(payload) {
    await ensureSession();
    const d = await call('api_story_create', {
      p_token: session.token,
      p_payload: payload,
      p_request_id: session.requestId,
    });
    session.clearRequestId();
    return d;
  },

  /* A-07 编辑 */
  async update(id, payload) {
    await ensureSession();
    return call('api_story_update', {
      p_token: session.token, p_story_id: id, p_payload: payload,
    });
  },

  /* A-08 补写「后来」 */
  async resolve(id, bodyAfter) {
    await ensureSession();
    return call('api_story_resolve', {
      p_token: session.token, p_story_id: id, p_body_after: bodyAfter,
    });
  },

  /* A-09 删除 */
  async remove(id) {
    await ensureSession();
    return call('api_story_delete', { p_token: session.token, p_story_id: id });
  },

  /* A-10 致谢。重复致谢也返回成功，计数不变 */
  async thanks(id) {
    await ensureSession();
    return call('api_story_thanks', { p_token: session.token, p_story_id: id });
  },

  /* A-16 共鸣「我也走过这段」。同一设备同一条只计一次（V1.1 新增） */
  async resonate(id) {
    await ensureSession();
    return call('api_story_resonate', { p_token: session.token, p_story_id: id });
  },

  /* A-17 批量查共鸣状态：ids → [{story_id, resonate_count, resonated}]（V1.1） */
  async resonateState(ids) {
    await ensureSession();
    return call('api_resonate_state', { p_token: session.token, p_story_ids: ids });
  },

  /* A-18 首页统计：N 位旅人 / M 个路标 / K 段已走完（V1.1，无需会话） */
  async stats() {
    return call('api_stats', {});
  },

  /* A-26 公开配置（V1.4）：目前只有投稿开关。不需要会话，
     拿不到时按「开放」处理——宁可多露一个入口，也别把入口误锁死 */
  async publicConfig() {
    return call('api_public_config', {});
  },

  /* ---------- 管理端（A-27 ~ A-29）：每次调用都带口令，不落会话 ----------
     没有账号体系，所以「管理员」= 一个 bcrypt 口令。口令只存在页面内存里，
     不进 localStorage；关掉标签页就没了。失败 8 次 / 5 分钟会锁住。 */

  /* 当前开关状态 + 最近 30 条（含已隐藏的，方便恢复） */
  async adminState(pass) {
    return call('api_admin_state', { p_pass: pass });
  },

  /* 开放 / 关闭投稿。返回 { publish_open } */
  async adminSetPublish(pass, open) {
    return call('api_admin_set_publish', { p_pass: pass, p_open: Boolean(open) });
  },

  /* 处置单条：action = 'hide' | 'restore' | 'delete' */
  async adminStory(pass, id, action) {
    return call('api_admin_story', { p_pass: pass, p_story_id: id, p_action: action });
  },

  /* A-30 我的身份（昵称 + 头像代码）。导航栏头像用它，比 api_me 轻 */
  async identity() {
    await ensureSession();
    return call('api_my_identity', { p_token: session.token });
  },

  /* A-31 改昵称 / 换头像。只传想改的那个，另一个传 null */
  async updateProfile({ nickname = null, avatar = null }) {
    await ensureSession();
    return call('api_update_profile', {
      p_token: session.token, p_nickname: nickname, p_avatar: avatar,
    });
  },

  /* A-19 点赞 / 取消点赞（V1.3，toggle）。返回 { liked, like_count }。
     作者会在首页铃铛里收到一条，但看不到是谁——接口也不返回操作者身份 */
  async like(id) {
    await ensureSession();
    return call('api_story_like', { p_token: session.token, p_story_id: id });
  },

  /* A-20 收藏 / 取消收藏（V1.3，toggle）。返回 { favorited } */
  async favorite(id) {
    await ensureSession();
    return call('api_story_favorite', { p_token: session.token, p_story_id: id });
  },

  /* A-21 记一次浏览（V1.3）。失败不影响正文阅读，页面自己吞掉异常 */
  async view(id) {
    await ensureSession();
    return call('api_story_view', { p_token: session.token, p_story_id: id });
  },

  /* A-22 批量查点赞 / 收藏状态：ids → [{ story_id, like_count, liked, favorited }] */
  async interactState(ids) {
    await ensureSession();
    return call('api_interaction_state', { p_token: session.token, p_story_ids: ids });
  },

  /* A-23 我的赞过 / 收藏 / 浏览记录。kind = 'like' | 'favorite' | 'view' */
  async myMarks({ kind, page = 1, size = 10 }) {
    await ensureSession();
    return call('api_my_marks', {
      p_token: session.token, p_kind: kind, p_page: page, p_size: size,
    });
  },

  /* A-24 铃铛：未读数 + 最近通知。actor 拿到了也不许渲染，见页面注释 */
  async notifications(limit = 20) {
    await ensureSession();
    return call('api_notifications', { p_token: session.token, p_limit: limit });
  },

  /* A-25 全部标为已读 */
  async readNotifications() {
    await ensureSession();
    return call('api_notification_read', { p_token: session.token });
  },

  /* A-26 个人空间头部资料与统计 */
  async me() {
    await ensureSession();
    return call('api_me', { p_token: session.token });
  },

  /* A-12 我的经历 */
  async myStories({ page = 1, size = 10 } = {}) {
    await ensureSession();
    return call('api_my_stories', { p_token: session.token, p_page: page, p_size: size });
  },

  /* A-13 查看恢复码 */
  async recoveryCode() {
    await ensureSession();
    return call('api_my_recovery_code', { p_token: session.token });
  },

  /* A-14 主动重置恢复码（旧码立即失效） */
  async resetRecoveryCode() {
    await ensureSession();
    return call('api_recovery_reset', { p_token: session.token });
  },

  /* A-15 认领：用恢复码把内容迁到当前设备 */
  async claim(code) {
    const d = await call('api_claim', {
      p_token: session.token || null,
      p_new_device: getDeviceId(),
      p_code: code,
    });
    if (d.token) session.token = d.token;
    if (d.user?.device_id) setDeviceId(d.user.device_id);
    return d;
  },
};

/**
 * 去门页的地址，顺手把「从哪来」和「链接里的口令」带过去。
 *
 * 两件事都得带上，否则观众点开分享链接会看到口令输入框：
 *   1. to=当前页：门页通过后回到原来那一页，而不是一律回首页（AC-04）
 *   2. k=口令：路演分享链接把口令放在 ?k= 里，门页读到它才敢静默通过
 */
function gateUrl() {
  const here = (location.pathname.split('/').pop() || 'index.html') + location.search;
  const key = new URLSearchParams(location.search).get('k');
  let url = 'gate.html?to=' + encodeURIComponent(here);
  if (key) url += '&k=' + encodeURIComponent(key);
  return url;
}

/* 挂到全局，供普通 <script> 使用。
   不用 ES module 是刻意的：file:// 下浏览器会以 CORS 为由拒绝加载相对模块，
   队友双击打开就看不到任何内容。 */
global.Renlu = { ApiError, api, session, ensureSession, getDeviceId, setDeviceId, bindCloud, cloudReady, getNickname, gateUrl,
  AVATARS, avatarSvg, getAvatar, setIdentity };

})(window);
