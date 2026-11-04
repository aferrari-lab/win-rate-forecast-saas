-- =====================================================================
-- 01 · Win rate por dimensão e ao longo do tempo
--
-- wr_global      : taxa única de hoje (a referência do Diretor)
-- wr_dimensoes   : 1 linha por (dimensão, grupo) - formato longo via UNPIVOT
--     win_rate       = ganhas / fechadas (por quantidade)
--     win_rate_mrr   = MRR ganho / MRR fechado (ponderado por valor; é o
--                      que importa para forecast de receita)
--     ic95_*         = intervalo de confiança de Wilson
--     dif_pp         = diferença para a taxa global, em pontos percentuais
--     vs_global      = 'acima'/'abaixo' só quando o IC não cruza a taxa global
-- wr_mensal      : win rate por mês de fechamento (estabilidade no tempo)
-- =====================================================================

CREATE OR REPLACE VIEW wr_global AS
SELECT count(*)                                         AS fechadas,
       count(*) FILTER (WHERE ganha)                    AS ganhas,
       avg(CAST(ganha AS DOUBLE))                       AS win_rate,
       sum(mrr_valido) FILTER (WHERE ganha) / sum(mrr_valido) AS win_rate_mrr
FROM base_op WHERE fechada;

CREATE OR REPLACE TABLE wr_dimensoes AS
WITH longo AS (
    SELECT dimensao, grupo, ganha, mrr_valido
    FROM (SELECT segmento_crm, porte_receita, setor, canal, origem, plano,
                 time_vendas, tipo_negocio, faixa_mrr, uf, ganha, mrr_valido
          FROM base_op WHERE fechada)
    UNPIVOT (grupo FOR dimensao IN (segmento_crm, porte_receita, setor, canal, origem, plano,
                                    time_vendas, tipo_negocio, faixa_mrr, uf))
),
agg AS (
    SELECT dimensao, grupo,
           count(*)                                         AS fechadas,
           count(*) FILTER (WHERE ganha)                    AS ganhas,
           sum(mrr_valido) FILTER (WHERE ganha)             AS mrr_ganho,
           sum(mrr_valido)                                  AS mrr_fechado
    FROM longo GROUP BY ALL
)
SELECT a.dimensao, a.grupo, a.fechadas, a.ganhas,
       round(a.fechadas * 100.0 / sum(a.fechadas) OVER (PARTITION BY a.dimensao), 1) AS pct_volume,
       round(100.0 * a.ganhas / a.fechadas, 1)                        AS win_rate,
       round(100 * wilson_inf(CAST(a.ganhas AS DOUBLE), a.fechadas), 1) AS ic95_inf,
       round(100 * wilson_sup(CAST(a.ganhas AS DOUBLE), a.fechadas), 1) AS ic95_sup,
       round(100.0 * a.ganhas / a.fechadas - 100 * g.win_rate, 1)     AS dif_pp,
       CASE WHEN wilson_inf(CAST(a.ganhas AS DOUBLE), a.fechadas) > g.win_rate THEN 'acima'
            WHEN wilson_sup(CAST(a.ganhas AS DOUBLE), a.fechadas) < g.win_rate THEN 'abaixo'
            ELSE 'igual (dentro do IC)' END                           AS vs_global,
       round(100.0 * a.mrr_ganho / a.mrr_fechado, 1)                  AS win_rate_mrr,
       round(a.mrr_ganho)                                             AS mrr_ganho
FROM agg a CROSS JOIN wr_global g
ORDER BY a.dimensao, a.fechadas DESC;

CREATE OR REPLACE VIEW wr_mensal AS
SELECT date_trunc('month', data_fechamento)               AS mes,
       count(*)                                           AS fechadas,
       count(*) FILTER (WHERE ganha)                      AS ganhas,
       round(100.0 * ganhas / fechadas, 1)                AS win_rate,
       round(100.0 * sum(mrr_valido) FILTER (WHERE ganha) / sum(mrr_valido), 1) AS win_rate_mrr
FROM base_op
WHERE fechada AND data_fechamento IS NOT NULL
GROUP BY ALL ORDER BY mes;
