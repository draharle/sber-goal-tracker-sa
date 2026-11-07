-- 02_kkd_logic.sql
-- Логика ККД: 4 правила, запуск и выполнение прогона, метрики, дельта, лента проблем.
-- Порядок работы сервиса:
--   1) SELECT kkd_start_run('schedule');            -- отдельная транзакция, прогон виден как running
--   2) BEGIN ISOLATION LEVEL REPEATABLE READ;       -- один согласованный снимок данных
--      SELECT kkd_execute_run(:run_id);             -- правила + дельта + метрики, всё или ничего
--      COMMIT;

-- Периметр подразделения: оно само и все дочерние (каскад по оргструктуре)
CREATE FUNCTION kkd_unit_scope(p_unit_id varchar)
RETURNS TABLE (unit_id varchar) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE scope AS (
        SELECT u.id FROM org_unit u WHERE u.id = p_unit_id
        UNION                       -- UNION, а не UNION ALL: защита от цикла в иерархии
        SELECT c.id FROM org_unit c JOIN scope s ON c.parent_id = s.id
    )
    SELECT id FROM scope
$$;

-- Все нарушения 4 правил на дату снимка. Только чтение, ничего не пишет.
CREATE FUNCTION kkd_find_violations(p_snapshot_date date, p_rule_codes varchar[])
RETURNS TABLE (rule_code varchar, object_type varchar, object_id varchar,
               goal_id varchar, goal_title varchar, goal_level varchar,
               kr_id varchar, kr_title varchar, unit_id varchar, owner_id varchar,
               details varchar, actual_value jsonb, expected_value jsonb)
LANGUAGE sql STABLE AS $$
-- R1. GOAL_NO_KR: у активной цели нет ни одного КР
SELECT 'GOAL_NO_KR' AS rule_code, 'goal' AS object_type, g.id AS object_id,
       g.id AS goal_id, g.title AS goal_title, g.level AS goal_level,
       NULL AS kr_id, NULL AS kr_title, g.unit_id, g.owner_id,
       'У цели 0 ключевых результатов' AS details,
       to_jsonb(0) AS actual_value, to_jsonb('>= 1'::text) AS expected_value
  FROM goal g
 WHERE g.status = 'active'
   AND NOT EXISTS (SELECT 1 FROM key_result kr WHERE kr.goal_id = g.id)
   AND 'GOAL_NO_KR' = ANY (p_rule_codes)

UNION ALL

-- R2. KR_WEIGHTS_SUM: сумма весов КР активной цели не равна 100 (точное сравнение numeric)
SELECT 'KR_WEIGHTS_SUM' AS rule_code, 'goal' AS object_type, g.id AS object_id,
       g.id AS goal_id, g.title AS goal_title, g.level AS goal_level,
       NULL AS kr_id, NULL AS kr_title, g.unit_id, g.owner_id,
       format('Сумма весов КР = %s%%, ожидается 100%%', trim_scale(w.total)) AS details,
       to_jsonb(trim_scale(w.total)) AS actual_value, to_jsonb(100) AS expected_value
  FROM goal g
  JOIN (SELECT kr.goal_id, ROUND(SUM(COALESCE(kr.weight, 0)), 2) AS total
          FROM key_result kr
         GROUP BY kr.goal_id) w ON w.goal_id = g.id      -- цели без КР сюда не попадают
 WHERE g.status = 'active'
   AND w.total <> 100
   AND 'KR_WEIGHTS_SUM' = ANY (p_rule_codes)

UNION ALL

-- R3. CASCADE_NO_PARENT: активная цель ниже уровня блока без родительской цели
SELECT 'CASCADE_NO_PARENT' AS rule_code, 'goal' AS object_type, g.id AS object_id,
       g.id AS goal_id, g.title AS goal_title, g.level AS goal_level,
       NULL AS kr_id, NULL AS kr_title, g.unit_id, g.owner_id,
       CASE WHEN g.parent_id IS NULL THEN 'Родительская цель не указана'
            ELSE format('Родительская цель %s не найдена', g.parent_id) END AS details,
       to_jsonb(g.parent_id) AS actual_value,
       to_jsonb('цель вышестоящего уровня'::text) AS expected_value
  FROM goal g
 WHERE g.status = 'active'
   AND g.level <> 'block'
   AND (g.parent_id IS NULL
        OR NOT EXISTS (SELECT 1 FROM goal p WHERE p.id = g.parent_id))
   AND 'CASCADE_NO_PARENT' = ANY (p_rule_codes)

UNION ALL

