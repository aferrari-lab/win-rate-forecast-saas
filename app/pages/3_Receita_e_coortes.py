"""Receita contratada (novos x expansão), coortes e painel de KPIs SaaS."""
import plotly.graph_objects as go
import streamlit as st

from lib import tema
from lib.dados import cabecalho, q

cabecalho("Receita, coortes e KPIs",
          "Bookings do CRM: o que foi vendido, não o que é faturado. Acumulados supõem churn zero (teto).")

aba1, aba2, aba3 = st.tabs(["Receita contratada", "Coortes", "Painel de KPIs"])

with aba1:
    rec = q("SELECT * FROM an_receita_mensal WHERE mes >= DATE '2024-01-01' ORDER BY mes")
    rec["mrr_outros_exp"] = rec.mrr_expansao - rec.mrr_upsell - rec.mrr_cross_sell
    fig = go.Figure()
    for col, nome in [("mrr_novos_clientes", "Novo cliente"), ("mrr_upsell", "Upsell"),
                      ("mrr_cross_sell", "Cross-sell"), ("mrr_outros_exp", "Mesmo plano")]:
        fig.add_bar(x=rec.mes, y=rec[col], name=nome if nome != "Mesmo plano" else "Expansão: mesmo plano / inferior",
                    marker_color=tema.CORES_NEGOCIO[nome],
                    hovertemplate=f"%{{x|%b/%Y}}<br>{nome}: R$ %{{y:,.0f}}<extra></extra>")
    fig.update_layout(barmode="stack", title="MRR ganho por mês e tipo de negócio", yaxis_title="R$",
                      height=420, separators=",.", hovermode="x unified")
    st.plotly_chart(fig, width="stretch")

    mix = q("""SELECT tipo_negocio, tipo_expansao, count(*) AS ganhas, sum(mrr_valido) AS mrr
               FROM base_op WHERE ganha GROUP BY ALL ORDER BY mrr DESC""")
    mix["% do MRR"] = 100 * mix.mrr / mix.mrr.sum()
    mix["tipo_expansao"] = mix.tipo_expansao.replace("NA", "—")
    st.dataframe(tema.tabela(mix, {"ganhas": "int", "mrr": "brl", "% do MRR": "pct"},
                             {"tipo_negocio": "Tipo de negócio", "tipo_expansao": "Tipo de expansão",
                              "ganhas": "Ganhas", "mrr": "MRR"}),
                 hide_index=True, width="stretch")

with aba2:
    esq, dir_ = st.columns(2)
    cc = q("SELECT * FROM an_coorte_clientes WHERE coorte >= DATE '2024-01-01'")
    cc["coorte"] = cc.coorte.dt.to_period("Q").astype(str)
    hm = cc.pivot(index="coorte", columns="trimestre_relativo", values="expansao_pct").round(0) + 0.0
    fig = go.Figure(go.Heatmap(
        z=hm.values, x=hm.columns, y=hm.index, colorscale=[[i / 6, c] for i, c in enumerate(tema.SEQUENCIAL)],
        text=hm.values, texttemplate="%{text:.0f}", xgap=2, ygap=2, colorbar=dict(title="%"),
        hovertemplate="Coorte %{y}<br>%{x} trimestres depois<br>Expansão: %{z:.0f}%<extra></extra>"))
    fig.update_layout(title="Expansão da coorte de clientes (% sobre o MRR inicial)",
                      xaxis_title="trimestres após o 1º ganho", yaxis_autorange="reversed", height=460)
    esq.plotly_chart(fig, width="stretch")

    cp = q("""SELECT meses_desde_criacao, avg(pct_ganhas) AS ganhas, avg(pct_perdidas) AS perdidas,
                     avg(pct_fechadas) AS fechadas
              FROM an_coorte_pipeline GROUP BY 1 ORDER BY 1""")
    fig = go.Figure()
    for i, col in enumerate(["fechadas", "ganhas", "perdidas"]):
        fig.add_scatter(x=cp.meses_desde_criacao, y=cp[col], name=col.capitalize(), mode="lines+markers",
                        line=dict(width=2, color=tema.CATEGORICA[i]), marker=dict(size=8),
                        hovertemplate=f"{col}: %{{y:.1f}}%<extra></extra>")
    fig.update_layout(title="Curva de maturação do pipeline", xaxis_title="meses desde a criação",
                      yaxis_title="% das oportunidades", height=460, hovermode="x unified", separators=",.")
    dir_.plotly_chart(fig, width="stretch")

with aba3:
    k = q("SELECT kpi, valor, valor_ano_anterior, variacao, unid_variacao, natureza, nota FROM an_kpis ORDER BY ordem")
    kp = k.kpi
    em = lambda *t: kp.str.contains("|".join(t), regex=True)
    vezes = kp.eq("LTV/CAC")
    pct_ = em("Win rate", "Churn", "GRR", "NRR", "Margem", "Expansão sobre", "Logo churn")
    dias, meses = em("Ciclo"), em("Payback")
    reais = em("MRR", "ARR", "ARPA", "ARPU", "EBITDA", "CAC", "LTV") & ~pct_ & ~vezes
    inteiro = ~(vezes | pct_ | dias | meses | reais)
    st.dataframe(tema.tabela(
        k.drop(columns="unid_variacao"),
        rotulos={"kpi": "KPI", "valor": "Valor", "valor_ano_anterior": "Ano anterior", "variacao": "Variação",
                 "natureza": "Natureza", "nota": "Nota"},
        por_linha=[(pct_, ["valor", "valor_ano_anterior"], "pct"), (reais, ["valor", "valor_ano_anterior"], "brl"),
                   (dias, ["valor", "valor_ano_anterior"], "dias"), (meses, ["valor", "valor_ano_anterior"], "meses"),
                   (vezes, ["valor", "valor_ano_anterior"], "vezes"), (inteiro, ["valor", "valor_ano_anterior"], "int"),
                   (k.unid_variacao.eq("pp"), ["variacao"], "var_pp"), (k.unid_variacao.eq("%"), ["variacao"], "var_pct")]),
        hide_index=True, width="stretch", height=600)
    pend = q("SELECT chave, unidade, descricao, fonte_sugerida FROM an_premissas WHERE valor IS NULL")
    if len(pend):
        st.info(f"{len(pend)} premissas pendentes em `data/ref/premissas.csv`. Preencha e clique em "
                "**Atualizar dados** para calcular churn, NRR, GRR, CAC, LTV, payback, ARPU e EBITDA.")
        st.dataframe(tema.tabela(pend, rotulos={"chave": "Premissa", "unidade": "Unidade", "descricao": "Descrição",
                                                "fonte_sugerida": "Fonte sugerida"}),
                     hide_index=True, width="stretch")
