-- 20_test_scenario.sql — 5 прогонов на тестовых данных и проверки (ASSERT).
-- Любая неверная цифра останавливает скрипт с сообщением «ожидалось / получено».
-- Перед запуском: 00, 01, 02, 03 и test/10_test_data.sql.

CREATE FUNCTION pg_temp.t_eq(actual text, expected text, what text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL %: ожидалось [%], получено [%]', what, expected, actual;
    END IF;
    RAISE NOTICE 'ok  %', what;
END $$;

-- Компактный вид метрик: "clean_goals_share=37.5 cascade_coverage=71.4 issues_total=6"
CREATE FUNCTION pg_temp.t_metrics(p_run bigint, p_unit varchar) RETURNS text
LANGUAGE sql AS $$
    SELECT string_agg(m.metric_key || '=' || COALESCE(m.value::text, 'null'), ' ' ORDER BY d.sort_order)
      FROM kkd_run_metric m JOIN kkd_metric_def d ON d.key = m.metric_key
     WHERE m.run_id = p_run AND m.unit_id = p_unit
$$;

-- Компактный вид проблем прогона: "CASCADE_NO_PARENT:G-05/new ..."
CREATE FUNCTION pg_temp.t_issues(p_run bigint) RETURNS text
LANGUAGE sql AS $$
    SELECT string_agg(fingerprint || '/' || delta_status, ' ' ORDER BY fingerprint)
      FROM kkd_issue WHERE run_id = p_run
$$;

-- ================= Чистая проверка правил (без записи) =================
DO $$ BEGIN
  PERFORM pg_temp.t_eq(
    (SELECT string_agg(rule_code || ':' || object_id, ' ' ORDER BY rule_code, object_id)
       FROM kkd_find_violations('2026-10-19', ARRAY['GOAL_NO_KR','KR_WEIGHTS_SUM','CASCADE_NO_PARENT','KR_STALE_PROGRESS'])),
    'CASCADE_NO_PARENT:G-05 GOAL_NO_KR:G-06 KR_STALE_PROGRESS:KR-07 KR_WEIGHTS_SUM:G-03 KR_WEIGHTS_SUM:G-04',
    'правила на 19.10: block без родителя, родитель-draft, draft и closed цели не нарушают');
  PERFORM pg_temp.t_eq(
    (SELECT actual_value::text FROM kkd_find_violations('2026-10-19', ARRAY['KR_WEIGHTS_SUM']) WHERE object_id = 'G-03'),
    '99.5', 'веса 99.5 -> нарушение, actual = 99.5');
  PERFORM pg_temp.t_eq(
    (SELECT actual_value::text FROM kkd_find_violations('2026-10-19', ARRAY['KR_WEIGHTS_SUM']) WHERE object_id = 'G-04'),
    '100.5', 'веса 100.5 -> нарушение, actual = 100.5');
  PERFORM pg_temp.t_eq(
    (SELECT count(*)::text FROM kkd_find_violations('2026-10-19', ARRAY['KR_WEIGHTS_SUM']) WHERE object_id = 'G-02'),
    '0', 'веса 50 + 50 = 100 -> нет нарушения');
  PERFORM pg_temp.t_eq(
    (SELECT count(*)::text FROM kkd_find_violations('2026-10-19', ARRAY['KR_WEIGHTS_SUM']) WHERE object_id = 'G-06'),
    '0', 'цель без КР -> только GOAL_NO_KR, без KR_WEIGHTS_SUM');
  PERFORM pg_temp.t_eq(
    (SELECT string_agg(object_id || '=' || actual_value::text, ' ' ORDER BY object_id)
       FROM kkd_find_violations('2026-11-02', ARRAY['KR_STALE_PROGRESS'])),
    'KR-03=46 KR-07=93', 'на 02.11: 45 дней (KR-02, KR-06 по МСК) — норма, 46 и «ни разу» — нарушение');
  PERFORM pg_temp.t_eq(
    (SELECT details FROM kkd_find_violations('2026-11-02', ARRAY['KR_STALE_PROGRESS']) WHERE object_id = 'KR-07'),
    'Факт ни разу не вносился, КР создан 93 дн. назад', 'текст для КР без факта');
END $$;

-- ================= Прогон 1 — первый =================
SELECT kkd_start_run('schedule', '2026-10-19');
DO $$ BEGIN
  PERFORM pg_temp.t_eq(kkd_execute_run(1), 'completed', 'прогон 1 завершён');
  PERFORM pg_temp.t_eq((SELECT compared_to_run_id::text FROM kkd_run WHERE id = 1), NULL, 'прогон 1: сравнивать не с чем');
  PERFORM pg_temp.t_eq(pg_temp.t_issues(1),
    'CASCADE_NO_PARENT:G-05/new GOAL_NO_KR:G-06/new KR_STALE_PROGRESS:KR-07/new KR_WEIGHTS_SUM:G-03/new KR_WEIGHTS_SUM:G-04/new',
    'прогон 1: 5 проблем, все new');
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(1, 'B2B'),
    'clean_goals_share=50.0 cascade_coverage=85.7 issues_total=5', 'прогон 1: метрики блока');
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(1, 'CIB-KEY'),
    'clean_goals_share=33.3 cascade_coverage=100.0 issues_total=3', 'прогон 1: метрики CIB-KEY');
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(1, 'HQ-TX'),
    'clean_goals_share=100.0 cascade_coverage=100.0 issues_total=0', 'прогон 1: HQ-TX без проблем -> 0, не null');
