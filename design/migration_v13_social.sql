-- ============================================================
-- V1.3 增量迁移：点赞 / 收藏 / 浏览记录 / 点赞通知 / 个人空间
-- 2026-11-05
--
-- 原则沿用 V1.1：只新增，不动现有 17 个 api_* 函数的语义
--（例外仅限 story 表加 like_count 列，属增量列，旧函数不受影响）。
--
-- 身份口径：与 thanks / story_resonate 一致，用 device_id 而不是 user_id。
-- 理由：设备迁移（认领）后 device_id 会换，旧打点跟着"人"走不了；
-- 但 V1 本来就是「内容绑浏览器」的产品假设，全站同一套偏差，不在这里单独修正。
--
-- 需求变更记录（2026-11-05 18:56）：
--   初版还建了 story_comment（评论）与 api_story_comment / api_comment_list。
--   产品侧改为「详情页右下角固定两个按钮：脚印 + 点赞」，评论不在范围内，
--   故已 DROP 掉这两条函数与一张表，本文件只保留最终生效的结构。
--   notification.kind 相应收紧为只允许 'like'。
--
-- 执行方式：genie-baas db_exec_sql（mode=migrate），单语句逐条执行。
-- ============================================================

-- ------------------------------------------------------------
-- 1) 点赞
-- ------------------------------------------------------------
CREATE TABLE story_like (
    story_id   BIGINT      NOT NULL REFERENCES story(story_id),
    device_id  VARCHAR(40) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (story_id, device_id)
);

CREATE INDEX idx_like_device ON story_like (device_id, created_at DESC);

-- ------------------------------------------------------------
-- 2) 收藏（自己看，不通知作者）
-- ------------------------------------------------------------
CREATE TABLE story_favorite (
    story_id   BIGINT      NOT NULL REFERENCES story(story_id),
    device_id  VARCHAR(40) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (story_id, device_id)
);

CREATE INDEX idx_fav_device ON story_favorite (device_id, created_at DESC);

-- ------------------------------------------------------------
-- 3) 浏览记录（同一设备同一条只留一行，重复看只刷时间）
-- ------------------------------------------------------------
CREATE TABLE story_view (
    story_id   BIGINT      NOT NULL REFERENCES story(story_id),
    device_id  VARCHAR(40) NOT NULL,
    viewed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (story_id, device_id)
);

CREATE INDEX idx_view_device ON story_view (device_id, viewed_at DESC);

-- ------------------------------------------------------------
-- 4) 通知（只给"我的内容被别人点赞"用，收藏与浏览是私密的、不通知）
-- ------------------------------------------------------------
-- user_id 是接收者（内容作者），不是操作者。
-- actor_nickname 存昵称快照：产品明确不展示点赞者账号，它只用于
-- 服务端一小时去重，前端拿到也不渲染，更不提供任何反查入口。
CREATE TABLE notification (
    notify_id      BIGSERIAL    PRIMARY KEY,
    user_id        BIGINT       NOT NULL REFERENCES app_user(user_id),
    story_id       BIGINT       NOT NULL REFERENCES story(story_id),
    kind           VARCHAR(16)  NOT NULL,
    actor_nickname VARCHAR(40)  NOT NULL,
    preview        TEXT,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    read_at        TIMESTAMPTZ,
    CONSTRAINT ck_notify_kind CHECK (kind IN ('like')),
    CONSTRAINT ck_notify_prev CHECK (preview IS NULL OR char_length(preview) <= 120)
);

CREATE INDEX idx_notify_user ON notification (user_id, created_at DESC);
-- 未读查询只扫未读行：红点要频繁查，走部分索引
CREATE INDEX idx_notify_unread ON notification (user_id) WHERE read_at IS NULL;

-- ------------------------------------------------------------
-- 5) story 加点赞计数列（与 thanks_count / resonate_count 平级）
-- ------------------------------------------------------------
ALTER TABLE story ADD COLUMN like_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE story ADD CONSTRAINT ck_story_like CHECK (like_count >= 0);

-- ------------------------------------------------------------
-- 6) 权限收口：4 张新表对前端零授权
-- ------------------------------------------------------------
REVOKE ALL ON story_like, story_favorite, story_view, notification
    FROM anon, authenticated;
REVOKE ALL ON SEQUENCE notification_notify_id_seq FROM anon, authenticated;

-- ============================================================
-- 函数（逐条执行）
-- ============================================================

