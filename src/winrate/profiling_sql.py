"""Executa o profiling em SQL (DuckDB).

Uso (na raiz do projeto, com o .venv ativo):
    python src/winrate/profiling_sql.py

Roda sql/profiling/*.sql em ordem num banco DuckDB persistente
(data/crm.duckdb), imprime os achados e exporta para reports/.
O banco pode ser aberto depois no DBeaver ou no CLI do DuckDB para explorar.
"""
import os
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = ROOT / "sql" / "profiling"
DB = ROOT / "data" / "crm.duckdb"
SAIDA = ROOT / "reports" / "01_profiling_sql_achados.csv"


def main() -> None:
    os.chdir(ROOT)  # os .sql usam caminhos relativos à raiz
    con = duckdb.connect(str(DB))
    for arq in sorted(SQL_DIR.glob("*.sql")):
        print(f"> {arq.name}")
        con.execute(arq.read_text(encoding="utf-8"))

    print()
    con.sql("FROM perfil_tabelas").show()
    con.sql("""
        SELECT severidade, count(*) AS checks, sum(linhas_afetadas) AS linhas
        FROM achados GROUP BY ALL ORDER BY min(CASE severidade WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END)
    """).show()
    con.sql("FROM achados").show(max_rows=100, max_width=200)
    con.sql("FROM wr_bruto WHERE dimensao IN ('TOTAL', 'segmento_crm', 'time')").show()

    SAIDA.parent.mkdir(parents=True, exist_ok=True)
    con.execute(f"COPY achados TO '{SAIDA.as_posix()}' (HEADER, DELIMITER ',')")
    print(f"Achados exportados para {SAIDA.relative_to(ROOT)}")
    con.close()


if __name__ == "__main__":
    main()
