/**
 * 启动：把云服务客户端交给 api.js
 *
 * 页面统一按这个顺序引入：
 *   1. SDK（CDN）
 *   2. cloud-config.js
 *   3. api.js
 *   4. boot.js
 *   5. 页面自己的脚本
 */
(function () {
  'use strict';

  if (typeof WorkBuddyCloud === 'undefined') {
    console.error('[boot] SDK 未加载，请检查网络或 CDN 地址');
    return;
  }
  if (!window.RENLU_CONFIG || !window.Renlu) {
    console.error('[boot] 配置文件或 api.js 未加载');
    return;
  }

  try {
    const client = WorkBuddyCloud.createWorkBuddyCloud(window.RENLU_CONFIG);
    window.Renlu.bindCloud(client);
  } catch (e) {
    console.error('[boot] 云服务客户端初始化失败', e);
  }
})();
