-- ============================================================
-- V1.6.2 · 共鸣「我也走过这段」改为可取消（2026-11-05）
--
-- 背景：V1.1 的 api_story_resonate 用 INSERT ... ON CONFLICT DO NOTHING，
--       打过点就再也撤不回来；点赞 / 收藏从一开始就是 toggle。
-- 改动：只替换 public.api_story_resonate 一个函数，与 api_story_like 同构：
--       先按 (story_id, device_id) DELETE；删到了就是「取消」→ 计数退 1
--       （GREATEST 防止越界）并返回 resonated=false；没删到就照旧打点 +1。
--       表结构、索引、约束、GRANT、返回字段全部不变。
-- 影响：历史记录与计数不受影响；api_resonate_state 的 EXISTS 判定自动跟随，
--       首页统计条与「我的」里 sum(resonate_count) 会随取消同步回落。
-- 注意：CREATE OR REPLACE 保留原有 owner 与 EXECUTE 授权，无需重新 GRANT；
--       部署后验证 has_function_privilege('anon', oid, 'EXECUTE') 仍为 true。
-- 前端配套：story.html 的 fabFoot、index.html 的 .story__resonate
--       去掉「点过即禁用」的拦截，按返回的 resonated 更新状态与文案。
-- ============================================================

CREATE OR REPLACE FUNCTION public.api_story_resonate(p_token text, p_story_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid   bigint;
    v_dev   varchar(40);
    r       record;
    v_del   boolean;
    v_count int;
BEGIN
    SELECT user_id, device_id INTO v_uid, v_dev
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT author_id, status, deleted_at, source_type, visibility, resonate_count
      INTO r FROM story WHERE story_id = p_story_id FOR UPDATE;
    IF r IS NULL OR r.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('code',41001,'message','这条内容已经不在了');
    END IF;
    IF r.status = 'hidden' THEN
        RETURN jsonb_build_object('code',41001,'message','这条内容正在处理中');
    END IF;
    IF r.visibility = 'private' AND r.author_id <> v_uid THEN
        RETURN jsonb_build_object('code',40401,'message','这条内容不在了');
    END IF;
    IF r.author_id = v_uid THEN
        RETURN jsonb_build_object('code',41001,'message','自己的路标不需要打点');
    END IF;
    IF r.source_type = 'qa' THEN
        RETURN jsonb_build_object('code',41001,'message','示例内容不支持打点');
    END IF;

    -- 再点一次 = 取消：删掉打点记录，计数退回
    DELETE FROM story_resonate WHERE story_id = p_story_id AND device_id = v_dev
    RETURNING true INTO v_del;

    IF v_del THEN
        UPDATE story SET resonate_count = GREATEST(resonate_count - 1, 0)
         WHERE story_id = p_story_id
        RETURNING resonate_count INTO v_count;
        RETURN jsonb_build_object('code',0,'message','',
            'data', jsonb_build_object('resonate_count', v_count, 'resonated', false));
    END IF;

    INSERT INTO story_resonate (story_id, device_id)
    VALUES (p_story_id, v_dev)
    ON CONFLICT DO NOTHING;

    UPDATE story SET resonate_count = resonate_count + 1
     WHERE story_id = p_story_id
    RETURNING resonate_count INTO v_count;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('resonate_count', v_count, 'resonated', true));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;
