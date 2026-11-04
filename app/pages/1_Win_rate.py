"""Win rate por dimensão, com IC 95% e evolução no tempo."""
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

from lib import tema
from lib.dados import cabecalho, data_ref, q
from lib.estatistica import projecao_wilson
from lib.filtros import DIMENSOES, filtros_base

cabecalho("Win rate", "Taxa de ganho por grupo, com intervalo de confiança de 95% (Wilson)")
where, params = filtros_base(chave="wr")

dim = st.selectbox("Abrir por", list(DIMENSOES), format_func=DIMENSOES.get)
min_n = st.slider("Mínimo de oportunidades fechadas por grupo", 10, 300, 30, step=10)

# dim vem de uma lista fixa (DIMENSOES), então pode ir no SQL; valores do usuário vão como parâmetro
SQL = f"""
WITH f AS (SELECT * FROM base_op WHERE fechada AND {where}),
g AS (SELECT avg(ganha::INT) AS p FROM f)
SELECT {dim} AS grupo, count(*) AS fechadas, count(*) FILTER (WHERE ganha) AS ganhas,
       100.0 * avg(ganha::INT) AS win_rate,
       100 * wilson_inf(count(*) FILTER (WHERE ganha)::DOUBLE, count(*)) AS ic_inf,
       100 * wilson_sup(count(*) FILTER (WHERE ganha)::DOUBLE, count(*)) AS ic_sup,
       100.0 * sum(mrr_valido) FILTER (WHERE ganha) / sum(mrr_valido) AS win_rate_mrr,
       100 * any_value(g.p) AS global
FROM f, g GROUP BY 1 HAVING count(*) >= ? ORDER BY win_rate
"""
d = q(SQL, tuple(params) + (min_n,))
if d.empty:
    st.info("Nenhum grupo com o volume mínimo nesse filtro.")
    st.stop()
glob = d["global"].iat[0]

d["cor"] = [tema.BOM if lo > glob else tema.RUIM if hi < glob else tema.MUTED for lo, hi in zip(d.ic_inf, d.ic_sup)]
d["leitura"] = d.cor.map({tema.BOM: "acima da média", tema.RUIM: "abaixo da média", tema.MUTED: "igual à média (dentro do IC)"})
fig = go.Figure(go.Scatter(
    x=d.win_rate, y=d.grupo, mode="markers",
    marker=dict(size=11, color=d.cor, line=dict(width=2, color=tema.SUPERFICIE)),
    error_x=dict(type="data", symmetric=False, array=d.ic_sup - d.win_rate, arrayminus=d.win_rate - d.ic_inf,
                 color=tema.EIXO, thickness=2, width=4),
    customdata=d[["fechadas", "ganhas", "ic_inf", "ic_sup", "leitura"]],
    hovertemplate="<b>%{y}</b><br>Win rate: %{x:.1f}%<br>IC 95%: %{customdata[2]:.1f}% a %{customdata[3]:.1f}%"
                  "<br>%{customdata[1]} ganhas de %{customdata[0]}<br>%{customdata[4]}<extra></extra>",
))
fig.add_vline(x=glob, line_dash="dot", line_color=tema.TEXTO_2,
              annotation_text=f"média do filtro {tema.pct(glob)}", annotation_position="top")
fig.update_layout(title=f"Win rate por {DIMENSOES[dim].lower()} (%)", xaxis_title="win rate (%)",
                  height=max(320, 42 * len(d) + 120), separators=",.")
st.plotly_chart(fig, width="stretch")
st.caption("Verde = acima da média com 95% de confiança · vermelho = abaixo · cinza = diferença dentro da margem de erro.")
if dim == "nome_vendedor":
    st.info("Compare vendedores do **mesmo time**: ENT, SMB Inbound e SMB Outbound trabalham canais e segmentos "
            "com taxas muito diferentes, então a diferença entre times não mede desempenho individual. "
            "Use o filtro de canal ou de segmento para comparar em condições parecidas.")

st.subheader("Evolução trimestral")
top = d.sort_values("fechadas", ascending=False).grupo.head(len(tema.CATEGORICA)).tolist()
evo = q(f"""
    SELECT date_trunc('quarter', data_fechamento) AS trimestre, {dim} AS grupo,
           count(*) AS fechadas, 100.0 * avg(ganha::INT) AS win_rate
    FROM base_op WHERE fechada AND {where} GROUP BY ALL ORDER BY 1""", tuple(params))
evo = evo[evo.grupo.isin(top)]
cores = tema.CORES_CANAL if dim == "canal" else dict(zip(sorted(top), tema.CATEGORICA))
fig = go.Figure()
for g in sorted(top):
    s = evo[evo.grupo == g]
    fig.add_scatter(x=s.trimestre, y=s.win_rate, name=g, mode="lines+markers",
                    line=dict(width=2, color=cores.get(g)), marker=dict(size=8),
                    customdata=s.fechadas, hovertemplate=f"{g}: %{{y:.1f}}% (n=%{{customdata}})<extra></extra>")
fig.update_layout(yaxis_title="win rate (%)", height=380, hovermode="x unified", separators=",.")
st.plotly_chart(fig, width="stretch")
if len(d) > len(top):
    st.caption(f"Mostrando os {len(top)} grupos de maior volume.")


