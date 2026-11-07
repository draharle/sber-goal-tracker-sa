-- 99_kkd_rollback.sql
-- Откат модуля ККД: удаляет только объекты kkd_*. Таблицы модуля «Цели» не трогает.
-- После отката 01 и 02 накатываются повторно без ошибок (проверяется тестом).

DROP FUNCTION IF EXISTS kkd_issues_filtered(bigint, varchar, varchar[], varchar[], varchar[], varchar, varchar);
DROP VIEW     IF EXISTS kkd_issue_feed;
DROP FUNCTION IF EXISTS kkd_execute_run(bigint);
DROP FUNCTION IF EXISTS kkd_start_run(varchar, date);
DROP FUNCTION IF EXISTS kkd_find_violations(date, varchar[]);
DROP FUNCTION IF EXISTS kkd_unit_scope(varchar);
DROP TABLE    IF EXISTS kkd_run_metric;
DROP TABLE    IF EXISTS kkd_issue;
DROP TABLE    IF EXISTS kkd_run;
DROP TABLE    IF EXISTS kkd_metric_def;
DROP TABLE    IF EXISTS kkd_rule;