END $$;

-- Данные между прогонами: G-03 веса исправили, у G-04 веса стали 110, у G-11 пропал родитель
UPDATE key_result SET weight = 40 WHERE id = 'KR-05';
UPDATE key_result SET weight = 50 WHERE id = 'KR-07';
UPDATE goal SET parent_id = NULL WHERE id = 'G-11';

-- ================= Прогон 2 — падает =================
SELECT kkd_start_run('schedule', '2026-10-26');
ALTER TABLE kkd_issue ADD CONSTRAINT t_simulate_failure CHECK (rule_code <> 'GOAL_NO_KR') NOT VALID;
DO $$ BEGIN
  PERFORM pg_temp.t_eq(kkd_execute_run(2), 'failed', 'прогон 2 упал');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issue WHERE run_id = 2), '0', 'прогон 2: частичных проблем нет');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_run_metric WHERE run_id = 2), '0', 'прогон 2: частичных метрик нет');
  PERFORM pg_temp.t_eq((SELECT (error_message IS NOT NULL AND finished_at IS NOT NULL)::text FROM kkd_run WHERE id = 2),
    'true', 'прогон 2: текст ошибки и время окончания записаны');
END $$;
ALTER TABLE kkd_issue DROP CONSTRAINT t_simulate_failure;

-- ================= Прогон 3 — сравнивается с прогоном 1 =================
SELECT kkd_start_run('schedule', '2026-11-02');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT compared_to_run_id::text FROM kkd_run WHERE id = 3), '1', 'прогон 3 сравнивается с 1 (2 упал)');
  PERFORM pg_temp.t_eq(kkd_execute_run(3), 'completed', 'прогон 3 завершён');
  PERFORM pg_temp.t_eq(pg_temp.t_issues(3),
    'CASCADE_NO_PARENT:G-05/persisting CASCADE_NO_PARENT:G-11/new GOAL_NO_KR:G-06/persisting KR_STALE_PROGRESS:KR-03/new KR_STALE_PROGRESS:KR-07/persisting KR_WEIGHTS_SUM:G-04/persisting',
    'прогон 3: 2 new, 4 persisting');
  PERFORM pg_temp.t_eq(
    (SELECT actual_value::text || ' ' || runs_in_row || ' ' || first_detected_run_id FROM kkd_issue
      WHERE run_id = 3 AND fingerprint = 'KR_WEIGHTS_SUM:G-04'),
    '110 2 1', 'детали изменились (100.5 -> 110), проблема та же: persisting, 2-й прогон подряд');
  PERFORM pg_temp.t_eq(
    (SELECT (a.issue_id = b.issue_id)::text FROM kkd_issue a JOIN kkd_issue b USING (fingerprint)
      WHERE a.run_id = 1 AND b.run_id = 3 AND fingerprint = 'GOAL_NO_KR:G-06'),
    'true', 'issue_id стабилен между прогонами');
  PERFORM pg_temp.t_eq(
    (SELECT string_agg(fingerprint, ' ') FROM kkd_issue_feed WHERE run_id = 3 AND delta_status = 'resolved'),
    'KR_WEIGHTS_SUM:G-03', 'прогон 3: исправлена G-03');
  -- метрики и каскад по оргструктуре
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(3, 'B2B'),
    'clean_goals_share=37.5 cascade_coverage=71.4 issues_total=6', 'прогон 3: блок');
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(3, 'HQ-CIB'),
    'clean_goals_share=33.3 cascade_coverage=83.3 issues_total=5', 'прогон 3: департамент = объединение целей, не среднее дочерних (100 и 50)');
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(3, 'CIB-KEY'),
    'clean_goals_share=66.7 cascade_coverage=100.0 issues_total=2', 'прогон 3: CIB-KEY');
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(3, 'CIB-REG'),
    'clean_goals_share=0.0 cascade_coverage=50.0 issues_total=2', 'прогон 3: CIB-REG');
  PERFORM pg_temp.t_eq(pg_temp.t_metrics(3, 'TX-NEW'),
    'clean_goals_share=null cascade_coverage=null issues_total=null', 'прогон 3: подразделение без целей -> null');
  PERFORM pg_temp.t_eq(
    (SELECT string_agg(numerator || '/' || COALESCE(denominator::text, '-'), ' ' ORDER BY metric_key)
       FROM kkd_run_metric WHERE run_id = 3 AND unit_id = 'TX-NEW'),
    '0/0 0/0 0/-', 'прогон 3: TX-NEW числители и знаменатели');
