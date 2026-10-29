/**
 * draft.js —— 投稿草稿（本地，不上服务端）
 *
 * 存在的理由只有两个，都写在 PRD 里：
 *   F6 / AC-36  写了没发也不该丢
 *   F7 / R7-7   预览页刷新要能回投稿页并把内容带回去
 *
 * 两条纪律：
 *   1. 草稿只存 localStorage，不占服务端内容 ID（R7-6）。
 *      预览页渲染的是这份草稿，不是隐藏的「待发布内容」。
 *   2. 「这次预览是不是刚点进来的」用 sessionStorage，因为它是标签页级的：
 *      刷新同一个标签页仍是同一个 session，所以 R7-7 的「刷新回投稿页」成立；
 *      新开标签页则两边互不干扰。
 */
(function (global) {
'use strict';

const KEY = 'renlu.draft';        // 草稿本体，localStorage：跨刷新、跨标签页都在
const KEY_SEEN = 'renlu.previewSeen';  // 已进入过预览，sessionStorage：只活在这个标签页

const FIELDS = ['topic', 'status', 'vis', 'tags', 'title', 'before', 'after', 'stage', 'nickname'];

/** 把表单读成一份草稿。缺字段一律给空值，读回来的东西不靠运气。 */
function normalize(raw) {
  const d = {};
  FIELDS.forEach((k) => {
    const v = raw ? raw[k] : undefined;
    if (k === 'tags') d.tags = Array.isArray(v) ? v.slice(0, 3) : [];
    else d[k] = typeof v === 'string' ? v : '';
  });
  return d;
}

function save(raw) {
  try {
    const d = normalize(raw);
    d.savedAt = Date.now();
    localStorage.setItem(KEY, JSON.stringify(d));
    return true;
  } catch (e) {
    // 隐私模式下列存满都可能抛，草稿失败不该让投稿页崩掉
    return false;
  }
}

function load() {
  let raw;
  try {
    raw = JSON.parse(localStorage.getItem(KEY) || 'null');
  } catch (e) {
    return null;
  }
  if (!raw || typeof raw !== 'object') return null;
  const d = normalize(raw);
  d.savedAt = Number(raw.savedAt) || 0;
  // 全空的草稿等于没有，别让「空表单恢复提示」出现在第一次进页面的人面前
  const empty = !d.title && !d.before && !d.after && !d.tags.length;
  return empty ? null : d;
}

function clear() {
  localStorage.removeItem(KEY);
  sessionStorage.removeItem(KEY_SEEN);
}

/** 从投稿页跳预览前调用：允许这一次进入预览 */
function reopenPreview() { sessionStorage.removeItem(KEY_SEEN); }

/**
 * 预览页专用。两种情况拿不到草稿：
 *   - 没有草稿（直接输地址栏进来，AC-43）
 *   - 这个标签页已经进过一次预览（刷新，R7-7）
 */
function takeForPreview() {
  const d = load();
  if (!d) return null;
  if (sessionStorage.getItem(KEY_SEEN) === '1') return null;
  sessionStorage.setItem(KEY_SEEN, '1');
  return d;
}

global.RenluDraft = { save, load, clear, reopenPreview, takeForPreview };

})(window);
