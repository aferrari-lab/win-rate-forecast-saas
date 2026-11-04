"""Pipeline completo: profiling -> tratamento (com QA) -> análise.

Uso (na raiz do projeto, com o .venv ativo):
    python src/winrate/pipeline.py

Gera/atualiza data/crm.duckdb com todas as tabelas que o dashboard lê
(raw_*, stg_*, achados, trt_*, qa_*, base_op, wr_*, an_*) e exporta a camada
tratada para data/processed/*.parquet. Se o QA do tratamento falhar, para antes
da análise e sai com código 1.
"""
import os
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "data" / "crm.duckdb"
ETAPAS = {
    "profiling": sorted((ROOT / "sql" / "profiling").glob("*.sql")),
    "tratamento": sorted((ROOT / "sql" / "tratamento").glob("*.sql")),
    "analise": sorted((ROOT / "sql" / "analise").glob("*.sql")),
}
TRT = ["trt_clientes", "trt_oportunidades", "trt_vendedores", "trt_historico_etapas"]


def main() -> int:
    os.chdir(ROOT)  # os .sql usam caminhos relativos à raiz
    con = duckdb.connect(str(DB))
    try:
        # Bancos antigos têm raw_* como VIEW; o 00_raw.sql agora cria TABLE, e o DuckDB
        # não troca view por tabela com CREATE OR REPLACE. Remove as views antes.
        for (nome,) in con.sql("SELECT view_name FROM duckdb_views() "
                               "WHERE NOT internal AND view_name LIKE 'raw\\_%' ESCAPE '\\'").fetchall():
            con.sql(f'DROP VIEW "{nome}"')
        for etapa, arquivos in ETAPAS.items():
            for arq in arquivos:
                print(f"> {arq.relative_to(ROOT).as_posix()}")
                con.execute(arq.read_text(encoding="utf-8"))
            if etapa == "tratamento":
                falhas = con.execute("SELECT count(*) FROM qa_tratamento WHERE resultado <> 'OK'").fetchone()[0]
                if falhas:
                    con.sql("FROM qa_tratamento WHERE resultado <> 'OK'").show(max_width=200)
                    print(f"{falhas} teste(s) de QA falharam: pipeline interrompido.")
                    return 1
                destino = ROOT / "data" / "processed"
                destino.mkdir(parents=True, exist_ok=True)
                for t in TRT:
                    con.execute(f"COPY {t} TO '{(destino / (t[4:] + '.parquet')).as_posix()}' (FORMAT parquet)")
        print("Pipeline concluído. Data de referência:", con.execute("FROM an_param").fetchone()[0])
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
