-- =====================================================================
-- 04 · Unit economics e painel de KPIs
--
-- O CRM não tem custo, cancelamento, faturamento nem usuários. Esses
-- insumos vêm de data/ref/premissas.csv (valores em branco = pendente).
-- Nada é estimado por conta própria: sem premissa, o KPI fica NULL e
-- a coluna "status" diz o que falta.
--
-- an_unit_economics : CAC, LTV, LTV/CAC, Payback, GRR, NRR, churn, ARPU, EBITDA
-- an_ltv_segmento   : ARPA de novos clientes e LTV por segmento
-- an_kpis           : painel consolidado (YTD x YTD ano anterior + status)
-- =====================================================================

CREATE OR REPLACE TABLE an_premissas AS
SELECT trim(chave) AS chave, TRY_CAST(nullif(trim(valor), '') AS DOUBLE) AS valor,
       unidade, descricao, fonte_sugerida
FROM read_csv('data/ref/premissas.csv', header = true, all_varchar = true);

CREATE OR REPLACE MACRO pr(k) AS (SELECT any_value(valor) FROM an_premissas WHERE chave = k);

CREATE OR REPLACE TABLE an_unit_economics AS
WITH u12 AS (
    SELECT novos_clientes, mrr_novos_clientes, mrr_expansao, arpa_novos_clientes
    FROM an_periodos_metricas WHERE periodo = 'Últimos 12 meses' AND janela = 'atual'
),
base AS (
    SELECT (SELECT mrr_contratado_acum_sem_churn FROM an_receita_mensal
             WHERE mes = date_trunc('month', (SELECT data_ref FROM an_param)) - INTERVAL 12 MONTH) AS mrr_base_12m_atras,
           (SELECT mrr_contratado_acum_sem_churn FROM an_receita_mensal ORDER BY mes DESC LIMIT 1) AS mrr_contratado_atual
),
v AS (
    SELECT
        pr('gasto_vendas_marketing_12m') / nullif(u.novos_clientes, 0)                      AS cac,
        u.arpa_novos_clientes                                                               AS arpa,
        u.arpa_novos_clientes * pr('margem_bruta_pct') / 100
            / (pr('churn_mrr_mensal_pct') / 100)                                            AS ltv,
        pow(1 - pr('churn_mrr_mensal_pct') / 100, 12)                                       AS grr,
        1 - pow(1 - pr('churn_logo_mensal_pct') / 100, 12)                                  AS logo_churn_anual,
        u.mrr_expansao / nullif(b.mrr_base_12m_atras, 0)                                    AS expansao_sobre_base,
        b.mrr_contratado_atual,
        u.novos_clientes, u.mrr_expansao, b.mrr_base_12m_atras
    FROM u12 u, base b
),
kpis AS (
    SELECT 1 AS ordem, 'ARPA (novos clientes, 12m)' AS kpi, round(arpa, 2) AS valor, 'R$/mês' AS unidade,
           'MRR de novos clientes / nº de novos clientes' AS formula, NULL AS falta FROM v
    UNION ALL SELECT 2, 'CAC', round(cac, 2), 'R$',
           'Gasto Vendas+Marketing 12m / novos clientes 12m', 'gasto_vendas_marketing_12m' FROM v
    UNION ALL SELECT 3, 'LTV', round(ltv, 2), 'R$',
           'ARPA x margem bruta / churn de MRR mensal', 'margem_bruta_pct, churn_mrr_mensal_pct' FROM v
    UNION ALL SELECT 4, 'LTV/CAC', round(ltv / cac, 2), 'x',
           'LTV / CAC (referência de mercado: >= 3x)', 'gasto_vendas_marketing_12m, margem_bruta_pct, churn_mrr_mensal_pct' FROM v
    UNION ALL SELECT 5, 'Payback do CAC', round(cac / (arpa * pr('margem_bruta_pct') / 100), 1), 'meses',
           'CAC / (ARPA x margem bruta)', 'gasto_vendas_marketing_12m, margem_bruta_pct' FROM v
    UNION ALL SELECT 6, 'Churn de MRR (mensal)', pr('churn_mrr_mensal_pct'), '% ao mês',
           'Premissa (billing)', 'churn_mrr_mensal_pct' FROM v
    UNION ALL SELECT 7, 'Logo churn (anual)', round(100 * logo_churn_anual, 1), '%',
           '1 - (1 - churn logo mensal)^12', 'churn_logo_mensal_pct' FROM v
    UNION ALL SELECT 8, 'GRR (anual)', round(100 * grr, 1), '%',
           '(1 - churn MRR mensal)^12', 'churn_mrr_mensal_pct' FROM v
    UNION ALL SELECT 9, 'NRR (anual)', round(100 * (grr + expansao_sobre_base), 1), '%',
           'GRR + MRR de expansão 12m (CRM) / MRR contratado 12m atrás (CRM, sem churn)', 'churn_mrr_mensal_pct' FROM v
    UNION ALL SELECT 10, 'Expansão sobre a base (12m)', round(100 * expansao_sobre_base, 1), '%',
           'MRR de expansão 12m / MRR contratado 12m atrás - componente do NRR vindo do CRM', NULL FROM v
    UNION ALL SELECT 11, 'ARR faturado', 12 * pr('mrr_faturado_atual'), 'R$',
           'MRR faturado x 12', 'mrr_faturado_atual' FROM v
    UNION ALL SELECT 12, 'ARPU', round(coalesce(pr('mrr_faturado_atual'), mrr_contratado_atual) / pr('usuarios_ativos'), 2), 'R$/usuário/mês',
           'MRR (faturado; senão contratado) / usuários ativos', 'usuarios_ativos' FROM v
    UNION ALL SELECT 13, 'EBITDA (12m)', pr('ebitda_12m'), 'R$', 'Premissa (DRE)', 'ebitda_12m' FROM v
    UNION ALL SELECT 14, 'Margem EBITDA (12m)', round(100 * pr('ebitda_12m') / pr('receita_liquida_12m'), 1), '%',
           'EBITDA / receita líquida', 'ebitda_12m, receita_liquida_12m' FROM v
)
SELECT ordem, kpi, valor, unidade, formula,
       CASE WHEN valor IS NOT NULL THEN 'calculado'
            ELSE 'pendente: preencher ' || falta || ' em data/ref/premissas.csv' END AS status
