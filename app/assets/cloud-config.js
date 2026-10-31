/**
 * 云服务配置
 *
 * endpoint 与 publishableKey 都是可公开的值：它们只用来标识「哪个应用」，
 * 真正的权限校验在数据库的函数里。所以这个文件可以进仓库。
 *
 * 注意 endpoint 不能随便改：它绑定了应用的域名，换了会导致请求被拒。
 */
window.RENLU_CONFIG = {
  endpoint: 'https://renlu-22866.app.workbuddy.host',
  oauthRelayBaseUrl: 'https://www.workbuddy.cn/v2/as/genie-baas/oauth',
  publishableKey: 'wbpk_gpfIqbE3k0eL0cFJb8lEx0_vJJnwHtAEpo1B5XHxoqVWH5d9Zw8pWuu',

  // 路演期间只读：收起「去写一段」的入口，避免观众随手写的内容出现在列表里。
  // 路演结束后改成 false 再发布一次即可恢复投稿。
  readOnly: true,
};