-- 7) 点赞 / 取消点赞（toggle）
--    返回 data: { liked, like_count }
--    给自己点赞允许，但不产生通知（避免红点靠自己点出来）。
--    同一人一小时内重复点赞只留一条通知，取消再点不该刷满铃铛。
CREATE OR REPLACE FUNCTION public.api_story_like(p_token text, p_story_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid   bigint;
    v_dev   varchar(40);
    v_nick  varchar(40);
    r       record;
    v_del   boolean;
    v_count int;
BEGIN
    SELECT user_id, device_id, nickname INTO v_uid, v_dev, v_nick
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT author_id, status, deleted_at, source_type, visibility, like_count
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
    IF r.source_type = 'qa' THEN
        RETURN jsonb_build_object('code',41001,'message','示例内容不支持点赞');
    END IF;

    DELETE FROM story_like WHERE story_id = p_story_id AND device_id = v_dev
    RETURNING true INTO v_del;

    IF v_del THEN
        UPDATE story SET like_count = GREATEST(like_count - 1, 0)
         WHERE story_id = p_story_id
        RETURNING like_count INTO v_count;
        RETURN jsonb_build_object('code',0,'message','',
            'data', jsonb_build_object('liked', false, 'like_count', v_count));
    END IF;

    INSERT INTO story_like (story_id, device_id) VALUES (p_story_id, v_dev)
    ON CONFLICT DO NOTHING;

    UPDATE story SET like_count = like_count + 1
     WHERE story_id = p_story_id
    RETURNING like_count INTO v_count;

    IF r.author_id <> v_uid THEN
        INSERT INTO notification (user_id, story_id, kind, actor_nickname)
        SELECT r.author_id, p_story_id, 'like', v_nick
         WHERE NOT EXISTS (
            SELECT 1 FROM notification n
             WHERE n.user_id = r.author_id AND n.story_id = p_story_id
               AND n.kind = 'like' AND n.actor_nickname = v_nick
               AND n.created_at > now() - interval '1 hour');
    END IF;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('liked', true, 'like_count', v_count));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 8) 收藏 / 取消收藏（toggle）
--    返回 data: { favorited }
CREATE OR REPLACE FUNCTION public.api_story_favorite(p_token text, p_story_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid bigint;
    v_dev varchar(40);
    r     record;
    v_del boolean;
BEGIN
    SELECT user_id, device_id INTO v_uid, v_dev
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT author_id, status, deleted_at, source_type, visibility
      INTO r FROM story WHERE story_id = p_story_id;
    IF r IS NULL OR r.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('code',41001,'message','这条内容已经不在了');
    END IF;
    IF r.status = 'hidden' THEN
        RETURN jsonb_build_object('code',41001,'message','这条内容正在处理中');
    END IF;
    IF r.visibility = 'private' AND r.author_id <> v_uid THEN
        RETURN jsonb_build_object('code',40401,'message','这条内容不在了');
    END IF;

    DELETE FROM story_favorite WHERE story_id = p_story_id AND device_id = v_dev
    RETURNING true INTO v_del;

    IF v_del THEN
        RETURN jsonb_build_object('code',0,'message','',
            'data', jsonb_build_object('favorited', false));
    END IF;

    INSERT INTO story_favorite (story_id, device_id) VALUES (p_story_id, v_dev)
    ON CONFLICT DO NOTHING;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('favorited', true));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 9) 浏览记录：只记「看过」，不记次数
--    返回 data: { ok: true }
CREATE OR REPLACE FUNCTION public.api_story_view(p_token text, p_story_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid bigint;
    v_dev varchar(40);
    r     record;
BEGIN
    SELECT user_id, device_id INTO v_uid, v_dev
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT status, deleted_at, visibility, author_id, source_type
      INTO r FROM story WHERE story_id = p_story_id;
    IF r IS NULL OR r.deleted_at IS NOT NULL OR r.status = 'hidden' THEN
        RETURN jsonb_build_object('code',41001,'message','这条内容已经不在了');
    END IF;
    -- 示例内容不进浏览记录：看了也没意义，还挤掉真实内容
    IF r.source_type = 'qa' THEN
        RETURN jsonb_build_object('code',0,'message','','data', jsonb_build_object('ok', false));
    END IF;
    IF r.visibility = 'private' AND r.author_id <> v_uid THEN
        RETURN jsonb_build_object('code',40401,'message','这条内容不在了');
    END IF;

    INSERT INTO story_view (story_id, device_id) VALUES (p_story_id, v_dev)
    ON CONFLICT (story_id, device_id) DO UPDATE SET viewed_at = now();

    RETURN jsonb_build_object('code',0,'message','','data', jsonb_build_object('ok', true));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 10) 批量查互动状态：列表页一次拿一页卡片的点赞 / 收藏状态
