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

  // 投稿开关。路演期间曾经设为 true（收起「写一段」入口），
  // V1.3 起恢复投稿：首页右上角的 + 直达写页。
  readOnly: false,

  // 客服邮箱：填了之后「社区规范 → 联系客服」会显示邮件入口与复制按钮；
  // 留空则显示「路演现场直接找同学反馈」的兜底文案。
  // 刻意不写死假地址 —— 换成你自己的邮箱再发布即可。
  supportEmail: '',
};
