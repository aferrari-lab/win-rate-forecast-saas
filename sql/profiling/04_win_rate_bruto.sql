-- =====================================================================
-- 04 · Win rate bruto (sanidade, ANTES do tratamento)
-- win rate = Ganhas / (Ganhas + Perdidas); abertas ficam fora do denominador.
-- IC 95% de Wilson: mostra se a diferença entre grupos é maior que o ruído.
-- Não é o resultado final: segmento ainda está com grafias sujas.
-- =====================================================================

CREATE OR REPLACE MACRO wilson_inf(g, n) AS
    (g/n + 1.96^2/(2*n) - 1.96*sqrt((g/n)*(1-g/n)/n + 1.96^2/(4*n^2))) / (1 + 1.96^2/n);
CREATE OR REPLACE MACRO wilson_sup(g, n) AS
    (g/n + 1.96^2/(2*n) + 1.96*sqrt((g/n)*(1-g/n)/n + 1.96^2/(4*n^2))) / (1 + 1.96^2/n);

CREATE OR REPLACE VIEW wr_bruto AS
WITH f AS (
    SELECT o.status, o.plano, o.origem,
           coalesce(c.segmento_crm, '(nulo)') AS segmento_crm,
           coalesce(v.time_vendas, '(nulo)')  AS time_vendas
    FROM stg_oportunidades o
    LEFT JOIN stg_clientes   c USING (id_cliente)
    LEFT JOIN stg_vendedores v USING (id_vendedor)
    WHERE o.status IN ('Ganha', 'Perdida')
),
agg AS (
    SELECT CASE WHEN GROUPING(segmento_crm) = 0 THEN 'segmento_crm'
                WHEN GROUPING(plano)        = 0 THEN 'plano'
                WHEN GROUPING(time_vendas)  = 0 THEN 'time'
                WHEN GROUPING(origem)       = 0 THEN 'origem'
                ELSE 'TOTAL' END                               AS dimensao,
           coalesce(segmento_crm, plano, time_vendas, origem, 'TOTAL') AS grupo,
           count(*)                                           AS fechadas,
           count(*) FILTER (WHERE status = 'Ganha')           AS ganhas
    FROM f
    GROUP BY GROUPING SETS ((segmento_crm), (plano), (time_vendas), (origem), ())
)
SELECT dimensao, grupo, fechadas, ganhas,
       round(100.0 * ganhas / fechadas, 1)                         AS win_rate_pct,
       round(100 * wilson_inf(CAST(ganhas AS DOUBLE), fechadas), 1) AS ic95_inf,
       round(100 * wilson_sup(CAST(ganhas AS DOUBLE), fechadas), 1) AS ic95_sup
FROM agg
ORDER BY dimensao = 'TOTAL' DESC, dimensao, fechadas DESC;

-- Safras (trimestre de criação): maturidade x win rate.
-- Safras recentes com poucas fechadas tendem a mostrar só os ciclos curtos.
CREATE OR REPLACE VIEW wr_safra AS
SELECT date_trunc('quarter', data_criacao)                AS trimestre,
       count(*)                                           AS criadas,
       count(*) FILTER (WHERE status <> 'Aberta')         AS fechadas,
       round(100.0 * fechadas / criadas, 1)               AS pct_fechadas,
       round(100.0 * count(*) FILTER (WHERE status = 'Ganha') / nullif(fechadas, 0), 1) AS win_rate_pct
FROM stg_oportunidades
WHERE data_criacao IS NOT NULL
GROUP BY ALL
ORDER BY trimestre;