# ---- Projeção do win rate com intervalo de Wilson (95%) ----
st.subheader("Projeção do win rate")
MESES = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
ref = data_ref()
hist = q(f"""
    SELECT count(*) AS oportunidades, count(*) FILTER (WHERE ganha) AS vendas,
           count(*) FILTER (WHERE data_fechamento > ?::DATE - INTERVAL 6 MONTH) AS fechadas_6m
    FROM base_op WHERE fechada AND data_fechamento IS NOT NULL AND {where}""", (ref.date(),) + tuple(params))
oport, vendas, f6 = (int(hist.at[0, c]) for c in ["oportunidades", "vendas", "fechadas_6m"])
if oport == 0:
    st.info("Sem oportunidades fechadas nesse recorte para projetar.")
else:
    c1, c2 = st.columns(2)
    horizonte = c1.slider("Meses de projeção", 3, 12, 6, key="proj_meses")
    volume = c2.number_input("Oportunidades fechadas por mês (projeção)", min_value=1,
                             value=max(1, round(f6 / 6)), step=1, key="proj_volume",
                             help="Padrão: média mensal dos últimos 6 meses do recorte filtrado. Ajuste para simular "
                                  "outro volume; quanto maior a amostra, mais estreita a faixa.")
    p_base = vendas / oport
    proj = projecao_wilson(p_base, volume, horizonte, ref + pd.offsets.MonthBegin(1))
    proj["rotulo"] = [f"{MESES[m.month - 1]}/{m:%y}" for m in proj.mes]

    fig = go.Figure()
    # banda de incerteza: limite superior (sem preenchimento) e depois o inferior preenchendo até ele
    fig.add_scatter(x=proj.rotulo, y=proj.limite_superior, name="Limite superior de Wilson (otimista)",
                    mode="lines+markers", line=dict(color=tema.CATEGORICA[2], width=2, dash="dash"),
                    marker=dict(size=7), customdata=proj.oportunidades_acum,
                    hovertemplate="Otimista: %{y:.1f}%<extra></extra>")
    fig.add_scatter(x=proj.rotulo, y=proj.limite_inferior, name="Limite inferior de Wilson (conservador)",
                    mode="lines+markers", line=dict(color=tema.CATEGORICA[1], width=2, dash="dash"),
                    marker=dict(size=7), fill="tonexty", fillcolor="rgba(177, 207, 245, 0.35)",
                    hovertemplate="Conservador: %{y:.1f}%<extra></extra>")
    fig.add_scatter(x=proj.rotulo, y=proj.win_rate, name="Win rate bruto esperado",
                    mode="lines+markers", line=dict(color=tema.CATEGORICA[0], width=3), marker=dict(size=8),
                    customdata=proj.oportunidades_acum,
                    hovertemplate="Esperado: %{y:.1f}%<br>amostra acumulada: %{customdata:,.0f} oportunidades<extra></extra>")
    # rótulos diretos no 1º e no último mês: valor e faixa
    for pos, anc, desloc in [(0, "right", -12), (-1, "left", 12)]:
        r = proj.iloc[pos]
        fig.add_annotation(x=r.rotulo, y=r.win_rate, xanchor=anc, xshift=desloc, showarrow=False, align=anc,
                           text=f"<b>{tema.pct(r.win_rate)}</b><br>{tema.pct(r.limite_inferior)} a {tema.pct(r.limite_superior)}",
                           font=dict(color=tema.TEXTO, size=12))
    fig.update_layout(
        title=dict(text="Projeção do Win Rate com Intervalo de Wilson (95%)",
                   subtitle=dict(text="A faixa de incerteza estreita conforme a amostra de oportunidades fechadas aumenta",
                                 font=dict(color=tema.TEXTO_2, size=12))),
        xaxis_title="Meses de projeção",
        yaxis=dict(title="Win rate (taxa de conversão)", ticksuffix="%", rangemode="tozero",
                   range=[0, max(50, proj.limite_superior.max() + 5)]),
        height=480, separators=",.", hovermode="x unified", margin=dict(l=90, r=130, t=120),
        legend=dict(y=1.02),
    )
    st.plotly_chart(fig, width="stretch")
    st.caption(f"Taxa base: {tema.pct(100 * p_base)} ({tema.num(vendas)} vendas em {tema.num(oport)} oportunidades "
               f"fechadas no recorte filtrado). Volume projetado: {tema.num(volume)} fechadas por mês. A faixa mostra "
               "onde o win rate realizado acumulado deve cair com 95% de confiança se a taxa se mantiver; ela não "
               "inclui mudanças de mercado nem a incerteza da própria taxa base.")

with st.expander("Tabela"):
    st.dataframe(tema.tabela(
        d.drop(columns=["cor", "global"]).sort_values("win_rate", ascending=False),
        formatos={"fechadas": "int", "ganhas": "int", "win_rate": "pct", "ic_inf": "pct", "ic_sup": "pct",
                  "win_rate_mrr": "pct"},
        rotulos={"grupo": DIMENSOES[dim], "fechadas": "Fechadas", "ganhas": "Ganhas", "win_rate": "Win rate",
                 "ic_inf": "IC 95% (mín.)", "ic_sup": "IC 95% (máx.)", "win_rate_mrr": "Win rate por MRR",
                 "leitura": "Leitura"}),
        hide_index=True, width="stretch")
