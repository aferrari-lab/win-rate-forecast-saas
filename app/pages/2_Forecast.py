"""Forecast do pipeline aberto: taxa única (como é hoje) x taxa por canal x setor.

Método recomendado:
  * taxas calibradas nas oportunidades fechadas nos últimos N trimestres;
  * taxa por canal x setor com shrinkage para a média (grupos pequenos não
    geram taxas extremas);
  * para receita, taxa PONDERADA POR MRR (negócios grandes ganham menos).
"""
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

from lib import tema
from lib.dados import cabecalho, data_ref, q

cabecalho("Forecast do pipeline", "Quanto do pipeline aberto deve virar receita, por método de taxa")

with st.sidebar:
    st.subheader("Parâmetros")
    idade_max = st.slider("Idade máxima da oportunidade (dias)", 30, 720, 120, step=30,
                          help="95% das oportunidades fecham em até 4 meses. As mais antigas que seguem "
                               "abertas dificilmente convertem e inflam o forecast.")
    trimestres = st.slider("Calibrar taxas com os últimos N trimestres", 2, 8, 4)
    k_qtd = st.number_input("Shrinkage (qtd): peso da média, em oportunidades", 0, 500, 30, step=10)
    k_mrr = st.number_input("Shrinkage (MRR): peso da média, em R$", 0, 500_000, 30_000, step=10_000)
    st.subheader("Filtro")
    vend = q("SELECT id_vendedor, nome_vendedor, time_vendas, ativo FROM trt_vendedores ORDER BY nome_vendedor")
    rotulos = {r.id_vendedor: f"{r.nome_vendedor} · {r.time_vendas}" + (" (desligado)" if r.ativo == "N" else "")
               for r in vend.itertuples()}
    vend_sel = st.multiselect("Vendedor", list(rotulos), format_func=rotulos.get, placeholder="Todos",
                              help="Filtra o pipeline aberto. As taxas continuam calibradas com toda a base, "
                                   "para que o forecast de um vendedor não dependa só do histórico dele.")

ref = data_ref()
base = q("SELECT * FROM base_op")
inicio_cal = (ref.to_period("Q") - trimestres + 1).start_time
cal = base[base.fechada & (pd.to_datetime(base.data_fechamento) >= inicio_cal)]
abertas = base[base.status == "Aberta"].copy()
if vend_sel:
    abertas = abertas[abertas.id_vendedor.isin(vend_sel)]
abertas["idade_dias"] = (ref - pd.to_datetime(abertas.data_criacao)).dt.days
ativas, velhas = abertas[abertas.idade_dias <= idade_max].copy(), abertas[abertas.idade_dias > idade_max]

# ---- taxas -----------------------------------------------------------------
CH = ["canal", "setor"]
p_qtd = cal.ganha.mean()
cm = cal.dropna(subset=["mrr_valido"])
p_mrr = (cm.ganha * cm.mrr_valido).sum() / cm.mrr_valido.sum()
g = cal.groupby(CH).agg(ganhas=("ganha", "sum"), n=("ganha", "size")).reset_index()
g["taxa_qtd"] = (g.ganhas + k_qtd * p_qtd) / (g.n + k_qtd)
gm = cm.assign(w=cm.ganha * cm.mrr_valido).groupby(CH).agg(w=("w", "sum"), m=("mrr_valido", "sum")).reset_index()
gm["taxa_mrr"] = (gm.w + k_mrr * p_mrr) / (gm.m + k_mrr)

ativas = ativas.merge(g[CH + ["taxa_qtd"]], on=CH, how="left").merge(gm[CH + ["taxa_mrr"]], on=CH, how="left")
ativas = ativas.fillna({"taxa_qtd": p_qtd, "taxa_mrr": p_mrr, "mrr_valido": 0})
ativas["mrr_unica"] = p_qtd * ativas.mrr_valido
ativas["mrr_segmentada"] = ativas.taxa_mrr * ativas.mrr_valido
ativas["mrr_crm"] = ativas.probabilidade_crm / 100 * ativas.mrr_valido

# ---- resumo ----------------------------------------------------------------
c = st.columns(4)
c[0].metric("Pipeline considerado", f"{tema.num(len(ativas))} oport.", help=f"Abertas com até {idade_max} dias")
c[1].metric("MRR do pipeline", tema.brl_curto(ativas.mrr_valido.sum()))
c[2].metric("MRR esperado (taxa única)", tema.brl_curto(ativas.mrr_unica.sum()),
            help=f"Taxa única por quantidade: {tema.pct(100 * p_qtd)} aplicada ao MRR (método atual)")
c[3].metric("MRR esperado (canal x setor)", tema.brl_curto(ativas.mrr_segmentada.sum()),
            f"{(ativas.mrr_segmentada.sum() / ativas.mrr_unica.sum() - 1) * 100:+.1f}% vs taxa única".replace(".", ","),
            delta_color="off", help="Taxa ponderada por MRR, por canal x setor (método recomendado)")
if len(velhas):
    st.warning(f"**{tema.num(len(velhas))} oportunidades abertas há mais de {idade_max} dias** "
               f"({tema.brl_curto(velhas.mrr_valido.sum())} de MRR) ficaram fora do forecast. "
               "Vale pedir ao time para encerrá-las no CRM.")