END $$;

-- ================= Запросы API на прогоне 3 =================
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_unit_scope('HQ-CIB')), '3', 'периметр HQ-CIB = 3 подразделения');
END $$;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_metrics(3, 'B2B');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT string_agg(key || ':' || value || '|' || previous || '|' || delta || '|' || delta_pct || '|' || trend, ' ') FROM t_out),
    'clean_goals_share:37.5|50.0|-12.5|-25.0|worse cascade_coverage:71.4|85.7|-14.3|-16.7|worse issues_total:6|5|1|20.0|worse',
    'summary B2B: дельта и тренд (рост проблем = worse)');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_metrics(3, 'CIB-KEY');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT string_agg(key || ':' || delta || '|' || COALESCE(delta_pct::text, 'null') || '|' || trend, ' ') FROM t_out),
    'clean_goals_share:33.4|100.3|better cascade_coverage:0.0|0.0|same issues_total:-1|-33.3|better',
    'summary CIB-KEY: дельта по округлённым значениям (66.7 - 33.3 = 33.4), снижение проблем = better');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_metrics(3, 'HQ-TX');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT key || ':' || previous || '|' || delta || '|' || COALESCE(delta_pct::text, 'null') || '|' || trend FROM t_out WHERE key = 'issues_total'),
    'issues_total:0|1|null|worse', 'summary HQ-TX: previous = 0 -> delta_pct = null');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_metrics(3, 'TX-NEW');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT string_agg(COALESCE(value::text, 'null') || '|' || COALESCE(trend, 'null'), ' ') FROM t_out),
    'null|null null|null null|null', 'summary TX-NEW: value, trend = null');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_metrics(1, 'B2B');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT string_agg(COALESCE(previous::text, 'null') || '|' || COALESCE(delta::text, 'null') || '|' || COALESCE(trend, 'null'), ' ') FROM t_out),
    'null|null|null null|null|null null|null|null', 'summary первого прогона: previous, delta, trend = null');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_delta(3, 'B2B');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT cnt_new || '/' || cnt_persisting || '/' || cnt_resolved FROM t_out), '2/4/1', 'delta B2B: new/persisting/resolved');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_delta(3, 'CIB-KEY');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT cnt_new || '/' || cnt_persisting || '/' || cnt_resolved FROM t_out), '0/2/1', 'delta CIB-KEY');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_delta(1, 'B2B');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT COALESCE(cnt_new::text, 'null') || '/' || COALESCE(cnt_resolved::text, 'null') FROM t_out), 'null/null', 'delta первого прогона = null, не 0');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_by_rule(3, 'B2B');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT string_agg(code || '=' || current || '/' || previous || '/' || delta, ' ') FROM t_out),
    'GOAL_NO_KR=1/1/0 CASCADE_NO_PARENT=2/1/1 KR_WEIGHTS_SUM=1/2/-1 KR_STALE_PROGRESS=2/1/1', 'issues_by_rule B2B');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_summary_by_severity(3, 'TX-NEW');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT string_agg(code || '=' || current || '/' || previous, ' ') FROM t_out),
    'critical=0/0 major=0/0 minor=0/0', 'issues_by_severity без целей: всегда 3 строки с нулями');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_issues_page(3, 'B2B', 20, 0);
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT string_agg(fingerprint, ' ') FROM t_out),
    'GOAL_NO_KR:G-06 KR_WEIGHTS_SUM:G-04 CASCADE_NO_PARENT:G-05 CASCADE_NO_PARENT:G-11 KR_STALE_PROGRESS:KR-07 KR_STALE_PROGRESS:KR-03',
    'issues sort=severity: важность, затем дольше живущие, затем object_id');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_issues_page(3, 'B2B', 20, 10);
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM t_out), '0', 'offset за пределами -> пустая страница');
END $$;
DROP TABLE t_out;

