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

  /* 只读模式（路演期间）：收起所有「去写一段」的入口。
     链接是发给观众自己点开的，任何人都能真写一条并立刻出现在列表里；
     路演结束把 cloud-config.js 里的 readOnly 改回 false 再发布就恢复。
     只动入口，不动页面逻辑 —— 直接访问 write.html 仍然可用。
     放在最前面：这段是纯 DOM 操作，不该因为 SDK 没加载就一起失效。 */
  if (window.RENLU_CONFIG && window.RENLU_CONFIG.readOnly) {
    document.querySelectorAll('a.nav__add[href="write.html"], a.btn[href="write.html"]')
      .forEach((el) => { el.hidden = true; });
  }

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

  /* 投稿开关（V1.4）：开关在数据库里，管理员可以随时改，所以每次进页面都查一次。
     关着就把「写一段」的号召按钮收起来，读的人不会一直被邀请去写一条发不出去的。
     查不到（断网 / 接口挂了）就按开放处理，宁可多露一个入口，也别把人挡在
     自己都没法试的路上。write.html 有提示条，后端 api_story_create 也硬拦。
     ⚠️ 导航栏的「+」不藏：它是固定的功能入口，藏了会让人以为这站不能发帖。
     点它进 write.html 会看到「投稿还没开放」，按钮是灰的。 */
  if (window.Renlu && window.Renlu.api) {
    window.Renlu.api.publicConfig().then((cfg) => {
      if (!cfg || cfg.publish_open !== false) return;
      document.querySelectorAll('a.btn[href="write.html"]')
        .forEach((el) => { el.hidden = true; });
      document.documentElement.classList.add('publish-closed');
    }).catch(() => { /* 拿不到就当作开放 */ });
  }
})();
