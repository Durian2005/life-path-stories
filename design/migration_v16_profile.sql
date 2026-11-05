-- ============================================================
-- V1.6 · 收藏按钮 + 昵称 / 头像编辑
--
-- 背景：
--   「我的」里一直有「收藏」这个 tab，但详情页根本没有收藏入口——
--   功能是断的。这次补上入口，并把「改名字 / 换头像」做出来。
--
-- 头像为什么不给上传：
--   - 匿名产品不该鼓励传真人照片，头像做成 8 个预设线稿就够了
--   - 教室网络传图容易卡在演示现场，外链图挂了头像就是一块空白
--   库里只存一个代码（leaf / moon / …），前端用内联 SVG 画出来。
-- ============================================================

-- ---------- 1. 用户表加头像 ----------
ALTER TABLE app_user ADD COLUMN avatar VARCHAR(16) NOT NULL DEFAULT 'leaf';

ALTER TABLE app_user ADD CONSTRAINT ck_user_avatar
  CHECK (avatar IN ('leaf','moon','star','hill','cloud','book','cat','cup'));

-- ---------- 2. 我的身份（导航栏头像用，比 api_me 轻） ----------
CREATE OR REPLACE FUNCTION public.api_my_identity(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_nick   varchar(40);
    v_avatar varchar(16);
BEGIN
    SELECT nickname, avatar INTO v_nick, v_avatar
      FROM app_user WHERE session_token = p_token;
    IF v_nick IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('nickname', v_nick, 'avatar', v_avatar));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- ---------- 3. 改昵称 / 换头像 ----------
-- 两个要点：
--   a) 昵称唯一，但不再限制「只能改一次」——产品定位是匿名写内容，
--      名字本来就只是个称呼，限制次数只会让人顶着临时名到路演结束
--   b) story.author_nickname 是写入时的冗余，改名必须一并对齐，
--      否则历史帖子还署着旧名
CREATE OR REPLACE FUNCTION public.api_update_profile(p_token text, p_nickname text, p_avatar text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
    v_uid  bigint;
    v_nick text;
    v_ava  text;
    v_old  varchar(40);
    v_used int;
BEGIN
    SELECT user_id, nickname INTO v_uid, v_old
      FROM app_user WHERE session_token = p_token;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('code',40101,'message','身份已失效，请重新打开页面');
    END IF;

    v_nick := btrim(coalesce(p_nickname, v_old));
    IF char_length(v_nick) < 2 OR char_length(v_nick) > 12 THEN
        RETURN jsonb_build_object('code',40001,'message','名字要 2 到 12 个字');
    END IF;
    IF v_nick ~ '^[[:space:][:punct:]]+$' THEN
        RETURN jsonb_build_object('code',40001,'message','名字不能全是标点');
    END IF;

    IF p_avatar IS NOT NULL THEN
        v_ava := btrim(p_avatar);
        IF v_ava NOT IN ('leaf','moon','star','hill','cloud','book','cat','cup') THEN
            RETURN jsonb_build_object('code',40001,'message','不认识的头像');
        END IF;
    ELSE
        v_ava := (SELECT avatar FROM app_user WHERE user_id = v_uid);
    END IF;

    IF v_nick <> v_old THEN
        SELECT count(*) INTO v_used FROM app_user
         WHERE nickname = v_nick AND user_id <> v_uid;
        IF v_used > 0 THEN
            RETURN jsonb_build_object('code',40001,'message','这个昵称有人用了，换一个');
        END IF;
    END IF;

    UPDATE app_user SET nickname = v_nick, avatar = v_ava WHERE user_id = v_uid;

    IF v_nick <> v_old THEN
        UPDATE story SET author_nickname = v_nick WHERE author_id = v_uid;
    END IF;

    RETURN jsonb_build_object('code',0,'message','',
        'data', jsonb_build_object('nickname', v_nick, 'avatar', v_ava,
                                   'renamed', (v_nick <> v_old)));
EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('code',40001,'message','这个昵称有人用了，换一个');
WHEN OTHERS THEN
    RETURN jsonb_build_object('code',50001,'message','服务出了点问题，稍后再试');
END;
$fn$;

-- ---------- 4. api_me 带上头像 ----------
-- 完整定义见线上函数（与 V1.3 一致，只多一个 avatar 字段），这里只记差异：
--   DECLARE 段加 v_ava varchar(16)
--   SELECT user_id, device_id, nickname, avatar, created_at INTO v_uid, v_dev, v_nick, v_ava, v_join
--   jsonb_build_object('nickname', v_nick, 'avatar', v_ava, ...)

-- ---------- 5. 权限 ----------
GRANT EXECUTE ON FUNCTION
    public.api_my_identity(text),
    public.api_update_profile(text, text, text),
    public.api_me(text)
TO anon;

-- ---------- 6. 详情页三个按钮 ----------
-- 前端的活，不涉及 SQL，记在这里方便对照：
--   足迹（共鸣，带计数）/ 点赞（带计数）/ 收藏（不带计数，只有一个小圆点）
--   三个都是 toggle：再点一下取消。取消点赞收藏的接口一直是 toggle，
--   这次只是把「收藏」的入口补上，并让点赞在已赞状态下也能继续点。
