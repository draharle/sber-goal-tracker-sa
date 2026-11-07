"""Проверка: каждый блок ```sql из docs/SA_KKD_spec.md дословно есть в файлах sql/*.sql.
Запуск из корня репозитория: python sql/test/check_spec_sql.py"""
import pathlib, re, sys
sys.stdout.reconfigure(encoding="utf-8")

root = pathlib.Path(__file__).resolve().parents[2]
spec = (root / 'docs' / 'SA_KKD_spec.md').read_text(encoding='utf-8')
sources = '\n'.join(p.read_text(encoding='utf-8') for p in sorted((root / 'sql').glob('*.sql')))
blocks = re.findall(r'```sql\n(.*?)\n```', spec, flags=re.S)
missing = [b.splitlines()[0] for b in blocks if b not in sources]
print(f'SQL-блоков в спецификации: {len(blocks)}, не найдено в sql/: {len(missing)}')
for first_line in missing:
    print('  нет в sql/:', first_line)
sys.exit(1 if missing or not blocks else 0)
