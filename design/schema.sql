-- ============================================================
-- 人生的路你走到哪了 · V1 数据模型 DDL
-- 对应 PRD V1.3（修订 2）第 8 章 · 详细设计 V1.1-a
-- 方言：PostgreSQL 14+（服务端托管，无 MySQL 分支）
-- V1 建 6 张表：app_user / story / thanks / story_tag / app_config / rate_limit
-- report 与 admin_log 属 V1.1，本次不建
--
-- 平台约束（2026-10-26 判定，见详细设计 2.4）：
--   1. 服务端逻辑只能落在 PostgreSQL 函数里（无 Node / Edge Function）。
--   2. 无法下发 HttpOnly Cookie，会话凭证改由函数签发、前端自存。
--   3. 无匿名登录，anon 角色无法区分设备 —— 因此业务写操作全部收进
--      SECURITY DEFINER 函数，表本身不对前端开放任何权限（见文末「权限收口」）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 身份
-- ------------------------------------------------------------
CREATE TABLE app_user (
    user_id          BIGSERIAL    PRIMARY KEY,
    device_id        VARCHAR(40)  NOT NULL,
    session_token    CHAR(64)     NOT NULL,   -- 会话凭证：函数签发的 64 位随机十六进制串
    nickname         VARCHAR(40)  NOT NULL,
    recovery_code    CHAR(12)     NOT NULL,
    nickname_changed SMALLINT     NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    last_seen_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uk_user_device   UNIQUE (device_id),
    CONSTRAINT uk_user_token    UNIQUE (session_token),
    CONSTRAINT uk_user_nickname UNIQUE (nickname),
    CONSTRAINT uk_user_code     UNIQUE (recovery_code),
    CONSTRAINT ck_user_code_len CHECK (char_length(recovery_code) = 12),
    CONSTRAINT ck_user_code_set CHECK (recovery_code ~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{12}$'),
    CONSTRAINT ck_user_nick_len CHECK (char_length(nickname) BETWEEN 2 AND 12),
    CONSTRAINT ck_user_changed  CHECK (nickname_changed IN (0, 1)),
    CONSTRAINT ck_user_token_len CHECK (session_token ~ '^[0-9a-f]{64}$')
);

-- 说明 1：device_id 与 recovery_code 均随「认领迁移」变化，update 时只改这一行，
--   不改 story 的任何字段（判权依据是 author_id，见 PRD 7.10 / RB-27）。
--
-- 说明 2：session_token 是本版新增，替代原设计的 HttpOnly Cookie。
--   平台下发不了 Set-Cookie，凭证只能由函数签发、前端存 localStorage。
--   取舍：XSS 可窃取该 token（Cookie 的 HttpOnly 能挡这一层），
--   作为交换换来了「点开就能用」的零摩擦。已知弱点，不粉饰，见详细设计 5.1。
--   迁移（认领）时会换发新 token，旧 token 立即失效 —— 顺便成了一个「踢下线」手段。
--
-- 说明 3：recovery_code 在此版仍为 NOT NULL，建号时即生成。
--   PRD 允许「首次发布后才生成」，但空值会让 NOT NULL 约束失效、
--   并产生「有账号无恢复码」的中间态，V1 不采用该分支。

-- ------------------------------------------------------------
-- 2. 内容
-- ------------------------------------------------------------
CREATE TABLE story (
    story_id              BIGSERIAL    PRIMARY KEY,
    author_id             BIGINT       NOT NULL REFERENCES app_user(user_id),
    author_nickname       VARCHAR(40)  NOT NULL,               -- 发布时快照，改名不回溯（RB-30）
    title                 VARCHAR(80)  NOT NULL,
    body_before           TEXT         NOT NULL,
    body_after            TEXT,
    status                VARCHAR(16)  NOT NULL DEFAULT 'open',
    status_before_hidden  VARCHAR(16),
    visibility            VARCHAR(8)   NOT NULL DEFAULT 'public',
    source_type           VARCHAR(8)   NOT NULL DEFAULT 'user',
    topic_code            VARCHAR(16)  NOT NULL,
    life_stage            VARCHAR(16)  NOT NULL,
    thanks_count          INTEGER      NOT NULL DEFAULT 0,
    needs_review          SMALLINT     NOT NULL DEFAULT 0,
    hidden_reason         VARCHAR(32),
    request_id            CHAR(36),                          -- 发布幂等键，见详细设计 4.2 ③
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    resolved_at           TIMESTAMPTZ,
    deleted_at            TIMESTAMPTZ,

    CONSTRAINT uk_story_request  UNIQUE (request_id),        -- NULL 可重复，不影响未带幂等键的写入

    CONSTRAINT ck_story_status   CHECK (status IN ('open','resolved','hidden','deleted')),
    CONSTRAINT ck_story_vis      CHECK (visibility IN ('public','private')),
    CONSTRAINT ck_story_source   CHECK (source_type IN ('user','qa')),
    CONSTRAINT ck_story_topic    CHECK (topic_code IN ('study','job','growth','relation','daily','family','money','body')),
    CONSTRAINT ck_story_stage    CHECK (life_stage IN ('before_18','college','graduation','early_work','transition')),
    CONSTRAINT ck_story_title_len CHECK (char_length(title) BETWEEN 4 AND 40),
    CONSTRAINT ck_story_b1_len   CHECK (char_length(body_before) BETWEEN 50 AND 2000),
    CONSTRAINT ck_story_b2_len   CHECK (body_after IS NULL OR char_length(body_after) BETWEEN 50 AND 2000),
    CONSTRAINT ck_story_thanks   CHECK (thanks_count >= 0),
    CONSTRAINT ck_story_review   CHECK (needs_review IN (0, 1)),

    -- DC-01 / DC-02：只在 open 与 resolved 下约束二段的有无
    -- （hidden / deleted 保留原状态的数据，不做要求）
    CONSTRAINT ck_story_after_by_status CHECK (
        status NOT IN ('open','resolved')
        OR (status = 'resolved' AND body_after IS NOT NULL)
        OR (status = 'open'     AND body_after IS NULL)
    ),

    -- DC-03：resolved_at 非空当且仅当 status = resolved
    CONSTRAINT ck_story_resolved_at CHECK (
        (status = 'resolved' AND resolved_at IS NOT NULL)
        OR (status <> 'resolved')
    ),

    -- DC-14：hidden 时必须记住隐藏前的状态，且不能是 hidden
    CONSTRAINT ck_story_before_hidden CHECK (
        status <> 'hidden'
        OR (status_before_hidden IS NOT NULL AND status_before_hidden <> 'hidden')
    ),

    -- DC-15：时间先后
    CONSTRAINT ck_story_time_order CHECK (
        updated_at >= created_at
        AND (resolved_at IS NULL OR resolved_at >= created_at)
    )
);

-- 公开列表：按主题 + 状态筛，按 created_at 倒序
CREATE INDEX idx_story_public ON story (topic_code, status, created_at DESC)
    WHERE status IN ('open','resolved') AND deleted_at IS NULL;
-- MySQL 无部分索引，改普通索引：CREATE INDEX idx_story_public ON story (topic_code, status, created_at);

-- 我 的经历：按 author_id 取，按 updated_at 倒序
CREATE INDEX idx_story_author ON story (author_id, updated_at DESC);

-- 首页「最近的路」：先 resolved 按 resolved_at，再 open 按 created_at
CREATE INDEX idx_story_resolved ON story (resolved_at DESC)
    WHERE status = 'resolved' AND deleted_at IS NULL;

-- 示例内容单独标记，便于统计时排除（DC-17）
CREATE INDEX idx_story_source ON story (source_type);

-- 关键词检索：24 至 100 条数据量用 ILIKE 足够；
-- 超过 500 条再考虑 pg_trgm：
--   CREATE EXTENSION pg_trgm;
--   CREATE INDEX idx_story_trgm ON story USING gin ((title || ' ' || body_before) gin_trgm_ops);

-- ------------------------------------------------------------
-- 3. 致谢
-- ------------------------------------------------------------
CREATE TABLE thanks (
    story_id   BIGINT      NOT NULL REFERENCES story(story_id),
    device_id  VARCHAR(40) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (story_id, device_id)        -- DC-12：同一设备同一条只一条
);

CREATE INDEX idx_thanks_story ON thanks (story_id);

-- 已知限制：迁移设备后，新设备可对曾致谢过的内容再致谢一次（PRD 8.4）。
-- V1 接受该偏差，不引入账号体系修正。

-- ------------------------------------------------------------
-- 4. 标签
-- ------------------------------------------------------------
CREATE TABLE story_tag (
    story_id BIGINT      NOT NULL REFERENCES story(story_id) ON DELETE CASCADE,
    tag_code VARCHAR(16) NOT NULL,
    PRIMARY KEY (story_id, tag_code),
    CONSTRAINT ck_tag_code CHECK (tag_code IN ('exam','jobhunt','intern','major','social','mood','family','time'))
);

-- DC-11「每条最多 3 个」为应用层校验（PG 可用触发器实现，V1 用应用层，理由：错误提示要可读）

-- ------------------------------------------------------------
-- 5. 配置（替代原设计的「环境变量」）
-- ------------------------------------------------------------
-- 平台不提供自定义环境变量注入，配置改存表。
-- 好处：改口令、开关主题不需要重新部署（NF-15 / RS-2）。
-- 代价：口令哈希落在库里，能读库就能读它 —— 所以存哈希不存明文。
CREATE TABLE app_config (
    key        VARCHAR(32)  PRIMARY KEY,
    value      TEXT         NOT NULL,
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_config_key CHECK (key IN (
        'gate_pass_hash',      -- 前台口令的 bcrypt/argon2 哈希（pgcrypto: crypt）
        'topic_open',          -- 开放主题，逗号分隔，如 study,job,growth,relation,daily
        'gate_locked_until'    -- 口令连续失败后的锁定截止时间（ISO 8601）
    ))
);

-- ------------------------------------------------------------
-- 6. 限流计数器
-- ------------------------------------------------------------
-- PRD 7.7 的四条限流原先假设在 Node 层做，现在没有 Node，
-- 只能在库里计数。窗口固定为 10 分钟 / 24 小时两种，按 bucket 区分场景。
CREATE TABLE rate_limit (
    bucket       VARCHAR(32)  NOT NULL,       -- 见下方 CHECK，一个场景一个 bucket
    subject      VARCHAR(64)  NOT NULL,       -- IP 或 device_id
    window_start TIMESTAMPTZ  NOT NULL,
    hit_count    INTEGER      NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket, subject, window_start),
    CONSTRAINT ck_rl_bucket CHECK (bucket IN (
        'gate_fail',      -- 口令失败，IP 维度，10 分钟 10 次
        'claim_fail',     -- 认领失败，IP 维度，10 分钟 5 次
        'publish',        -- 发布，设备维度，10 分钟 3 条
        'new_identity'    -- 新建身份，IP 维度，24 小时 20 个
    )),
    CONSTRAINT ck_rl_count CHECK (hit_count >= 0)
);