FROM kpis
ORDER BY ordem;

-- LTV por segmento: o ARPA muda muito entre segmentos, então o LTV também.
-- (usa churn e margem únicos - se o billing tiver churn por segmento, refinar)
CREATE OR REPLACE TABLE an_ltv_segmento AS
SELECT b.segmento_crm,
       count(DISTINCT b.id_cliente_master)                         AS novos_clientes_12m,
       round(sum(b.mrr_valido) / count(DISTINCT b.id_cliente_master), 2) AS arpa_novos_12m,
       round(sum(b.mrr_valido) / count(DISTINCT b.id_cliente_master)
             * pr('margem_bruta_pct') / 100 / (pr('churn_mrr_mensal_pct') / 100), 2) AS ltv
FROM base_op b, an_param p
WHERE b.ganha AND b.tipo_negocio = 'Novo cliente'
  AND b.data_fechamento > p.data_ref - INTERVAL 12 MONTH
GROUP BY ALL
ORDER BY arpa_novos_12m DESC;

-- Painel consolidado de KPIs
CREATE OR REPLACE TABLE an_kpis AS
WITH ytd AS (
    SELECT * FROM an_periodos_comparativo WHERE periodo = 'YTD'
),
ult AS (SELECT * FROM an_receita_mensal ORDER BY mes DESC LIMIT 1),
k AS (
    SELECT 1 AS ordem, 'Win rate (YTD)' AS kpi, atual, ano_anterior, var_pp AS variacao, 'pp' AS unid_variacao,
           'Calculado (CRM)' AS natureza, 'Ganhas / (ganhas + perdidas), por data de fechamento' AS nota
      FROM ytd WHERE metrica = 'win_rate'
    UNION ALL SELECT 2, 'Win rate ponderado por MRR (YTD)', atual, ano_anterior, var_pp, 'pp',
           'Calculado (CRM)', 'MRR ganho / MRR fechado' FROM ytd WHERE metrica = 'win_rate_mrr'
    UNION ALL SELECT 3, 'Oportunidades ganhas (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', NULL FROM ytd WHERE metrica = 'oportunidades_ganhas'
    UNION ALL SELECT 4, 'Novos clientes (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'Logos conquistados' FROM ytd WHERE metrica = 'novos_clientes'
    UNION ALL SELECT 5, 'MRR novo - novos clientes (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'New MRR contratado' FROM ytd WHERE metrica = 'mrr_novos_clientes'
    UNION ALL SELECT 6, 'MRR de expansão (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'Upsell + cross-sell + recompra' FROM ytd WHERE metrica = 'mrr_expansao'
    UNION ALL SELECT 7, 'MRR de upsell (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'Plano de nível superior' FROM ytd WHERE metrica = 'mrr_upsell'
    UNION ALL SELECT 8, 'MRR de cross-sell (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'Add-on WhatsApp / IA' FROM ytd WHERE metrica = 'mrr_cross_sell'
    UNION ALL SELECT 9, 'ARR novo contratado (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'MRR ganho x 12 (bookings, não faturamento)' FROM ytd WHERE metrica = 'arr_ganho'
    UNION ALL SELECT 10, 'ARPA novos clientes (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'Ticket médio mensal de novos clientes' FROM ytd WHERE metrica = 'arpa_novos_clientes'
    UNION ALL SELECT 11, 'Ciclo médio de vendas - ganhas (YTD)', atual, ano_anterior, var_pct, '%',
           'Calculado (CRM)', 'Dias entre criação e fechamento' FROM ytd WHERE metrica = 'ciclo_medio_ganhas_dias'
    UNION ALL SELECT 12, 'MRR contratado acumulado', round(mrr_contratado_acum_sem_churn), NULL, NULL, NULL,
           'Proxy (CRM, teto)', 'Soma de todo MRR ganho desde 2023, supondo churn zero. NÃO é o MRR atual' FROM ult
    UNION ALL SELECT 13, 'ARR contratado acumulado', round(arr_contratado_acum_sem_churn), NULL, NULL, NULL,
           'Proxy (CRM, teto)', 'MRR contratado acumulado x 12. NÃO é o ARR atual' FROM ult
    UNION ALL SELECT 14, 'ARPA da base', round(arpa_base_sem_churn, 2), NULL, NULL, NULL,
           'Proxy (CRM, teto)', 'MRR contratado acumulado / clientes conquistados' FROM ult
    UNION ALL
    SELECT 100 + ordem, kpi, valor, NULL, NULL, NULL,
           CASE WHEN kpi LIKE 'ARPA%' OR kpi LIKE 'Expansão%' THEN 'Calculado (CRM)'
                WHEN status = 'calculado' THEN 'Premissa + CRM'
                ELSE 'Requer dado externo' END,
           CASE WHEN status = 'calculado' THEN formula ELSE status END
    FROM an_unit_economics WHERE kpi NOT LIKE 'ARPA (novos%'
)
SELECT ordem, kpi, atual AS valor, ano_anterior AS valor_ano_anterior, variacao, unid_variacao, natureza, nota
FROM k ORDER BY ordem;
