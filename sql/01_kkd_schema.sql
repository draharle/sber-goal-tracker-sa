-- 01_kkd_schema.sql
-- Таблицы модуля ККД: справочники, прогоны, найденные проблемы, сохранённые метрики.
-- Откат — 99_kkd_rollback.sql. На таблицы модуля «Цели» внешних ключей нет намеренно:
-- результаты прогона — исторический снимок и не должны мешать удалять цели и КР.

CREATE TABLE kkd_rule (
    code            varchar(64)  PRIMARY KEY,
    title           varchar(255) NOT NULL,
    description     text         NOT NULL,
    object_type     varchar(16)  NOT NULL CHECK (object_type IN ('goal', 'key_result')),
    severity        varchar(16)  NOT NULL CHECK (severity IN ('critical', 'major', 'minor')),
    is_cascade      boolean      NOT NULL DEFAULT false,   -- правило на каскад (идёт в cascade_coverage)
    params          jsonb        NOT NULL DEFAULT '{}'::jsonb,
    recommendation  text         NOT NULL,
    is_enabled      boolean      NOT NULL DEFAULT true
);

CREATE TABLE kkd_metric_def (
    key               varchar(64)  PRIMARY KEY,
    title             varchar(255) NOT NULL,
    unit              varchar(16)  NOT NULL,
    higher_is_better  boolean      NOT NULL,
    formula           text         NOT NULL,
    sort_order        smallint     NOT NULL UNIQUE
);

CREATE TABLE kkd_run (
    id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status              varchar(16)   NOT NULL DEFAULT 'running'
                                      CHECK (status IN ('running', 'completed', 'failed')),
    trigger_type        varchar(16)   NOT NULL CHECK (trigger_type IN ('schedule', 'manual')),
    snapshot_date       date          NOT NULL,             -- «сегодня» для правил (дата по МСК)
    started_at          timestamptz   NOT NULL DEFAULT now(),
    finished_at         timestamptz,
    compared_to_run_id  bigint        REFERENCES kkd_run (id),   -- предыдущий УСПЕШНЫЙ прогон
    rule_codes          varchar(64)[] NOT NULL,             -- какие правила применялись
    error_message       text,
    CHECK ((status = 'running') = (finished_at IS NULL)),
    CHECK ((status = 'failed') = (error_message IS NOT NULL)),
    CHECK (compared_to_run_id < id)
);
-- одновременно выполняется не больше одного прогона
CREATE UNIQUE INDEX kkd_run_one_running_uq ON kkd_run ((true)) WHERE status = 'running';

CREATE TABLE kkd_issue (
    run_id                 bigint        NOT NULL REFERENCES kkd_run (id) ON DELETE CASCADE,
    fingerprint            varchar(128)  NOT NULL,          -- RULE_CODE:object_id
    issue_id               varchar(16)   NOT NULL,          -- ISS-XXXXXXXXXX, стабилен между прогонами
    rule_code              varchar(64)   NOT NULL REFERENCES kkd_rule (code),
    severity               varchar(16)   NOT NULL CHECK (severity IN ('critical', 'major', 'minor')),
    object_type            varchar(16)   NOT NULL CHECK (object_type IN ('goal', 'key_result')),
    object_id              varchar(32)   NOT NULL,
    goal_id                varchar(32)   NOT NULL,
    goal_title             varchar(500)  NOT NULL,
    goal_level             varchar(16)   NOT NULL,
    kr_id                  varchar(32),
    kr_title               varchar(500),
    unit_id                varchar(32)   NOT NULL,          -- подразделение цели на дату снимка
    owner_id               varchar(32),
    details                varchar(500)  NOT NULL,
    actual_value           jsonb,                           -- факт: число или строка
    expected_value         jsonb,                           -- ожидание: число или строка
    delta_status           varchar(16)   NOT NULL CHECK (delta_status IN ('new', 'persisting')),
    first_detected_run_id  bigint        NOT NULL REFERENCES kkd_run (id),
    runs_in_row            integer       NOT NULL CHECK (runs_in_row >= 1),
    PRIMARY KEY (run_id, fingerprint),
    UNIQUE (run_id, issue_id),
    CHECK (fingerprint = rule_code || ':' || object_id),
    CHECK ((object_type = 'key_result') = (kr_id IS NOT NULL))
);
CREATE INDEX kkd_issue_run_unit_idx ON kkd_issue (run_id, unit_id);
CREATE INDEX kkd_issue_run_goal_idx ON kkd_issue (run_id, goal_id);

CREATE TABLE kkd_run_metric (
    run_id       bigint       NOT NULL REFERENCES kkd_run (id) ON DELETE CASCADE,
    unit_id      varchar(32)  NOT NULL,
    metric_key   varchar(64)  NOT NULL REFERENCES kkd_metric_def (key),
    value        numeric,          -- % — 1 знак после запятой, шт. — целое; NULL — нет целей
    numerator    integer      NOT NULL,
    denominator  integer,
    PRIMARY KEY (run_id, unit_id, metric_key)
);

-- Справочники: ядро из 4 правил и 3 метрик
INSERT INTO kkd_rule (code, title, description, object_type, severity, is_cascade, params, recommendation) VALUES
('GOAL_NO_KR', 'Цель без ключевых результатов',
 'У активной цели нет ни одного ключевого результата.',
 'goal', 'critical', false, '{}', 'Добавить 1–5 измеримых ключевых результатов.'),
('KR_WEIGHTS_SUM', 'Сумма весов КР не равна 100%',
 'Сумма весов ключевых результатов активной цели отличается от 100%.',
 'goal', 'major', false, '{}', 'Перераспределить веса КР так, чтобы сумма была 100%.'),
('CASCADE_NO_PARENT', 'Цель не связана с вышестоящей',
 'Активная цель уровня департамента, подразделения или сотрудника не привязана к родительской цели.',
 'goal', 'major', true, '{}', 'Указать родительскую цель вышестоящего уровня.'),
('KR_STALE_PROGRESS', 'Прогресс КР давно не обновлялся',
 'Фактическое значение КР активной цели не обновлялось более 45 дней.',
 'key_result', 'minor', false, '{"stale_days": 45}', 'Обновить фактическое значение КР.');

INSERT INTO kkd_metric_def (key, title, unit, higher_is_better, formula, sort_order) VALUES
('clean_goals_share', 'Доля корректных целей', '%', true,
 'активные цели без проблем ÷ все активные цели × 100', 1),
('cascade_coverage', 'Покрытие каскадом', '%', true,
 'активные цели (кроме уровня блока) без проблем каскада ÷ все такие цели × 100', 2),
('issues_total', 'Найдено проблем', 'шт.', false,
 'количество нарушений правил ККД', 3);
