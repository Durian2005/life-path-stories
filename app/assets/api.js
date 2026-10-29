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
 * 有 token → 直接返回；有 gate_ok → 静默换 token；
 * 都没有 → 抛 40301，由页面跳到门页。
 */
async function ensureSession() {
  // 云端未接线时先报这个，否则会误报成「需要输口令」，把版式预览卡在门页
  if (!client) {
    throw new ApiError('NO_CLOUD', '云服务还没开通，页面现在只能看版式，不能真正读写。');
  }
  if (session.token) return session.token;

  if (session.gateOk) {
    const d = await api.sessionInit();
    return d.token;
  }
  throw new ApiError(40301, '需要先输入访问口令');
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

/* 挂到全局，供普通 <script> 使用。
   不用 ES module 是刻意的：file:// 下浏览器会以 CORS 为由拒绝加载相对模块，
   队友双击打开就看不到任何内容。 */
global.Renlu = { ApiError, api, session, ensureSession, getDeviceId, setDeviceId, bindCloud, cloudReady, getNickname };

})(window);
