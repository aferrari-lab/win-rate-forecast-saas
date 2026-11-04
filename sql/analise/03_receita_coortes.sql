-- =====================================================================
-- 03 · Receita contratada e coortes
--
-- ATENÇÃO: o CRM registra o que foi VENDIDO (bookings), não o que está
-- sendo FATURADO. Não há cancelamentos/downgrades na extração, então o
-- MRR acumulado aqui é um TETO (supõe churn zero). MRR/ARR reais, churn,
-- NRR e GRR exigem a base de assinaturas/faturamento.
--
-- an_receita_mensal   : movimentos e acumulados por mês
-- an_coorte_clientes  : coorte = trimestre do 1º ganho do cliente;
--                       MRR acumulado da coorte ao longo dos trimestres
--                       (mostra expansão: upsell + cross-sell + recompra)
-- an_coorte_pipeline  : coorte = mês de criação da oportunidade;
--                       % ganhas/perdidas/abertas após k meses
--                       (curva de maturação: quanto tempo o funil leva)
-- =====================================================================

CREATE OR REPLACE TABLE an_receita_mensal AS
WITH meses AS (
    SELECT CAST(range AS DATE) AS mes
    FROM range((SELECT date_trunc('month', min(data_fechamento)) FROM base_op),
               (SELECT date_trunc('month', data_ref) FROM an_param) + INTERVAL 1 MONTH,
               INTERVAL 1 MONTH)
),
mov AS (
    SELECT date_trunc('month', data_fechamento) AS mes,
           count(DISTINCT id_cliente_master) FILTER (WHERE tipo_negocio = 'Novo cliente') AS novos_clientes,
           count(*) FILTER (WHERE tipo_negocio = 'Expansão')                         AS expansoes,
           coalesce(sum(mrr_valido) FILTER (WHERE tipo_negocio = 'Novo cliente'), 0) AS mrr_novos_clientes,
           coalesce(sum(mrr_valido) FILTER (WHERE tipo_negocio = 'Expansão'), 0)     AS mrr_expansao,
           coalesce(sum(mrr_valido) FILTER (WHERE tipo_expansao = 'Upsell'), 0)      AS mrr_upsell,
           coalesce(sum(mrr_valido) FILTER (WHERE tipo_expansao = 'Cross-sell'), 0)  AS mrr_cross_sell
    FROM base_op WHERE ganha AND data_fechamento IS NOT NULL
    GROUP BY ALL
)
SELECT m.mes,
       coalesce(v.novos_clientes, 0)     AS novos_clientes,
       coalesce(v.expansoes, 0)          AS expansoes,
       coalesce(v.mrr_novos_clientes, 0) AS mrr_novos_clientes,
       coalesce(v.mrr_expansao, 0)       AS mrr_expansao,
       coalesce(v.mrr_upsell, 0)         AS mrr_upsell,
       coalesce(v.mrr_cross_sell, 0)     AS mrr_cross_sell,
       sum(coalesce(v.novos_clientes, 0)) OVER w                                     AS clientes_acum_sem_churn,
       sum(coalesce(v.mrr_novos_clientes, 0) + coalesce(v.mrr_expansao, 0)) OVER w   AS mrr_contratado_acum_sem_churn,
       12 * sum(coalesce(v.mrr_novos_clientes, 0) + coalesce(v.mrr_expansao, 0)) OVER w AS arr_contratado_acum_sem_churn,
       sum(coalesce(v.mrr_novos_clientes, 0) + coalesce(v.mrr_expansao, 0)) OVER w
         / nullif(sum(coalesce(v.novos_clientes, 0)) OVER w, 0)                      AS arpa_base_sem_churn
FROM meses m LEFT JOIN mov v USING (mes)
WINDOW w AS (ORDER BY m.mes)
ORDER BY m.mes;

CREATE OR REPLACE TABLE an_coorte_clientes AS
WITH ganhos AS (
    SELECT id_cliente_master, data_fechamento, mrr_valido,
           min(date_trunc('quarter', data_fechamento)) OVER (PARTITION BY id_cliente_master) AS coorte
    FROM base_op WHERE ganha AND data_fechamento IS NOT NULL
),
grade AS (   -- coorte x trimestres relativos já decorridos até a data de referência
    SELECT DISTINCT g.coorte, k.k AS trimestre_relativo
    FROM ganhos g, range(0, 13) k(k), an_param p
    WHERE g.coorte + to_months(3 * k.k) <= p.data_ref
),
base AS (
    SELECT coorte,
           count(DISTINCT id_cliente_master) AS clientes,
           sum(mrr_valido) FILTER (WHERE date_trunc('quarter', data_fechamento) = coorte) AS mrr_inicial
    FROM ganhos GROUP BY coorte
)
SELECT gr.coorte, gr.trimestre_relativo, b.clientes, round(b.mrr_inicial) AS mrr_inicial,
       round(sum(g.mrr_valido)) AS mrr_acumulado,
       round(100.0 * (sum(g.mrr_valido) / b.mrr_inicial - 1), 1) AS expansao_pct,
       round(100.0 * count(DISTINCT g.id_cliente_master) FILTER (
             WHERE date_trunc('quarter', g.data_fechamento) > gr.coorte) / b.clientes, 1) AS pct_clientes_com_expansao
FROM grade gr
JOIN base b USING (coorte)
JOIN ganhos g ON g.coorte = gr.coorte
             AND date_trunc('quarter', g.data_fechamento) <= gr.coorte + to_months(3 * gr.trimestre_relativo)
GROUP BY gr.coorte, gr.trimestre_relativo, b.clientes, b.mrr_inicial
ORDER BY gr.coorte, gr.trimestre_relativo;

CREATE OR REPLACE TABLE an_coorte_pipeline AS
WITH o AS (
    SELECT date_trunc('month', data_criacao) AS coorte, status,
           date_diff('month', date_trunc('month', data_criacao), date_trunc('month', data_fechamento)) AS meses_ate_fechar
    FROM base_op WHERE data_criacao IS NOT NULL
),
grade AS (
    SELECT DISTINCT o.coorte, k.k AS meses_desde_criacao
    FROM o, range(0, 13) k(k), an_param p
    WHERE o.coorte + to_months(k.k) <= date_trunc('month', p.data_ref)
)
SELECT g.coorte, g.meses_desde_criacao,
       count(*) AS oportunidades,
       round(100.0 * count(*) FILTER (WHERE o.status = 'Ganha'   AND o.meses_ate_fechar <= g.meses_desde_criacao) / count(*), 1) AS pct_ganhas,
       round(100.0 * count(*) FILTER (WHERE o.status = 'Perdida' AND o.meses_ate_fechar <= g.meses_desde_criacao) / count(*), 1) AS pct_perdidas,
       round(100.0 * count(*) FILTER (WHERE o.status IN ('Ganha', 'Perdida') AND o.meses_ate_fechar <= g.meses_desde_criacao)
             / count(*), 1) AS pct_fechadas
FROM grade g JOIN o USING (coorte)
GROUP BY ALL
ORDER BY g.coorte, g.meses_desde_criacao;