--     p_story_ids: jsonb 数组，如 [55,56,57]，最多取前 100 个
--     返回 data: { items: [{ story_id, like_count, liked, favorited }] }
CREATE OR REPLACE FUNCTION public.api_interaction_state(p_token text, p_story_ids jsonb)
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

    SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) INTO v_items
      FROM (
        SELECT s.story_id,
               s.like_count,
               EXISTS (SELECT 1 FROM story_like l
                        WHERE l.story_id = s.story_id AND l.device_id = v_dev) AS liked,
               EXISTS (SELECT 1 FROM story_favorite f
                        WHERE f.story_id = s.story_id AND f.device_id = v_dev) AS favorited
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

-- 11) 我的收藏夹 / 赞过 / 浏览记录
--     p_kind: 'like' | 'favorite' | 'view'
--     返回 data: { items, total, page, size, has_more }
CREATE OR REPLACE FUNCTION public.api_my_marks(p_token text, p_kind text,
                                               p_page integer DEFAULT 1, p_size integer DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid   bigint;
    v_dev   varchar(40);
    v_items jsonb;
    v_total bigint;
    v_page  int;
    v_size  int;
BEGIN
    SELECT user_id, device_id INTO v_uid, v_dev
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    v_size := least(greatest(coalesce(p_size,10),1),20);
    v_page := greatest(coalesce(p_page,1),1);

    IF p_kind = 'like' THEN
        SELECT coalesce(jsonb_agg(item ORDER BY oa DESC, oi DESC),'[]'::jsonb), coalesce(max(total),0)
          INTO v_items, v_total
          FROM (
            SELECT jsonb_build_object(
                     'id', s.story_id, 'title', s.title,
                     'summary', left(s.body_before,80) || CASE WHEN char_length(s.body_before) > 80 THEN '…' ELSE '' END,
                     'status', s.status, 'topic_code', s.topic_code,
                     'author_nickname', s.author_nickname,
                     'created_at', to_char(s.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                     'marked_at', to_char(m.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                     'like_count', s.like_count,
                     'is_sample', (s.source_type = 'qa')
                   ) AS item,
                   m.created_at AS oa, s.story_id AS oi,
                   count(*) OVER () AS total
              FROM story_like m JOIN story s ON s.story_id = m.story_id
             WHERE m.device_id = v_dev
               AND s.deleted_at IS NULL AND s.status IN ('open','resolved')
               AND (s.visibility = 'public' OR s.author_id = v_uid)
             ORDER BY m.created_at DESC
             LIMIT v_size OFFSET (v_page-1)*v_size
          ) x;
    ELSIF p_kind = 'favorite' THEN
        SELECT coalesce(jsonb_agg(item ORDER BY oa DESC, oi DESC),'[]'::jsonb), coalesce(max(total),0)
          INTO v_items, v_total
          FROM (
            SELECT jsonb_build_object(
                     'id', s.story_id, 'title', s.title,
                     'summary', left(s.body_before,80) || CASE WHEN char_length(s.body_before) > 80 THEN '…' ELSE '' END,
                     'status', s.status, 'topic_code', s.topic_code,
                     'author_nickname', s.author_nickname,
                     'created_at', to_char(s.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                     'marked_at', to_char(m.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                     'like_count', s.like_count,
                     'is_sample', (s.source_type = 'qa')
                   ) AS item,
                   m.created_at AS oa, s.story_id AS oi,
                   count(*) OVER () AS total
              FROM story_favorite m JOIN story s ON s.story_id = m.story_id
             WHERE m.device_id = v_dev
               AND s.deleted_at IS NULL AND s.status IN ('open','resolved')
               AND (s.visibility = 'public' OR s.author_id = v_uid)
             ORDER BY m.created_at DESC
             LIMIT v_size OFFSET (v_page-1)*v_size
          ) x;
    ELSIF p_kind = 'view' THEN
        SELECT coalesce(jsonb_agg(item ORDER BY oa DESC, oi DESC),'[]'::jsonb), coalesce(max(total),0)
          INTO v_items, v_total
          FROM (
            SELECT jsonb_build_object(
                     'id', s.story_id, 'title', s.title,
                     'summary', left(s.body_before,80) || CASE WHEN char_length(s.body_before) > 80 THEN '…' ELSE '' END,
                     'status', s.status, 'topic_code', s.topic_code,
                     'author_nickname', s.author_nickname,
                     'created_at', to_char(s.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                     'marked_at', to_char(m.viewed_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                     'like_count', s.like_count,
                     'is_sample', (s.source_type = 'qa')
                   ) AS item,
                   m.viewed_at AS oa, s.story_id AS oi,
                   count(*) OVER () AS total
              FROM story_view m JOIN story s ON s.story_id = m.story_id
             WHERE m.device_id = v_dev
               AND s.deleted_at IS NULL AND s.status IN ('open','resolved')
               AND (s.visibility = 'public' OR s.author_id = v_uid)
             ORDER BY m.viewed_at DESC
             LIMIT v_size OFFSET (v_page-1)*v_size
          ) x;
    ELSE
        RETURN jsonb_build_object('code',40001,'message','不认识的列表类型');
    END IF;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('items', v_items, 'total', v_total,
                                   'page', v_page, 'size', v_size,
                                   'has_more', (v_page * v_size < v_total)));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 12) 通知列表 + 未读数（首页铃铛只调这一个）
--     返回 data: { unread, items: [{ id, kind, story_id, story_title, actor, preview, created_at, read }] }
--     注意：actor 只落在返回体里，前端**不渲染**——匿名产品不展示点赞者身份。
CREATE OR REPLACE FUNCTION public.api_notifications(p_token text, p_limit integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid    bigint;
    v_unread int;
    v_items  jsonb;
BEGIN
    SELECT user_id INTO v_uid FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT count(*) INTO v_unread
      FROM notification WHERE user_id = v_uid AND read_at IS NULL;

    SELECT coalesce(jsonb_agg(item ORDER BY oa DESC, oi DESC),'[]'::jsonb) INTO v_items
      FROM (
        SELECT jsonb_build_object(
                 'id', n.notify_id,
                 'kind', n.kind,
                 'story_id', n.story_id,
                 'story_title', s.title,
                 'actor', n.actor_nickname,
                 'preview', n.preview,
                 'created_at', to_char(n.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                 'read', (n.read_at IS NOT NULL)
               ) AS item,
               n.created_at AS oa, n.notify_id AS oi
          FROM notification n JOIN story s ON s.story_id = n.story_id
         WHERE n.user_id = v_uid AND s.deleted_at IS NULL
         ORDER BY n.created_at DESC, n.notify_id DESC
         LIMIT least(greatest(coalesce(p_limit,20),1),50)
      ) x;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('unread', v_unread, 'items', v_items));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 13) 全部标为已读（打开铃铛面板时调用）
--     返回 data: { unread: 0 }
CREATE OR REPLACE FUNCTION public.api_notification_read(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid bigint;
BEGIN
    SELECT user_id INTO v_uid FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    UPDATE notification SET read_at = now()
     WHERE user_id = v_uid AND read_at IS NULL;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('unread', 0));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- 14) 个人空间头部资料
--     返回 data: { nickname, joined_at, stats: { posts, likes, resonates, thanks, favorites, marks } }
CREATE OR REPLACE FUNCTION public.api_me(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid  bigint;
    v_dev  varchar(40);
    v_nick varchar(40);
    v_join timestamptz;
    v_out  jsonb;
BEGIN
    SELECT user_id, device_id, nickname, created_at
      INTO v_uid, v_dev, v_nick, v_join
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    SELECT jsonb_build_object(
        'nickname', v_nick,
        'joined_at', to_char(v_join AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'stats', jsonb_build_object(
            'posts', (SELECT count(*) FROM story
                       WHERE author_id = v_uid AND deleted_at IS NULL),
            -- 收到的赞 / 共鸣 / 致谢只算公开内容上别人给的
            'likes', (SELECT coalesce(sum(s.like_count),0) FROM story s
                       WHERE s.author_id = v_uid AND s.deleted_at IS NULL
                         AND s.visibility = 'public'),
            'resonates', (SELECT coalesce(sum(s.resonate_count),0) FROM story s
                           WHERE s.author_id = v_uid AND s.deleted_at IS NULL
                             AND s.visibility = 'public'),
            'thanks', (SELECT coalesce(sum(s.thanks_count),0) FROM story s
                        WHERE s.author_id = v_uid AND s.deleted_at IS NULL
                          AND s.visibility = 'public'),
            'favorites', (SELECT count(*) FROM story_favorite WHERE device_id = v_dev),
            'marks', (SELECT count(*) FROM story_like WHERE device_id = v_dev)
        )
    ) INTO v_out;

    RETURN jsonb_build_object('code',0,'message','','data',v_out);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- ------------------------------------------------------------
-- 15) 执行权限：只授 anon（与现有 17 个函数一致）
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.api_story_like(text,bigint)               FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_story_like(text,bigint)            TO anon;
REVOKE ALL ON FUNCTION public.api_story_favorite(text,bigint)           FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_story_favorite(text,bigint)        TO anon;
REVOKE ALL ON FUNCTION public.api_story_view(text,bigint)               FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_story_view(text,bigint)            TO anon;
REVOKE ALL ON FUNCTION public.api_interaction_state(text,jsonb)         FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_interaction_state(text,jsonb)      TO anon;
REVOKE ALL ON FUNCTION public.api_my_marks(text,text,integer,integer)   FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_my_marks(text,text,integer,integer) TO anon;
REVOKE ALL ON FUNCTION public.api_notifications(text,integer)           FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_notifications(text,integer)        TO anon;
REVOKE ALL ON FUNCTION public.api_notification_read(text)               FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_notification_read(text)            TO anon;
REVOKE ALL ON FUNCTION public.api_me(text)                              FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_me(text)                           TO anon;