CREATE TEMP TABLE t_out AS EXECUTE kkd_issues_total(3, 'B2B');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT total::text FROM t_out), '6', 'total без resolved');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(3, 'B2B', p_delta_statuses => '{resolved}')), '1', 'фильтр resolved');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(3, 'B2B', p_delta_statuses => '{new,resolved}')), '3', 'фильтр new,resolved');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(3, 'B2B', p_severities => '{major}', p_object_type => 'goal')), '3', 'фильтр major + goal');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(3, 'B2B', p_q => 'g-04')), '2', 'поиск без учёта регистра по ID цели');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(3, 'B2B', p_q => 'Сотрудник 0004')), '2', 'поиск по ФИО ответственного');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(3, 'B2B', p_q => 'КРОСС')), '2', 'поиск по названию цели/КР, кириллица без учёта регистра');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(3, 'TX-NEW')), '0', 'подразделение без целей -> пустой список');
  PERFORM pg_temp.t_eq((SELECT count(*)::text FROM kkd_issues_filtered(1, 'B2B', p_delta_statuses => '{resolved}')), '0', 'первый прогон: resolved нет');
END $$;
DROP TABLE t_out;

-- ================= Прогон 4 — проблема вернулась, правило выключено =================
UPDATE key_result SET weight = 39.5 WHERE id = 'KR-05';           -- G-03 снова 99.5
UPDATE goal SET parent_id = 'G-02' WHERE id = 'G-05';              -- каскад G-05 починили
UPDATE kkd_rule SET is_enabled = false WHERE code = 'KR_STALE_PROGRESS';
SELECT kkd_start_run('manual', '2026-11-09');
DO $$ BEGIN
  PERFORM pg_temp.t_eq(kkd_execute_run(4), 'completed', 'прогон 4 завершён');
  PERFORM pg_temp.t_eq(pg_temp.t_issues(4),
    'CASCADE_NO_PARENT:G-11/persisting GOAL_NO_KR:G-06/persisting KR_WEIGHTS_SUM:G-03/new KR_WEIGHTS_SUM:G-04/persisting',
    'прогон 4: вернувшаяся проблема G-03 — new');
  PERFORM pg_temp.t_eq(
    (SELECT first_detected_run_id || '/' || runs_in_row FROM kkd_issue WHERE run_id = 4 AND fingerprint = 'KR_WEIGHTS_SUM:G-03'),
    '4/1', 'вернувшаяся проблема: счёт заново');
  PERFORM pg_temp.t_eq(
    (SELECT string_agg(fingerprint, ' ') FROM kkd_issue_feed WHERE run_id = 4 AND delta_status = 'resolved'),
    'CASCADE_NO_PARENT:G-05', 'выключенное правило не даёт resolved');
END $$;
UPDATE kkd_rule SET is_enabled = true WHERE code = 'KR_STALE_PROGRESS';

-- ================= Прогон выполняется / завис =================
SELECT kkd_start_run('manual', '2026-11-16');
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM kkd_start_run('manual', '2026-11-16');
    v_state := 'второй запуск прошёл';
  EXCEPTION WHEN unique_violation THEN
    v_state := 'unique_violation';
  END;
  PERFORM pg_temp.t_eq(v_state, 'unique_violation', 'второй одновременный прогон запрещён (-> 409 RUN_IN_PROGRESS)');
  PERFORM pg_temp.t_eq((SELECT status || '/' || COALESCE(finished_at::text, 'null') FROM kkd_run WHERE id = 5), 'running/null', 'прогон 5 выполняется');
END $$;
UPDATE kkd_run SET started_at = now() - interval '3 hours' WHERE id = 5;
SELECT kkd_start_run('manual', '2026-11-16');
DO $$ BEGIN
  PERFORM pg_temp.t_eq((SELECT status FROM kkd_run WHERE id = 5), 'failed', 'зависший прогон 5 помечен failed');
  PERFORM pg_temp.t_eq((SELECT status || '/' || compared_to_run_id FROM kkd_run ORDER BY id DESC LIMIT 1),
    'running/4', 'новый прогон сравнивается с последним успешным 4');
  PERFORM pg_temp.t_eq((SELECT max(id)::text FROM kkd_run), '7',
    'номер 6 «съела» отклонённая попытка запуска: номера прогонов идут с пропусками — это норма');
END $$;

SELECT 'ALL CHECKS PASSED' AS result;
