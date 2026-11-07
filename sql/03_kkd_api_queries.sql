-- 03_kkd_api_queries.sql
-- Запросы бэкенда для страницы ККД. Это не объекты БД: PREPARE живёт в сессии,
-- чтобы запросы можно было выполнить в psql и в тестах. В Java — те же тексты, $N -> ?.
-- $1 — номер прогона (kkd_run.id), $2 — код подразделения.

-- Метрики для GET /api/kkd/summary: значение, прошлое значение, дельта, тренд
PREPARE kkd_summary_metrics (bigint, varchar) AS
SELECT d.key, d.title, d.unit, d.higher_is_better, d.formula,
       cur.value, cur.numerator, cur.denominator,
       prev.value                                                        AS previous,
       cur.value - prev.value                                            AS delta,
       ROUND(100 * (cur.value - prev.value) / NULLIF(prev.value, 0), 1) AS delta_pct,
       CASE WHEN cur.value IS NULL OR prev.value IS NULL      THEN NULL
            WHEN cur.value = prev.value                       THEN 'same'
            WHEN (cur.value > prev.value) = d.higher_is_better THEN 'better'
            ELSE 'worse' END                                             AS trend
  FROM kkd_run r
 CROSS JOIN kkd_metric_def d
  LEFT JOIN kkd_run_metric cur  ON cur.run_id = r.id
                               AND cur.unit_id = $2 AND cur.metric_key = d.key
  LEFT JOIN kkd_run_metric prev ON prev.run_id = r.compared_to_run_id
                               AND prev.unit_id = $2 AND prev.metric_key = d.key
 WHERE r.id = $1
 ORDER BY d.sort_order;

-- Счётчики дельты для GET /api/kkd/summary (NULL у первого прогона)
PREPARE kkd_summary_delta (bigint, varchar) AS
SELECT CASE WHEN r.compared_to_run_id IS NOT NULL
            THEN count(f.issue_id) FILTER (WHERE f.delta_status = 'new') END        AS cnt_new,
       CASE WHEN r.compared_to_run_id IS NOT NULL
            THEN count(f.issue_id) FILTER (WHERE f.delta_status = 'persisting') END AS cnt_persisting,
       CASE WHEN r.compared_to_run_id IS NOT NULL
            THEN count(f.issue_id) FILTER (WHERE f.delta_status = 'resolved') END   AS cnt_resolved
  FROM kkd_run r
  LEFT JOIN kkd_issue_feed f ON f.run_id = r.id
                            AND f.unit_id IN (SELECT unit_id FROM kkd_unit_scope($2))
 WHERE r.id = $1
 GROUP BY r.id, r.compared_to_run_id;

-- Разбивка по правилам для GET /api/kkd/summary (только правила этого прогона)
PREPARE kkd_summary_by_rule (bigint, varchar) AS
SELECT x.code, x.title, x.severity, x.object_type, x.current, x.previous,
       x.current - x.previous AS delta
  FROM (SELECT rl.code, rl.title, rl.severity, rl.object_type,
               (SELECT count(*) FROM kkd_issue i
                 WHERE i.run_id = r.id AND i.rule_code = rl.code
                   AND i.unit_id IN (SELECT unit_id FROM kkd_unit_scope($2))) AS current,
               CASE WHEN r.compared_to_run_id IS NOT NULL THEN
               (SELECT count(*) FROM kkd_issue i
                 WHERE i.run_id = r.compared_to_run_id AND i.rule_code = rl.code
                   AND i.unit_id IN (SELECT unit_id FROM kkd_unit_scope($2))) END AS previous
          FROM kkd_run r
          JOIN kkd_rule rl ON rl.code = ANY (r.rule_codes)
         WHERE r.id = $1) x
 ORDER BY CASE x.severity WHEN 'critical' THEN 0 WHEN 'major' THEN 1 ELSE 2 END, x.code;

-- Разбивка по важности: всегда 3 строки (critical, major, minor), правила — как у прогона
PREPARE kkd_summary_by_severity (bigint, varchar) AS
SELECT s.code, s.current, s.previous, s.current - s.previous AS delta
  FROM kkd_run r
 CROSS JOIN LATERAL (
       SELECT sv.code, sv.ord,
              (SELECT count(*) FROM kkd_issue i
                WHERE i.run_id = r.id AND i.severity = sv.code
                  AND i.unit_id IN (SELECT unit_id FROM kkd_unit_scope($2))) AS current,
              CASE WHEN r.compared_to_run_id IS NOT NULL THEN
              (SELECT count(*) FROM kkd_issue i
                WHERE i.run_id = r.compared_to_run_id AND i.severity = sv.code
                  AND i.rule_code = ANY (r.rule_codes)
                  AND i.unit_id IN (SELECT unit_id FROM kkd_unit_scope($2))) END AS previous
         FROM (VALUES ('critical', 0), ('major', 1), ('minor', 2)) AS sv (code, ord)) s
 WHERE r.id = $1
 ORDER BY s.ord;

-- GET /api/kkd/issues: страница (сортировка по умолчанию sort=severity) и total
PREPARE kkd_issues_page (bigint, varchar, int, int) AS
SELECT f.*, u.name AS unit_name, e.full_name AS owner_full_name, e.position AS owner_position
  FROM kkd_issues_filtered($1, $2) f
  LEFT JOIN org_unit u ON u.id = f.unit_id
  LEFT JOIN employee e ON e.id = f.owner_id
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'major' THEN 1 ELSE 2 END,
          f.runs_in_row DESC, f.object_id, f.rule_code
 LIMIT $3 OFFSET $4;

PREPARE kkd_issues_total (bigint, varchar) AS
SELECT count(*) AS total FROM kkd_issues_filtered($1, $2);
