"""Acesso aos dados do dashboard.

Lê data/crm.duckdb em modo somente leitura. Cada consulta abre e fecha a
conexão (o arquivo fica livre para o pipeline gravar - importante no Windows)
e o resultado fica em cache até alguém clicar em "Atualizar dados".
"""
import os
import subprocess
import sys
from pathlib import Path

import duckdb
import pandas as pd
import streamlit as st

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "data" / "crm.duckdb"
PIPELINE = ROOT / "src" / "winrate" / "pipeline.py"


@st.cache_data(show_spinner=False)
def q(sql: str, params: tuple | None = None) -> pd.DataFrame:
    with duckdb.connect(str(DB), read_only=True) as con:
        return con.execute(sql, list(params) if params else None).df()


def banco_pronto() -> bool:
    if not DB.exists():
        return False
    try:
        with duckdb.connect(str(DB), read_only=True) as con:
            tabelas = con.execute(
                "SELECT count(*) FROM information_schema.tables WHERE table_name IN ('base_op', 'an_kpis')"
            ).fetchone()[0]
            # coluna mais recente da base analítica: sem ela, o banco é de uma versão anterior do pipeline
            coluna = con.execute(
                "SELECT count(*) FROM information_schema.columns WHERE table_name = 'base_op' AND column_name = 'nome_vendedor'"
            ).fetchone()[0]
            return tabelas == 2 and coluna == 1
    except duckdb.Error:
        return False


def rodar_pipeline() -> tuple[bool, str]:
    st.cache_data.clear()
    # No Windows o processo filho escreve em cp1252 por padrão: força UTF-8 nele e
    # tolera bytes inválidos na leitura (sem isso a saída volta None e o app quebra)
    env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}
    r = subprocess.run([sys.executable, str(PIPELINE)], cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace", env=env)
    return r.returncode == 0, ((r.stdout or "") + (r.stderr or ""))[-3000:]


def cabecalho(titulo: str, subtitulo: str | None = None) -> None:
    """Configuração comum de cada página + barra lateral com atualização."""
    st.set_page_config(page_title=f"Win Rate Analytics · {titulo}", layout="wide")
    with st.sidebar:
        st.markdown("<div style='font-weight:700;font-size:1.15rem;color:#29354d;line-height:1.2'>Win Rate Analytics</div>"
                    "<div style='font-size:.8rem;color:#70757f;margin-bottom:.5rem'>Inteligência Comercial · SaaS B2B</div>",
                    unsafe_allow_html=True)
        if st.button("Atualizar dados", help="Roda o pipeline SQL completo (profiling, tratamento, análise)"):
            with st.spinner("Rodando pipeline..."):
                ok, log = rodar_pipeline()
            (st.success if ok else st.error)("Dados atualizados." if ok else "Pipeline falhou.")
            if not ok:
                st.code(log)
    if not banco_pronto():
        st.title(titulo)
        st.warning("Banco de dados ausente ou desatualizado. Clique em **Atualizar dados** na barra lateral "
                   "ou rode `python src/winrate/pipeline.py` na raiz do projeto.")
        st.stop()
    ref = q("SELECT data_ref FROM an_param").iat[0, 0]
    st.sidebar.caption(f"Dados até **{pd.Timestamp(ref):%d/%m/%Y}**")
    st.title(titulo)
    if subtitulo:
        st.caption(subtitulo)


def data_ref() -> pd.Timestamp:
    return pd.Timestamp(q("SELECT data_ref FROM an_param").iat[0, 0])


def opcoes(coluna: str) -> list[str]:
    return q(f"SELECT DISTINCT {coluna} AS v FROM base_op ORDER BY 1")["v"].tolist()
