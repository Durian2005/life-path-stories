-- ============================================================
-- V1.4 · 投稿开关 + 管理入口
--
-- 背景：展示当天想让「谁都能发」的效果，但展示之前不希望内容被随手写脏。
--       于是把投稿口做成运行期开关，由管理员在 /admin.html 上开合，
--       而不是像 11-01 那样改前端 readOnly 再重新发布一次。
--
-- 三条防线（缺一条都能被绕过）：
--   1. 首页 / 我的 / 详情页的「+」与「写下我的这一段」：boot.js 查到关着就隐藏
--   2. write.html 自己显示提示条并禁用「预览」
--   3. api_story_create 前置检查：绕过页面直接调接口也会被拒（code 43001）
--
-- 管理员 = 一个 bcrypt 口令（产品没有账号体系，设备身份不能当管理员用：
-- 换浏览器 / 清缓存就失效，现场容易翻车）。口令只在页面内存里，不落盘。
-- ============================================================

-- ---------- 1. 配置项 ----------
-- 原来的 CHECK 只允许三个 key，先放宽
ALTER TABLE app_config DROP CONSTRAINT ck_config_key;
ALTER TABLE app_config ADD CONSTRAINT ck_config_key CHECK (
  key IN ('gate_pass_hash', 'topic_open', 'gate_locked_until',
          'publish_open', 'admin_pass_hash'));

INSERT INTO app_config (key, value) VALUES
  ('publish_open', '0'),        -- '1' 开放 / '0' 关闭；缺省按开放处理
  ('admin_pass_hash', '')       -- 空 = 管理入口未开通（不是「空口令能进」）
ON CONFLICT (key) DO NOTHING;

-- 设口令（换成自己的；改口令就重跑这一句）
-- UPDATE app_config SET value = crypt('你的口令', gen_salt('bf')) WHERE key = 'admin_pass_hash';

-- ---------- 2. 管理口令校验 ----------
-- 返回 'ok' / 'bad' / 'locked' / 'disabled'。内部函数，不对 anon 授权。
CREATE OR REPLACE FUNCTION public._admin_ok(p_pass text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_hash text;
    v_win  timestamptz;
    v_fail int;
BEGIN
    SELECT value INTO v_hash FROM app_config WHERE key = 'admin_pass_hash';
    IF v_hash IS NULL OR v_hash = '' THEN
        RETURN 'disabled';
    END IF;

    -- 失败计数按 5 分钟窗口累加，8 次就锁。窗口过了自动作废，不需要人解锁
    v_win := to_timestamp(floor(extract(epoch FROM now())/300)*300);
    SELECT coalesce(sum(hit_count),0) INTO v_fail
      FROM rate_limit
     WHERE bucket = 'admin_fail' AND subject = 'unknown' AND window_start = v_win;
    IF v_fail >= 8 THEN
        RETURN 'locked';
    END IF;

    IF crypt(coalesce(p_pass,''), v_hash) = v_hash THEN
        DELETE FROM rate_limit WHERE bucket = 'admin_fail' AND subject = 'unknown';
        RETURN 'ok';
    END IF;

    INSERT INTO rate_limit (bucket, subject, window_start, hit_count)
    VALUES ('admin_fail', 'unknown', v_win, 1)
    ON CONFLICT (bucket, subject, window_start)
    DO UPDATE SET hit_count = rate_limit.hit_count + 1;

    RETURN 'bad';
EXCEPTION WHEN OTHERS THEN
    RETURN 'bad';
END;
$fn$;

-- ---------- 3. 公开配置（页面用来决定要不要露出投稿入口） ----------
CREATE OR REPLACE FUNCTION public.api_public_config()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_open text;
BEGIN
    SELECT value INTO v_open FROM app_config WHERE key = 'publish_open';
    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('publish_open', coalesce(v_open,'1') = '1'));
EXCEPTION WHEN OTHERS THEN
    -- 配置读不到时按开放处理：宁可多露一个入口，也别把人挡在门外
    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('publish_open', true));
END;
$fn$;

