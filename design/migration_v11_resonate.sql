-- ============================================================
-- V1.1 增量迁移：共鸣（「我也走过这段」）+ 首页统计
-- 2026-10-31 与 api_story_thanks 同构，SECURITY DEFINER + token 鉴权。
-- 原则：只新增，不修改现有 14 个 api_* 函数（DC-17 口径不动）。
-- 执行方式：genie-baas db_exec_sql（mode=migrate），单语句逐条执行。
-- ============================================================

-- 1) 共鸣表：与 thanks 同构，同设备同一条只一条
CREATE TABLE story_resonate (
    story_id   BIGINT      NOT NULL REFERENCES story(story_id),
    device_id  VARCHAR(40) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (story_id, device_id)
);

CREATE INDEX idx_resonate_story ON story_resonate (story_id);

-- 2) story 加计数列（与 thanks_count 平级）
ALTER TABLE story
    ADD COLUMN resonate_count INTEGER NOT NULL DEFAULT 0,
    ADD CONSTRAINT ck_story_resonate CHECK (resonate_count >= 0);

-- 3) 权限收口：表不对前端开放（函数是 SECURITY DEFINER，自己能读写）
REVOKE ALL ON story_resonate FROM anon, authenticated;

-- 4) 打点：api_story_resonate(p_token text, p_story_id bigint)
--    返回 data: { resonate_count, resonated }
CREATE OR REPLACE FUNCTION public.api_story_resonate(p_token text, p_story_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid  bigint;
    v_dev  varchar(40);
    r      record;
    v_ins  boolean;
    v_count int;
BEGIN
    SELECT user_id, device_id INTO v_uid, v_dev
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT author_id, status, deleted_at, source_type, visibility, resonate_count
      INTO r
      FROM story WHERE story_id = p_story_id FOR UPDATE;
    IF r IS NULL OR r.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('code',41001,'message','这条内容已经不在了');
    END IF;
    IF r.visibility = 'private' AND r.author_id <> v_uid THEN
        RETURN jsonb_build_object('code',40401,'message','这条内容不在了');
    END IF;
    IF r.status = 'hidden' THEN
        RETURN jsonb_build_object('code',41001,'message','这条内容正在处理中');
    END IF;
    IF r.author_id = v_uid THEN
        RETURN jsonb_build_object('code',41001,'message','自己的路标不需要打点');
    END IF;
    IF r.source_type = 'qa' THEN
        RETURN jsonb_build_object('code',41001,'message','示例内容不支持打点');
    END IF;

    INSERT INTO story_resonate (story_id, device_id)
    VALUES (p_story_id, v_dev)
    ON CONFLICT DO NOTHING
    RETURNING true INTO v_ins;

    IF v_ins THEN
        UPDATE story SET resonate_count = resonate_count + 1
         WHERE story_id = p_story_id
        RETURNING resonate_count INTO v_count;
    ELSE
        v_count := r.resonate_count;
    END IF;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('resonate_count', v_count, 'resonated', true));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 5) 批量查状态（列表页一次拿一页卡片的计数与「我是否点过」）
--    p_story_ids: jsonb 数组，如 [55,56,57]，最多取前 100 个
--    返回 data: { items: [{ story_id, resonate_count, resonated }] }
CREATE OR REPLACE FUNCTION public.api_resonate_state(p_token text, p_story_ids jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid   bigint;
    v_dev   varchar(40);
    v_ids   bigint[];
    v_items jsonb;
BEGIN
    SELECT user_id, device_id INTO v_uid, v_dev
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT array_agg(x) INTO v_ids
      FROM (SELECT (e::text)::bigint AS x
              FROM jsonb_array_elements_text(p_story_ids) e
             LIMIT 100) t;

    IF v_ids IS NULL THEN
        RETURN jsonb_build_object('code',0,'message','',
            'data', jsonb_build_object('items', '[]'::jsonb));
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_items
      FROM (
        SELECT s.story_id,
               s.resonate_count,
               EXISTS (SELECT 1 FROM story_resonate sr
                        WHERE sr.story_id = s.story_id
                          AND sr.device_id = v_dev) AS resonated
          FROM story s
         WHERE s.story_id = ANY(v_ids)
           AND s.deleted_at IS NULL
           AND s.status IN ('open','resolved')
      ) x;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('items', v_items));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 6) 首页统计：N 位旅人 / M 个路标 / K 段已走完
--    只数 source_type='user'（与 api_topics / api_story_list 的 total 口径一致，DC-17）
CREATE OR REPLACE FUNCTION public.api_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v jsonb;
BEGIN
    SELECT jsonb_build_object(
        'travelers', (SELECT COUNT(DISTINCT author_id) FROM story
                       WHERE source_type = 'user' AND deleted_at IS NULL
                         AND visibility = 'public' AND status IN ('open','resolved')),
        'stories',   (SELECT COUNT(*) FROM story
                       WHERE source_type = 'user' AND deleted_at IS NULL
                         AND visibility = 'public' AND status IN ('open','resolved')),
        'resolved',  (SELECT COUNT(*) FROM story
                       WHERE source_type = 'user' AND deleted_at IS NULL
                         AND visibility = 'public' AND status = 'resolved')
    ) INTO v;
    RETURN jsonb_build_object('code',0,'message','','data',v);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 7) 执行权限：只授 anon（本产品无账号体系，所有请求都以 anon 进来）
REVOKE ALL ON FUNCTION public.api_story_resonate(text,bigint)  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_story_resonate(text,bigint)  TO anon;
REVOKE ALL ON FUNCTION public.api_resonate_state(text,jsonb)   FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_resonate_state(text,jsonb)   TO anon;
REVOKE ALL ON FUNCTION public.api_stats()                      FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_stats()                      TO anon;

-- ============================================================
-- 附：app/assets/qr-share.png 的重建命令（该文件不入 git，部署前本地生成）
--   python -c "import qrcode;from qrcode.constants import ERROR_CORRECT_M as M;"
--   python - <<'PY'
--   import qrcode
--   from qrcode.constants import ERROR_CORRECT_M as M
--   qr = qrcode.QRCode(version=6, error_correction=M, box_size=8, border=3)
--   qr.add_data('https://renlu-22866.app.workbuddy.host/gate.html?sharecode=<sharecode>&k=<口令>')
--   qr.make(fit=False)
--   qr.make_image(fill_color='#101a2b', back_color='white').save('app/assets/qr-share.png')
--   PY
--   注意：必须深色模块 + 白底（反色二维码大量解码器不认）。
-- ============================================================
