"""Filtros da barra lateral, compartilhados entre as páginas.

Devolvem um trecho WHERE parametrizado (sem concatenar valores do usuário
no SQL) para aplicar em base_op.
"""
import datetime as dt

import pandas as pd
import streamlit as st

from lib.dados import data_ref, opcoes, q

DIMENSOES = {
    "canal": "Canal", "setor": "Setor", "segmento_crm": "Segmento", "porte_receita": "Porte (receita)",
    "plano": "Plano", "time_vendas": "Time de vendas", "nome_vendedor": "Vendedor", "faixa_mrr": "Faixa de MRR",
    "tipo_negocio": "Novo cliente x Expansão", "origem": "Origem", "uf": "UF",
}


def filtros_base(periodo: bool = True, chave: str = "f") -> tuple[str, list]:
    """Período de fechamento + canal/segmento/setor/vendedor. Retorna (sql_where, params)."""
    st.sidebar.subheader("Filtros")
    conds, params = [], []
    if periodo:
        lim = pd.Timestamp(q("SELECT min(data_fechamento) AS ini FROM base_op").iat[0, 0]).date()
        fim = data_ref().date()
        # padrão = base inteira, para os números baterem com a apresentação
        padrao = (lim, fim)
        intervalo = st.sidebar.date_input("Fechamento entre", padrao, min_value=lim, max_value=fim,
                                          format="DD/MM/YYYY", key=f"{chave}_per")
        if isinstance(intervalo, tuple) and len(intervalo) == 2:
            if tuple(intervalo) == padrao:
                # base inteira: inclui as 2 fechadas sem data de fechamento, como na apresentação
                conds.append("(data_fechamento BETWEEN ? AND ? OR data_fechamento IS NULL)")
            else:
                conds.append("data_fechamento BETWEEN ? AND ?")
            params += list(intervalo)
    for col, rotulo in [("canal", "Canal"), ("segmento_crm", "Segmento"), ("setor", "Setor")]:
        sel = st.sidebar.multiselect(rotulo, opcoes(col), key=f"{chave}_{col}", placeholder="Todos")
        if sel:
            conds.append(f"{col} IN ({', '.join('?' * len(sel))})")
            params += sel
    # Vendedor = dono da oportunidade (id_vendedor). A lista mostra nome, time e
    # se foi desligado; o filtro usa o id, então dois vendedores com o mesmo
    # nome nunca se misturam.
    vend = q("SELECT id_vendedor, nome_vendedor, time_vendas, ativo FROM trt_vendedores ORDER BY nome_vendedor")
    rotulos = {r.id_vendedor: f"{r.nome_vendedor} · {r.time_vendas}" + (" (desligado)" if r.ativo == "N" else "")
               for r in vend.itertuples()}
    sel = st.sidebar.multiselect("Vendedor", list(rotulos), format_func=rotulos.get,
                                 key=f"{chave}_vendedor", placeholder="Todos")
    if sel:
        conds.append(f"id_vendedor IN ({', '.join('?' * len(sel))})")
        params += sel
    return (" AND ".join(conds) or "TRUE"), params