-- ---------- 4. 管理面板数据 ----------
CREATE OR REPLACE FUNCTION public.api_admin_state(p_pass text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_st text;
    v_open text;
    v_items jsonb;
    v_total int;
    v_hidden int;
BEGIN
    v_st := _admin_ok(p_pass);
    IF v_st = 'disabled' THEN
        RETURN jsonb_build_object('code',40302,'message','管理入口还没开通');
    ELSIF v_st = 'locked' THEN
        RETURN jsonb_build_object('code',42901,'message','试错次数太多，等几分钟再试');
    ELSIF v_st <> 'ok' THEN
        RETURN jsonb_build_object('code',40303,'message','口令不对');
    END IF;

    SELECT value INTO v_open FROM app_config WHERE key = 'publish_open';

    SELECT coalesce(jsonb_agg(item ORDER BY oi DESC),'[]'::jsonb) INTO v_items
      FROM (
        SELECT jsonb_build_object(
                 'id', s.story_id, 'title', s.title,
                 'author', s.author_nickname,
                 'status', s.status, 'visibility', s.visibility,
                 'is_sample', (s.source_type = 'qa'),
                 'like_count', s.like_count, 'thanks_count', s.thanks_count,
                 'created_at', to_char(s.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')
               ) AS item, s.story_id AS oi
          FROM story s
         WHERE s.deleted_at IS NULL
         ORDER BY s.story_id DESC
         LIMIT 30
      ) x;

    SELECT count(*) INTO v_total FROM story WHERE deleted_at IS NULL;
    SELECT count(*) INTO v_hidden FROM story WHERE deleted_at IS NULL AND status = 'hidden';

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object(
            'publish_open', coalesce(v_open,'1') = '1',
            'total', v_total, 'hidden', v_hidden, 'items', v_items));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- ---------- 5. 开关投稿 ----------
CREATE OR REPLACE FUNCTION public.api_admin_set_publish(p_pass text, p_open boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_st text;
BEGIN
    v_st := _admin_ok(p_pass);
    IF v_st = 'disabled' THEN
        RETURN jsonb_build_object('code',40302,'message','管理入口还没开通');
    ELSIF v_st = 'locked' THEN
        RETURN jsonb_build_object('code',42901,'message','试错次数太多，等几分钟再试');
    ELSIF v_st <> 'ok' THEN
        RETURN jsonb_build_object('code',40303,'message','口令不对');
    END IF;

    UPDATE app_config SET value = CASE WHEN p_open THEN '1' ELSE '0' END, updated_at = now()
     WHERE key = 'publish_open';

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('publish_open', coalesce(p_open,false)));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- ---------- 6. 单条处置：hide / restore / delete ----------
-- 注意 ck_story_before_hidden：置为 hidden 时必须把原状态记进 status_before_hidden，
-- 否则约束直接报错（第一次实现就踩了这个，管理页返回 50001）。
CREATE OR REPLACE FUNCTION public.api_admin_story(p_pass text, p_story_id bigint, p_action text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_st     text;
    v_status text;
    v_before text;
    v_new    text;
BEGIN
    v_st := _admin_ok(p_pass);
    IF v_st = 'disabled' THEN
        RETURN jsonb_build_object('code',40302,'message','管理入口还没开通');
    ELSIF v_st = 'locked' THEN
        RETURN jsonb_build_object('code',42901,'message','试错次数太多，等几分钟再试');
    ELSIF v_st <> 'ok' THEN
        RETURN jsonb_build_object('code',40303,'message','口令不对');
    END IF;

    SELECT status, status_before_hidden INTO v_status, v_before
      FROM story WHERE story_id = p_story_id;
    IF v_status IS NULL THEN
        RETURN jsonb_build_object('code',40401,'message','这条不在了');
    END IF;

    IF p_action = 'hide' THEN
        IF v_status <> 'hidden' THEN
            UPDATE story
               SET status_before_hidden = v_status,
                   status = 'hidden'
             WHERE story_id = p_story_id;
        END IF;
        v_new := 'hidden';
    ELSIF p_action = 'restore' THEN
        -- 恢复成隐藏前的样子：原本 resolved 的不会被打回 open
        v_new := CASE WHEN v_status = 'hidden' THEN coalesce(v_before, 'open') ELSE v_status END;
        UPDATE story
           SET status = v_new,
               status_before_hidden = NULL
         WHERE story_id = p_story_id;
    ELSIF p_action = 'delete' THEN
        -- 软删：列表与详情都看不到，作者也拿不回来，但数据库里留痕
        UPDATE story SET deleted_at = now() WHERE story_id = p_story_id;
        v_new := 'deleted';
    ELSE
        RETURN jsonb_build_object('code',40001,'message','不认识的操作');
    END IF;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('story_id', p_story_id, 'action', p_action, 'status', v_new));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- ---------- 7. 投稿拦截：原函数改名做实现，外面套一层开关 ----------
-- 直接加在 api_story_create 里也行，但它有两千多字，改一次风险大；
-- 改名 + 包一层只动入口，实现一行没碰。
ALTER FUNCTION public.api_story_create(text, jsonb, text) RENAME TO _story_create_impl;

CREATE OR REPLACE FUNCTION public.api_story_create(p_token text, p_payload jsonb, p_request_id text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_open text;
BEGIN
    SELECT value INTO v_open FROM app_config WHERE key = 'publish_open';
    IF coalesce(v_open,'1') <> '1' THEN
        RETURN jsonb_build_object('code',43001,'message','投稿现在没开着，先读读别人的吧');
    END IF;

    RETURN public._story_create_impl(p_token, p_payload, p_request_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- ---------- 8. 权限收口 ----------
-- 关键：改名会把原来的 anon 授权一起带过去，不收回就等于开关形同虚设
REVOKE ALL ON FUNCTION public._story_create_impl(text, jsonb, text) FROM anon, authenticated, PUBLIC;
REVOKE ALL ON FUNCTION public._admin_ok(text) FROM anon, authenticated, PUBLIC;

GRANT EXECUTE ON FUNCTION
    public.api_public_config(),
    public.api_admin_state(text),
    public.api_admin_set_publish(text, boolean),
    public.api_admin_story(text, bigint, text),
    public.api_story_create(text, jsonb, text)
TO anon;

-- ---------- 9. 日常操作速查 ----------
-- 开 / 关投稿（也可以用 /admin.html）：
--   UPDATE app_config SET value = '1' WHERE key = 'publish_open';
-- 被锁了想立刻解锁：
--   DELETE FROM rate_limit WHERE bucket = 'admin_fail';
-- 隐藏单条：
--   UPDATE story SET status_before_hidden = status, status = 'hidden' WHERE story_id = ?;
