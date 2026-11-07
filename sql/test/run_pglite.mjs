// Прогон SQL на настоящем PostgreSQL без установки сервера: PGlite = PostgreSQL, собранный в WebAssembly.
//   npm install --no-save @electric-sql/pglite
//   node sql/test/run_pglite.mjs
// Шаги: накат -> откат -> повторный накат (как в приёмке БТ), тестовые данные, сценарий с ASSERT, финальный откат.
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const mod = process.env.PGLITE_MODULE ? pathToFileURL(process.env.PGLITE_MODULE).href : '@electric-sql/pglite';
const { PGlite } = await import(mod);

const sqlDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (name) => readFileSync(join(sqlDir, name), 'utf8');

const db = new PGlite();
let notices = 0;
const run = async (name) => {
  await db.exec(read(name), { onNotice: (n) => { if (String(n.message).startsWith('ok')) { notices++; console.log('  ' + n.message); } } });
  console.log(`[ok] ${name}`);
};
const scalar = async (sql) => Object.values((await db.query(sql)).rows[0])[0];

console.log((await db.query('select version()')).rows[0].version);
await run('00_source_tables.sql');
await run('01_kkd_schema.sql');
await run('02_kkd_logic.sql');
await run('99_kkd_rollback.sql');          // откат
await run('01_kkd_schema.sql');            // повторный накат
await run('02_kkd_logic.sql');
await run('03_kkd_api_queries.sql');
await run('test/10_test_data.sql');
await run('test/20_test_scenario.sql');
console.log(`checks passed: ${notices}`);

await run('99_kkd_rollback.sql');          // финальный откат при наличии данных
const left = await scalar(`select count(*) from pg_class where relname like 'kkd%'`)
  + await scalar(`select count(*) from pg_proc where proname like 'kkd%'`);
const goals = await scalar('select count(*) from goal');
if (Number(left) !== 0 || Number(goals) === 0) throw new Error(`rollback check failed: kkd objects=${left}, goals=${goals}`);
console.log(`[ok] rollback: kkd objects left = 0, source goals kept = ${goals}`);
