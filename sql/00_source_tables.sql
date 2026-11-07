-- 00_source_tables.sql
-- Таблицы модуля «Цели» — СУЩЕСТВУЮЩИЕ данные, которые ККД только читает.
-- Здесь — минимальный набор полей, нужный ККД. Скрипт нужен для тестового стенда;
-- на реальной БД эти таблицы уже есть, ККД их не создаёт и не меняет.

CREATE TABLE org_unit (
    id         varchar(32)  PRIMARY KEY,                  -- код подразделения: B2B, HQ-CIB, CIB-KEY
    name       varchar(255) NOT NULL,
    level      varchar(16)  NOT NULL CHECK (level IN ('block', 'hq', 'unit')),
    parent_id  varchar(32)  REFERENCES org_unit (id),     -- NULL только у корня (блока)
    CHECK (parent_id <> id)
);
CREATE INDEX org_unit_parent_idx ON org_unit (parent_id);

CREATE TABLE employee (
    id         varchar(32)  PRIMARY KEY,
    full_name  varchar(255) NOT NULL,
    position   varchar(255),
    unit_id    varchar(32)  NOT NULL REFERENCES org_unit (id)
);

CREATE TABLE goal (
    id          varchar(32)  PRIMARY KEY,
    title       varchar(500) NOT NULL,
    level       varchar(16)  NOT NULL CHECK (level IN ('block', 'hq', 'unit', 'employee')),
    unit_id     varchar(32)  NOT NULL REFERENCES org_unit (id),
    owner_id    varchar(32)  REFERENCES employee (id),    -- ответственный; может быть не заполнен
    parent_id   varchar(32)  REFERENCES goal (id),        -- родительская цель (каскад)
    status      varchar(16)  NOT NULL CHECK (status IN ('draft', 'active', 'closed', 'cancelled')),
    deadline    date,                                     -- срок достижения
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    CHECK (parent_id <> id)
);
CREATE INDEX goal_unit_status_idx ON goal (unit_id, status);
CREATE INDEX goal_parent_idx ON goal (parent_id);

CREATE TABLE key_result (
    id               varchar(32)   PRIMARY KEY,
    goal_id          varchar(32)   NOT NULL REFERENCES goal (id) ON DELETE CASCADE,
    title            varchar(500)  NOT NULL,
    metric_unit      varchar(32),                         -- единица измерения: %, шт., млн ₽
    baseline_value   numeric(18,4),
    target_value     numeric(18,4),                       -- целевое значение
    fact_value       numeric(18,4),                       -- фактическое значение
    weight           numeric(5,2),                        -- вес КР в процентах
    fact_updated_at  timestamptz,                         -- когда последний раз вносили факт; NULL — ни разу
    created_at       timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX key_result_goal_idx ON key_result (goal_id);