-- R4. KR_STALE_PROGRESS: факт КР активной цели не обновлялся больше stale_days (45) дней
SELECT 'KR_STALE_PROGRESS' AS rule_code, 'key_result' AS object_type, kr.id AS object_id,
       g.id AS goal_id, g.title AS goal_title, g.level AS goal_level,
       kr.id AS kr_id, kr.title AS kr_title, g.unit_id, g.owner_id,
       CASE WHEN kr.fact_updated_at IS NULL
            THEN format('Факт ни разу не вносился, КР создан %s дн. назад', a.age_days)
            ELSE format('Факт обновлялся %s дн. назад', a.age_days) END AS details,
       to_jsonb(a.age_days) AS actual_value,
       to_jsonb('<= ' || (r.params ->> 'stale_days')) AS expected_value
  FROM key_result kr
  JOIN goal g ON g.id = kr.goal_id
  JOIN kkd_rule r ON r.code = 'KR_STALE_PROGRESS'
 CROSS JOIN LATERAL (
       SELECT p_snapshot_date
              - (COALESCE(kr.fact_updated_at, kr.created_at) AT TIME ZONE 'Europe/Moscow')::date
              AS age_days) a
 WHERE g.status = 'active'
   AND a.age_days > (r.params ->> 'stale_days')::int
   AND 'KR_STALE_PROGRESS' = ANY (p_rule_codes)
$$;

