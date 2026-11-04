"""Qualidade dos dados: achados do profiling, QA do tratamento e de-para pendente."""
import streamlit as st

from lib import tema
from lib.dados import cabecalho, q

cabecalho("Qualidade dos dados", "O que foi encontrado na extração do CRM e o que foi tratado")

qa = q("FROM qa_tratamento")
falhas = (qa.resultado != "OK").sum()
c = st.columns(3)
c[0].metric("Testes de QA do tratamento", f"{(qa.resultado == 'OK').sum()}/{len(qa)} OK")
c[1].metric("Problemas de severidade alta", int(q("SELECT count(*) FROM achados WHERE severidade = 'alta'").iat[0, 0]))
nm = q("FROM qa_nao_mapeados")
c[2].metric("Valores sem de-para", len(nm))
if falhas:
    st.error("Há testes de QA falhando:")
    st.dataframe(qa[qa.resultado != "OK"], hide_index=True, width="stretch")
if len(nm):
    st.warning("Valores novos sem linha em `data/ref/de_para.csv`:")
    st.dataframe(tema.tabela(nm, {"qtd": "int"}, {"campo": "Campo", "valor": "Valor", "chave_sugerida": "Chave sugerida",
                                                  "qtd": "Ocorrências"}), hide_index=True, width="stretch")

st.subheader("Granularidade e reconciliação (duplicação de linhas)")
gr = q("SELECT teste, resultado, detalhe FROM qa_granularidade ORDER BY ordem")
hi = q("FROM qa_historico_info").iloc[0]
(st.success if (gr.resultado == "OK").all() else st.error)(
    f"{(gr.resultado == 'OK').sum()}/{len(gr)} testes OK: cada oportunidade é contada uma vez e os totais "
    "do painel batem com a soma direta das oportunidades.")
st.caption(f"O histórico de etapas tem {hi.linhas_por_oportunidade:.2f} linhas por oportunidade (máx. "
           f"{int(hi.max_linhas_por_oportunidade)}) e não entra em nenhuma soma do painel. Se fosse juntado sem agregar, "
           f"o MRR ganho apareceria como R$ {hi.mrr_ganho_se_juntar_sem_agregar / 1e6:,.1f} mi em vez de "
           f"R$ {hi.mrr_ganho_correto / 1e6:,.1f} mi.".replace(".", ","))
st.dataframe(tema.tabela(gr, rotulos={"teste": "Teste", "resultado": "Resultado", "detalhe": "Detalhe"}),
             hide_index=True, width="stretch")

st.subheader("Achados do profiling")
sev = st.multiselect("Severidade", ["alta", "media", "baixa"], default=["alta", "media"])
ach = q("FROM achados")
st.dataframe(tema.tabela(ach[ach.severidade.isin(sev)], {"linhas_afetadas": "int"},
                         {"tabela": "Tabela", "coluna": "Coluna", "problema": "Problema", "severidade": "Severidade",
                          "linhas_afetadas": "Linhas afetadas"}),
             hide_index=True, width="stretch")

st.subheader("Registros marcados no tratamento")
flags = q("""
    SELECT count(*) FILTER (WHERE flag_teste)             AS oportunidades_teste,
           count(*) FILTER (WHERE flag_mrr_suspeito)      AS mrr_preenchimento,
           count(*) FILTER (WHERE flag_mrr_invalido)      AS mrr_invalido,
           count(*) FILTER (WHERE flag_status_incoerente) AS status_incoerente,
           count(*) FILTER (WHERE flag_data_incoerente)   AS data_incoerente,
           count(*) FILTER (WHERE flag_cliente_duplicado) AS cliente_duplicado
    FROM trt_oportunidades""")
st.dataframe(tema.tabela(flags, {c: "int" for c in flags.columns},
                         {"oportunidades_teste": "Oportunidades de teste", "mrr_preenchimento": "MRR de preenchimento",
                          "mrr_invalido": "MRR zero ou negativo", "status_incoerente": "Status incoerente",
                          "data_incoerente": "Data incoerente", "cliente_duplicado": "Cliente duplicado"}),
             hide_index=True, width="stretch")
st.caption("Testes ficam fora de toda análise; MRR de preenchimento/inválido fica fora das somas de receita. "
           "As demais flags são mantidas e podem ser filtradas na análise.")