CREATE INDEX idx_rl_window ON rate_limit (window_start);

-- 清理：读时顺带删过期行即可，不另设定时任务。
--   DELETE FROM rate_limit WHERE window_start < now() - interval '25 hours';

-- ============================================================
-- 权限收口（这一节比表结构更重要）
-- ============================================================
-- 平台没有匿名身份，anon 无法区分「谁是谁」。因此：
--   表 —— 不对 anon / authenticated 授予任何权限，前端读不到也写不进。
--   函数 —— 全部 SECURITY DEFINER，函数内校验 token 后再操作。
-- 这样「前端只调函数、不碰表」不是约定，是数据库强制的。
--
-- 执行顺序（必须在建函数之前）：
--   REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
--   REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
--   然后每个 api_* 函数：REVOKE EXECUTE ... FROM PUBLIC; GRANT EXECUTE ... TO anon;
--
-- 为什么授给 anon 而不是 authenticated：本产品没有账号体系，
-- 前端从来不调 cloud.auth 登录，所有请求都以 anon 角色进来。
-- 若只授 authenticated，所有调用都会 42501，且报错像 RLS 配错，极难排查。

-- ============================================================
-- 迁移 / 认领（已改为函数实现，此处保留为语义说明）
-- ============================================================
-- api_claim(p_token, p_new_device, p_recovery_code) 内部逻辑：
--   1. 行锁取出码对应的 user（FOR UPDATE），未命中即返回 40103 —— 不区分原因；
--   2. 新设备若已存在空白身份，先删掉（否则 device_id 唯一索引冲突）；
--   3. UPDATE app_user SET device_id = 新设备,
--                            session_token = 新 token,
--                            recovery_code = 新码,
--                            last_seen_at = now()
--      WHERE user_id = 该用户;
--   4. story 表一行都不动（判权靠 author_id）。
-- 函数体本身即一个事务：任一步失败整体回滚，不需要前端补偿。

-- ============================================================
-- 种子数据说明
-- ============================================================
-- 1. 主题（7 个）与人生阶段（5 个）、标签（8 个）均为枚举，V1 用应用层常量维护，
--    不建字典表。开放哪些主题由配置项控制（RS-1、RS-2），不在库表里。
-- 2. 示例内容 6 条：source_type = 'qa'，不参与主题条数统计（DC-17），
--    不接收致谢，卡片展示「示例」角标。
-- 3. 压测数据 500 条：同样用 source_type = 'qa' 注入，压测后清除。
--    注入与清除各写一个脚本，避免手工 DELETE 误伤真实内容：
--      DELETE FROM story WHERE source_type = 'qa' AND needs_review = 9;  -- 压测批专用标记
--    建议给压测批单独一个 needs_review 值或在 title 前缀加固定标记，便于识别。

-- 迁移与认领的原子操作见上文「迁移 / 认领（已改为函数实现）」一节，
-- 该逻辑不再由应用层拼事务，而是封在 api_claim 函数体内。
