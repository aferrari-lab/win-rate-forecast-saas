"""Executa o tratamento em SQL (DuckDB) e grava a camada tratada em Parquet.

Uso (na raiz do projeto, com o .venv ativo):
    python src/winrate/tratamento_sql.py

Ordem: camadas raw/staging do profiling -> sql/tratamento/*.sql -> QA ->
exporta trt_* para data/processed/*.parquet. Se algum teste de QA falhar,
nada é exportado.
"""
import os
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "data" / "crm.duckdb"
ARQUIVOS = [
    ROOT / "sql" / "profiling" / "00_raw.sql",
    ROOT / "sql" / "profiling" / "01_staging.sql",
    *sorted((ROOT / "sql" / "tratamento").glob("*.sql")),
]
TABELAS = ["trt_clientes", "trt_oportunidades", "trt_vendedores", "trt_historico_etapas"]


def main() -> int:
    os.chdir(ROOT)  # os .sql usam caminhos relativos à raiz
    con = duckdb.connect(str(DB))
    for arq in ARQUIVOS:
        print(f"> {arq.relative_to(ROOT).as_posix()}")
        con.execute(arq.read_text(encoding="utf-8"))

    print()
    con.sql("FROM qa_tratamento").show(max_width=200)
    nao_mapeados = con.sql("FROM qa_nao_mapeados")
    if con.execute("SELECT count(*) FROM qa_nao_mapeados").fetchone()[0]:
        print("Valores sem de-para (incluir em data/ref/de_para.csv):")
        nao_mapeados.show()

    falhas = con.execute("SELECT count(*) FROM qa_tratamento WHERE resultado <> 'OK'").fetchone()[0]
    if falhas:
        print(f"{falhas} teste(s) de QA falharam: Parquet NÃO exportado.")
        return 1

    destino = ROOT / "data" / "processed"
    destino.mkdir(parents=True, exist_ok=True)
    for t in TABELAS:
        arq = destino / f"{t.removeprefix('trt_')}.parquet"
        con.execute(f"COPY {t} TO '{arq.as_posix()}' (FORMAT parquet)")
        print(f"{t:<22} -> {arq.relative_to(ROOT).as_posix()}")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
