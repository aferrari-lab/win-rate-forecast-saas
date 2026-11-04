-- =====================================================================
-- 02 · Comparações por período (MTD, QTD, YTD, últimos 12 meses)
-- Período atual termina em an_param.data_ref; o comparativo é a mesma
-- janela um ano antes (ex.: YTD 01/01-30/09/2026 x 01/01-30/09/2025).
--
-- Datas usadas: criadas -> data_criacao | resultado/receita -> data_fechamento
-- =====================================================================

CREATE OR REPLACE TABLE an_periodos AS
WITH r AS (SELECT data_ref AS d FROM an_param),
p AS (
    SELECT 1 AS ordem, 'MTD' AS periodo, date_trunc('month', d)   AS ini, d AS fim FROM r
    UNION ALL SELECT 2, 'QTD', date_trunc('quarter', d), d FROM r
    UNION ALL SELECT 3, 'YTD', date_trunc('year', d), d FROM r
    UNION ALL SELECT 4, 'Últimos 12 meses', CAST(d - INTERVAL 12 MONTH + INTERVAL 1 DAY AS DATE), d FROM r
)
SELECT ordem, periodo, 'atual' AS janela, CAST(ini AS DATE) AS ini, CAST(fim AS DATE) AS fim FROM p
UNION ALL
SELECT ordem, periodo, 'ano anterior', CAST(ini - INTERVAL 1 YEAR AS DATE), CAST(fim - INTERVAL 1 YEAR AS DATE) FROM p;

CREATE OR REPLACE TABLE an_periodos_metricas AS
WITH m AS (
    SELECT p.ordem, p.periodo, p.janela, p.ini, p.fim,
        count(*) FILTER (WHERE b.data_criacao BETWEEN p.ini AND p.fim)                         AS oportunidades_criadas,
        count(*) FILTER (WHERE b.fechada AND b.data_fechamento BETWEEN p.ini AND p.fim)        AS oportunidades_fechadas,
        count(*) FILTER (WHERE b.ganha AND b.data_fechamento BETWEEN p.ini AND p.fim)          AS oportunidades_ganhas,
        count(DISTINCT b.id_cliente_master) FILTER (WHERE b.ganha AND b.tipo_negocio = 'Novo cliente'
                                                    AND b.data_fechamento BETWEEN p.ini AND p.fim) AS novos_clientes,
        sum(b.mrr_valido) FILTER (WHERE b.ganha AND b.data_fechamento BETWEEN p.ini AND p.fim) AS mrr_ganho,
        sum(b.mrr_valido) FILTER (WHERE b.ganha AND b.tipo_negocio = 'Novo cliente'
                                  AND b.data_fechamento BETWEEN p.ini AND p.fim)              AS mrr_novos_clientes,
        sum(b.mrr_valido) FILTER (WHERE b.ganha AND b.tipo_negocio = 'Expansão'
                                  AND b.data_fechamento BETWEEN p.ini AND p.fim)              AS mrr_expansao,
        sum(b.mrr_valido) FILTER (WHERE b.ganha AND b.tipo_expansao = 'Upsell'
                                  AND b.data_fechamento BETWEEN p.ini AND p.fim)              AS mrr_upsell,
        sum(b.mrr_valido) FILTER (WHERE b.ganha AND b.tipo_expansao = 'Cross-sell'
                                  AND b.data_fechamento BETWEEN p.ini AND p.fim)              AS mrr_cross_sell,
        sum(b.mrr_valido) FILTER (WHERE b.fechada AND b.data_fechamento BETWEEN p.ini AND p.fim) AS mrr_fechado,
        avg(b.ciclo_vendas_dias) FILTER (WHERE b.ganha AND b.data_fechamento BETWEEN p.ini AND p.fim) AS ciclo_medio_ganhas_dias
    FROM an_periodos p CROSS JOIN base_op b
    GROUP BY ALL
)
SELECT *,
       100.0 * oportunidades_ganhas / nullif(oportunidades_fechadas, 0) AS win_rate,
       100.0 * mrr_ganho / nullif(mrr_fechado, 0)                       AS win_rate_mrr,
       mrr_ganho * 12                                                   AS arr_ganho,
       mrr_novos_clientes / nullif(novos_clientes, 0)                   AS arpa_novos_clientes
FROM m;

-- Formato de leitura: métrica x (atual, ano anterior, variação)
CREATE OR REPLACE VIEW an_periodos_comparativo AS
WITH longo AS (
    UNPIVOT (SELECT periodo, ordem, janela,
                    CAST(oportunidades_criadas AS DOUBLE) AS oportunidades_criadas,
                    CAST(oportunidades_fechadas AS DOUBLE) AS oportunidades_fechadas,
                    CAST(oportunidades_ganhas AS DOUBLE) AS oportunidades_ganhas,
                    win_rate, win_rate_mrr,
                    CAST(novos_clientes AS DOUBLE) AS novos_clientes,
                    mrr_ganho, mrr_novos_clientes, mrr_expansao, mrr_upsell, mrr_cross_sell,
                    arr_ganho, arpa_novos_clientes, ciclo_medio_ganhas_dias
             FROM an_periodos_metricas)
    ON COLUMNS(* EXCLUDE (periodo, ordem, janela)) INTO NAME metrica VALUE valor
)
SELECT periodo, metrica,
       round(any_value(valor) FILTER (WHERE janela = 'atual'), 1)        AS atual,
       round(any_value(valor) FILTER (WHERE janela = 'ano anterior'), 1) AS ano_anterior,
       CASE WHEN metrica IN ('win_rate', 'win_rate_mrr')
            THEN round(atual - ano_anterior, 1) END                      AS var_pp,
       CASE WHEN metrica NOT IN ('win_rate', 'win_rate_mrr')
            THEN round(100.0 * (atual / nullif(ano_anterior, 0) - 1), 1) END AS var_pct
FROM longo
GROUP BY periodo, ordem, metrica
ORDER BY ordem, metrica;
