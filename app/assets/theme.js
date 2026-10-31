/**
 * theme.js —— 白天 / 夜间
 *
 * 引入方式：必须放在 <head> 里、样式表之后、<body> 之前，并且不要加 defer / async。
 *   <link rel="stylesheet" href="assets/style.css">
 *   <script src="assets/theme.js"></script>
 * 它是同步脚本，在首帧绘制之前就把 <html data-theme> 定下来，
 * 否则会先闪一下白天再变黑——那个闪比没有夜间模式更难受。
 *
 * 主题只有一个开关：<html data-theme="light|dark">。
 * 配色与各组件覆盖全在 style.css 末尾那一层，这个文件不写任何样式。
 */
(function () {
  'use strict';

  var KEY = 'renlu.theme';                 // 只记用户的显式选择，不记时间推断的结果
  var root = document.documentElement;

  function saved() {
    var v = null;
    try { v = localStorage.getItem(KEY); } catch (e) { /* 隐私模式下会抛，忽略即可 */ }
    return (v === 'light' || v === 'dark') ? v : null;
  }

  /* 没存过就按时间猜：18:00 之后、05:00 之前进夜间。
     晚上打开的人，多半就是想说点什么。 */
  function byClock() {
    var h = new Date().getHours();
    return (h >= 18 || h < 5) ? 'dark' : 'light';
  }

  function initial() {
    // ?theme=light|dark 强制指定，只用于对照检查两种模式，不写回 localStorage
    var q = null;
    try { q = new URLSearchParams(location.search).get('theme'); } catch (e) { }
    if (q === 'light' || q === 'dark') return q;
    return saved() || byClock();
  }

  /* 把状态刷到按钮上：整颗按钮的 aria-pressed 表示「夜间是否打开」 */
  function sync(mode) {
    var opts = document.querySelectorAll('.theme-toggle__opt');
    for (var i = 0; i < opts.length; i += 1) {
      opts[i].setAttribute('data-on', String(opts[i].getAttribute('data-mode') === mode));
    }
    var btns = document.querySelectorAll('.theme-toggle');
    for (var j = 0; j < btns.length; j += 1) {
      btns[j].setAttribute('aria-pressed', String(mode === 'dark'));
    }
  }

  function apply(mode, remember) {
    root.setAttribute('data-theme', mode);
    sync(mode);
    if (remember) {
      try { localStorage.setItem(KEY, mode); } catch (e) { }
    }
  }

  apply(initial(), false);                 // 首帧：此时 body 还没解析，按钮还不存在，sync 是空转

  function mount() {
    var btns = document.querySelectorAll('.theme-toggle');
    for (var i = 0; i < btns.length; i += 1) {
      btns[i].addEventListener('click', function () {
        apply(root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark', true);
      });
    }
    sync(root.getAttribute('data-theme'));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mount);
  } else {
    mount();
  }

  /* 调试用：RenluTheme.set('dark')。不挂到 Renlu 上——api.js 会整体替换那个对象 */
  window.RenluTheme = {
    get: function () { return root.getAttribute('data-theme'); },
    set: function (mode) { apply(mode === 'dark' ? 'dark' : 'light', true); },
  };
}());