-- Шаг 1. Создать прогон в статусе running (отдельная транзакция).
CREATE FUNCTION kkd_start_run(p_trigger_type varchar, p_snapshot_date date DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_run_id bigint;
BEGIN
    -- прогон, который «висит» дольше 2 часов (упал процесс), считаем упавшим
    UPDATE kkd_run
       SET status = 'failed', finished_at = now(),
           error_message = 'Превышено время выполнения прогона (2 часа)'
     WHERE status = 'running' AND started_at < now() - interval '2 hours';

    INSERT INTO kkd_run (trigger_type, snapshot_date, compared_to_run_id, rule_codes)
    VALUES (p_trigger_type,
            COALESCE(p_snapshot_date, (now() AT TIME ZONE 'Europe/Moscow')::date),
            (SELECT max(id) FROM kkd_run WHERE status = 'completed'),  -- предыдущий УСПЕШНЫЙ
            ARRAY(SELECT code FROM kkd_rule WHERE is_enabled ORDER BY code))
    RETURNING id INTO v_run_id;   -- если уже есть running: unique_violation -> 409 RUN_IN_PROGRESS
    RETURN v_run_id;
END;
$$;

-- Шаг 2. Выполнить прогон: проблемы с дельтой, метрики, статус. Всё или ничего.
CREATE FUNCTION kkd_execute_run(p_run_id bigint)
RETURNS varchar LANGUAGE plpgsql AS $$
DECLARE
    v_run  kkd_run%ROWTYPE;
    v_err  text;
BEGIN
    SELECT * INTO v_run FROM kkd_run WHERE id = p_run_id AND status = 'running' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Прогон % не найден или уже завершён', p_run_id;
    END IF;

    BEGIN
-- D1. Проблемы прогона + дельта с предыдущим успешным прогоном
INSERT INTO kkd_issue (run_id, fingerprint, issue_id, rule_code, severity, object_type,
                       object_id, goal_id, goal_title, goal_level, kr_id, kr_title,
                       unit_id, owner_id, details, actual_value, expected_value,
                       delta_status, first_detected_run_id, runs_in_row)
SELECT p_run_id, f.fp,
       'ISS-' || upper(left(encode(sha256(convert_to(f.fp, 'UTF8')), 'hex'), 10)),
       v.rule_code, rl.severity, v.object_type,
       v.object_id, v.goal_id, v.goal_title, v.goal_level, v.kr_id, v.kr_title,
       v.unit_id, v.owner_id, v.details, v.actual_value, v.expected_value,
       CASE WHEN prev.fingerprint IS NULL THEN 'new' ELSE 'persisting' END,
       COALESCE(prev.first_detected_run_id, p_run_id),
       COALESCE(prev.runs_in_row, 0) + 1
  FROM kkd_find_violations(v_run.snapshot_date, v_run.rule_codes) v
 CROSS JOIN LATERAL (SELECT v.rule_code || ':' || v.object_id AS fp) f
  JOIN kkd_rule rl ON rl.code = v.rule_code
  LEFT JOIN kkd_issue prev ON prev.run_id = v_run.compared_to_run_id   -- NULL у первого прогона
                          AND prev.fingerprint = f.fp;

-- M1. Метрики по каждому подразделению: само подразделение + все дочерние
INSERT INTO kkd_run_metric (run_id, unit_id, metric_key, value, numerator, denominator)
WITH RECURSIVE subtree AS (            -- пары (подразделение, оно само или его потомок)
    SELECT u.id AS root_id, u.id AS unit_id FROM org_unit u
    UNION                              -- UNION, а не UNION ALL: защита от цикла в иерархии
    SELECT s.root_id, c.id FROM subtree s JOIN org_unit c ON c.parent_id = s.unit_id
),
goal_flags AS (                        -- активные цели и их проблемы в этом прогоне
    SELECT g.id, g.unit_id, g.level,
           (SELECT count(*) FROM kkd_issue i
             WHERE i.run_id = p_run_id AND i.goal_id = g.id) AS issues,
           EXISTS (SELECT 1 FROM kkd_issue i JOIN kkd_rule rl ON rl.code = i.rule_code
                    WHERE i.run_id = p_run_id AND i.goal_id = g.id
                      AND rl.is_cascade) AS has_cascade_issue
      FROM goal g
     WHERE g.status = 'active'
),
agg AS (
    SELECT s.root_id AS unit_id,
           count(gf.id)                                        AS goals_active,
           count(gf.id) FILTER (WHERE gf.issues = 0)           AS goals_clean,
           count(gf.id) FILTER (WHERE gf.level <> 'block')     AS goals_non_block,
           count(gf.id) FILTER (WHERE gf.level <> 'block'
                                  AND NOT gf.has_cascade_issue) AS goals_cascaded,
           COALESCE(sum(gf.issues), 0)                         AS issues
      FROM subtree s
      LEFT JOIN goal_flags gf ON gf.unit_id = s.unit_id
     GROUP BY s.root_id
)
SELECT p_run_id, a.unit_id, m.metric_key, m.value, m.numerator, m.denominator
  FROM agg a
 CROSS JOIN LATERAL (VALUES
       ('clean_goals_share', ROUND(100.0 * a.goals_clean / NULLIF(a.goals_active, 0), 1),
                             a.goals_clean, a.goals_active),
       ('cascade_coverage',  ROUND(100.0 * a.goals_cascaded / NULLIF(a.goals_non_block, 0), 1),
                             a.goals_cascaded, a.goals_non_block),
       ('issues_total',      CASE WHEN a.goals_active > 0 THEN a.issues END,
                             a.issues, NULL)
 ) AS m (metric_key, value, numerator, denominator);

        UPDATE kkd_run SET status = 'completed', finished_at = now() WHERE id = p_run_id;
    EXCEPTION WHEN OTHERS THEN
        -- всё, что вставлено в этом блоке, откатилось: у упавшего прогона нет результатов
        GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
        UPDATE kkd_run
           SET status = 'failed', finished_at = now(), error_message = left(v_err, 1000)
         WHERE id = p_run_id;
    END;
    RETURN (SELECT status FROM kkd_run WHERE id = p_run_id);
END;
$$;

-- Лента проблем прогона с дельтой: new / persisting (из прогона) + resolved (из прошлого)
CREATE VIEW kkd_issue_feed AS
SELECT i.run_id, i.issue_id, i.fingerprint, i.rule_code, i.severity, i.object_type,
       i.object_id, i.goal_id, i.goal_title, i.goal_level, i.kr_id, i.kr_title,
       i.unit_id, i.owner_id, i.details, i.actual_value, i.expected_value,
       i.delta_status, i.first_detected_run_id, i.runs_in_row
  FROM kkd_issue i
UNION ALL
SELECT r.id, p.issue_id, p.fingerprint, p.rule_code, p.severity, p.object_type,
       p.object_id, p.goal_id, p.goal_title, p.goal_level, p.kr_id, p.kr_title,
       p.unit_id, p.owner_id, p.details, p.actual_value, p.expected_value,
       'resolved', p.first_detected_run_id, p.runs_in_row
  FROM kkd_run r
  JOIN kkd_issue p ON p.run_id = r.compared_to_run_id
 WHERE r.status = 'completed'
   AND p.rule_code = ANY (r.rule_codes)        -- выключенное правило не даёт «исправлений»
   AND NOT EXISTS (SELECT 1 FROM kkd_issue c
                    WHERE c.run_id = r.id AND c.fingerprint = p.fingerprint);

-- Фильтры GET /api/kkd/issues. Пустой параметр (NULL) = фильтр не применяется.
CREATE FUNCTION kkd_issues_filtered(
    p_run_id bigint, p_unit_id varchar,
    p_rule_codes varchar[] DEFAULT NULL, p_severities varchar[] DEFAULT NULL,
    p_delta_statuses varchar[] DEFAULT NULL, p_object_type varchar DEFAULT NULL,
    p_q varchar DEFAULT NULL)
RETURNS SETOF kkd_issue_feed LANGUAGE sql STABLE AS $$
    SELECT f.*
      FROM kkd_issue_feed f
      LEFT JOIN employee e ON e.id = f.owner_id
     WHERE f.run_id = p_run_id
       AND f.unit_id IN (SELECT unit_id FROM kkd_unit_scope(p_unit_id))
       AND (p_rule_codes IS NULL OR f.rule_code = ANY (p_rule_codes))
       AND (p_severities IS NULL OR f.severity = ANY (p_severities))
       AND (CASE WHEN p_delta_statuses IS NULL THEN f.delta_status <> 'resolved'
                 ELSE f.delta_status = ANY (p_delta_statuses) END)
       AND (p_object_type IS NULL OR f.object_type = p_object_type)
       AND (p_q IS NULL OR concat_ws(' ', f.issue_id, f.goal_id, f.goal_title,
                                     f.kr_id, f.kr_title, e.full_name) ILIKE '%' || p_q || '%')
$$;