resumo = pd.DataFrame({
    "Método": ["Taxa única por quantidade (hoje)", "Taxa única por MRR", "Canal x setor por MRR (recomendado)",
               "Probabilidade da etapa no CRM"],
    # taxa por MRR mede valor, não quantidade: ganhos esperados vêm da taxa por qtd do mesmo recorte
    "Ganhos esperados": [p_qtd * len(ativas), None, ativas.taxa_qtd.sum(), ativas.probabilidade_crm.sum() / 100],
    "MRR esperado": [ativas.mrr_unica.sum(), p_mrr * ativas.mrr_valido.sum(), ativas.mrr_segmentada.sum(), ativas.mrr_crm.sum()],
})
resumo["ARR esperado"] = resumo["MRR esperado"] * 12
st.dataframe(tema.tabela(resumo, {"Ganhos esperados": "int", "MRR esperado": "brl", "ARR esperado": "brl"}),
             hide_index=True, width="stretch")
st.caption(f"Taxas calibradas com {tema.num(len(cal))} oportunidades fechadas desde {inicio_cal:%d/%m/%Y}. "
           "Canal e setor são os recortes com as maiores diferenças de win rate, e a taxa por MRR corrige o fato de "
           "negócios grandes converterem menos. Valide o método num piloto, comparando previsto e realizado.")

# ---- por canal -------------------------------------------------------------
pc = ativas.groupby("canal")[["mrr_valido", "mrr_unica", "mrr_segmentada"]].sum().reset_index()
fig = go.Figure()
fig.add_bar(x=pc.canal, y=pc.mrr_unica, name="Taxa única (hoje)", marker_color=tema.CATEGORICA[0],
            hovertemplate="%{x}<br>Taxa única: R$ %{y:,.0f}<extra></extra>")
fig.add_bar(x=pc.canal, y=pc.mrr_segmentada, name="Canal x setor por MRR", marker_color=tema.CATEGORICA[1],
            hovertemplate="%{x}<br>Canal x setor: R$ %{y:,.0f}<extra></extra>")
fig.update_layout(barmode="group", title="MRR esperado por canal", yaxis_title="R$", height=400, separators=",.")
st.plotly_chart(fig, width="stretch")

st.subheader("Por vendedor")
pv = (ativas.groupby(["nome_vendedor", "time_vendas"])
      .agg(oportunidades=("id_oportunidade", "size"), mrr_pipeline=("mrr_valido", "sum"),
           mrr_taxa_unica=("mrr_unica", "sum"), mrr_canal_setor=("mrr_segmentada", "sum"))
      .reset_index().sort_values("mrr_canal_setor", ascending=False))
pv["diferenca_%"] = 100 * (pv.mrr_canal_setor / pv.mrr_taxa_unica - 1)
st.dataframe(tema.tabela(pv, {"oportunidades": "int", "mrr_pipeline": "brl", "mrr_taxa_unica": "brl",
                              "mrr_canal_setor": "brl", "diferenca_%": "var_pct"},
                         {"nome_vendedor": "Vendedor", "time_vendas": "Time", "oportunidades": "Oportunidades",
                          "mrr_pipeline": "MRR do pipeline", "mrr_taxa_unica": "MRR esperado (taxa única)",
                          "mrr_canal_setor": "MRR esperado (canal x setor)", "diferenca_%": "Diferença"}),
             hide_index=True, width="stretch", height=320)
st.caption("Diferença = quanto o método recomendado muda a projeção de cada vendedor em relação à taxa única. "
           "Negativo = a taxa única superestimava o pipeline dele (mix com mais Outbound, setores de menor conversão "
           "ou tickets maiores).")

st.subheader("Taxas usadas")
tx = g.merge(gm[CH + ["taxa_mrr"]], on=CH, how="outer")
tx = tx.assign(taxa_qtd=100 * tx.taxa_qtd, taxa_mrr=100 * tx.taxa_mrr).sort_values(["canal", "taxa_mrr"], ascending=[True, False])
st.dataframe(tema.tabela(tx, {"ganhas": "int", "n": "int", "taxa_qtd": "pct", "taxa_mrr": "pct"},
                         {"canal": "Canal", "setor": "Setor", "ganhas": "Ganhas", "n": "Fechadas",
                          "taxa_qtd": "Taxa por quantidade", "taxa_mrr": "Taxa por MRR"}),
             hide_index=True, width="stretch", height=300)

with st.expander("Oportunidades do pipeline (exportável)"):
    cols = ["id_oportunidade", "nome_vendedor", "canal", "setor", "segmento_crm", "plano", "etapa_atual", "idade_dias",
            "mrr_valido", "probabilidade_crm", "taxa_mrr", "mrr_segmentada"]
    tab = ativas[cols].sort_values("mrr_segmentada", ascending=False)
    st.dataframe(tema.tabela(tab.assign(taxa_mrr=100 * tab.taxa_mrr),
                             {"idade_dias": "int", "mrr_valido": "brl2", "probabilidade_crm": "pct",
                              "taxa_mrr": "pct", "mrr_segmentada": "brl2"},
                             {"id_oportunidade": "Oportunidade", "nome_vendedor": "Vendedor", "canal": "Canal",
                              "setor": "Setor", "segmento_crm": "Segmento", "plano": "Plano", "etapa_atual": "Etapa",
                              "idade_dias": "Idade (dias)", "mrr_valido": "MRR", "probabilidade_crm": "Prob. CRM",
                              "taxa_mrr": "Taxa aplicada", "mrr_segmentada": "MRR esperado"}),
                 hide_index=True, width="stretch")
    st.download_button("Baixar CSV", tab.to_csv(index=False, sep=";", decimal=",").encode("utf-8-sig"),
                       "forecast_pipeline.csv", "text/csv")

# Próximo passo sugerido: distribuir o MRR esperado por mês usando a curva de
# maturação (tabela an_coorte_pipeline) condicionada à idade de cada oportunidade.
