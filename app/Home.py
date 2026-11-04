"""Visão geral: KPIs do período x mesmo período do ano anterior.

Rodar na raiz do projeto:
    streamlit run app/Home.py
"""
import plotly.graph_objects as go
import streamlit as st

from lib import tema
from lib.dados import cabecalho, q

cabecalho("Visão geral comercial", "Resultado do período comparado com a mesma janela do ano anterior")

periodo = st.segmented_control("Período", ["MTD", "QTD", "YTD", "Últimos 12 meses"], default="YTD")
m = q("SELECT * FROM an_periodos_metricas WHERE periodo = ?", (periodo,)).set_index("janela")
atual, ant = m.loc["atual"], m.loc["ano anterior"]
st.caption(f"{atual.ini:%d/%m/%Y} a {atual.fim:%d/%m/%Y}  ·  comparado com {ant.ini:%d/%m/%Y} a {ant.fim:%d/%m/%Y}")


def delta_pct(a, b):
    return None if not b else f"{(a / b - 1) * 100:+.1f}%".replace(".", ",")


def delta_pp(a, b):
    return None if b is None else f"{a - b:+.1f} pp".replace(".", ",")


c = st.columns(4)
c[0].metric("Win rate", tema.pct(atual.win_rate), delta_pp(atual.win_rate, ant.win_rate),
            help="Ganhas / (ganhas + perdidas), por data de fechamento")
c[1].metric("Win rate por MRR", tema.pct(atual.win_rate_mrr), delta_pp(atual.win_rate_mrr, ant.win_rate_mrr),
            help="MRR ganho / MRR fechado. É a taxa a usar para projetar receita")
c[2].metric("MRR ganho", tema.brl_curto(atual.mrr_ganho), delta_pct(atual.mrr_ganho, ant.mrr_ganho))
c[3].metric("ARR novo contratado", tema.brl_curto(atual.arr_ganho), delta_pct(atual.arr_ganho, ant.arr_ganho),
            help="MRR ganho x 12 (bookings, não faturamento)")
c = st.columns(4)
c[0].metric("Novos clientes", tema.num(atual.novos_clientes), delta_pct(atual.novos_clientes, ant.novos_clientes))
c[1].metric("MRR de novos clientes", tema.brl_curto(atual.mrr_novos_clientes),
            delta_pct(atual.mrr_novos_clientes, ant.mrr_novos_clientes))
c[2].metric("MRR de expansão", tema.brl_curto(atual.mrr_expansao), delta_pct(atual.mrr_expansao, ant.mrr_expansao),
            help="Upsell + cross-sell + recompra em clientes da base")
c[3].metric("Ciclo médio (ganhas)", f"{tema.num(atual.ciclo_medio_ganhas_dias)} dias",
            delta_pct(atual.ciclo_medio_ganhas_dias, ant.ciclo_medio_ganhas_dias), delta_color="inverse")

st.divider()
esq, dir_ = st.columns(2)

rec = q("SELECT * FROM an_receita_mensal WHERE mes >= DATE '2024-01-01' ORDER BY mes")
fig = go.Figure()
fig.add_bar(x=rec.mes, y=rec.mrr_novos_clientes, name="Novos clientes", marker_color=tema.CORES_NEGOCIO["Novo cliente"],
            hovertemplate="%{x|%b/%Y}<br>Novos clientes: R$ %{y:,.0f}<extra></extra>")
fig.add_bar(x=rec.mes, y=rec.mrr_expansao, name="Expansão", marker_color=tema.CORES_NEGOCIO["Expansão"],
            hovertemplate="%{x|%b/%Y}<br>Expansão: R$ %{y:,.0f}<extra></extra>")
fig.update_layout(barmode="stack", title="MRR ganho por mês", yaxis_title="R$", height=380,
                  separators=",.", hovermode="x unified")
esq.plotly_chart(fig, width="stretch")

wr = q("SELECT * FROM wr_mensal WHERE mes >= DATE '2024-01-01' ORDER BY mes")
glob = q("SELECT 100 * win_rate AS wr, 100 * win_rate_mrr AS wr_mrr FROM wr_global").iloc[0]
fig = go.Figure()
fig.add_scatter(x=wr.mes, y=wr.win_rate, name="Por quantidade", mode="lines+markers", line=dict(width=2),
                marker=dict(size=8), line_color=tema.CATEGORICA[0])
fig.add_scatter(x=wr.mes, y=wr.win_rate_mrr, name="Por MRR", mode="lines+markers", line=dict(width=2),
                marker=dict(size=8), line_color=tema.CATEGORICA[1])
fig.add_hline(y=glob.wr, line_dash="dot", line_color=tema.MUTED,
              annotation_text=f"taxa única {tema.pct(glob.wr)}", annotation_position="top left", annotation_font_color=tema.TEXTO_2)
fig.update_layout(title="Win rate mensal (%)", yaxis_title="%", height=380, separators=",.", hovermode="x unified")
fig.update_traces(hovertemplate="%{y:.1f}%")
dir_.plotly_chart(fig, width="stretch")

with st.expander("Ver tabela do comparativo"):
    comp = q("SELECT metrica, atual, ano_anterior, var_pp, var_pct FROM an_periodos_comparativo WHERE periodo = ?",
             (periodo,))
    NOMES = {"oportunidades_criadas": "Oportunidades criadas", "oportunidades_fechadas": "Oportunidades fechadas",
             "oportunidades_ganhas": "Oportunidades ganhas", "win_rate": "Win rate", "win_rate_mrr": "Win rate por MRR",
             "novos_clientes": "Novos clientes", "mrr_ganho": "MRR ganho", "mrr_novos_clientes": "MRR de novos clientes",
             "mrr_expansao": "MRR de expansão", "mrr_upsell": "MRR de upsell", "mrr_cross_sell": "MRR de cross-sell",
             "arr_ganho": "ARR novo contratado", "arpa_novos_clientes": "ARPA de novos clientes",
             "ciclo_medio_ganhas_dias": "Ciclo médio (ganhas)"}
    m = comp.metrica
    taxa, dias = m.str.startswith("win_rate"), m.eq("ciclo_medio_ganhas_dias")
    reais = m.str.startswith(("mrr", "arr", "arpa"))
    comp["metrica"] = m.map(NOMES).fillna(m)
    comp["variacao"] = comp.var_pp.fillna(comp.var_pct)
    st.dataframe(tema.tabela(
        comp[["metrica", "atual", "ano_anterior", "variacao"]],
        rotulos={"metrica": "Métrica", "atual": "Atual", "ano_anterior": "Ano anterior", "variacao": "Variação"},
        por_linha=[(taxa, ["atual", "ano_anterior"], "pct"), (taxa, ["variacao"], "var_pp"),
                   (reais, ["atual", "ano_anterior"], "brl"), (dias, ["atual", "ano_anterior"], "dias"),
                   (~(taxa | reais | dias), ["atual", "ano_anterior"], "int"), (~taxa, ["variacao"], "var_pct")]),
        hide_index=True, width="stretch")
