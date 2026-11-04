-- =====================================================================
-- 00 · Base analítica (depende da camada trt_*)
--
-- an_param  : data de referência = último dia com dado de negócio
--             (a extração é de 20/10, mas criação/fechamento vão até 30/09;
--              usar a data da extração deixaria o MTD vazio)
-- base_op   : 1 linha por oportunidade válida (sem testes), com atributos
--             do cliente/vendedor e classificação Novo cliente x Expansão
--
-- Regras:
--   * Rótulo do desfecho = status (Ganha/Perdida/Aberta).
--   * Win rate = ganhas / (ganhas + perdidas). Abertas fora do denominador.
--   * Receita usa mrr_valido: exclui MRR de preenchimento e <= 0.
--   * Expansão = oportunidade criada quando o cliente (id_cliente_master)
--     já tinha um ganho fechado. Tipo de expansão pelo plano:
--       Upsell     -> plano de nível acima do maior já contratado
--       Cross-sell -> mesmo nível + add-on (WhatsApp / IA) que não tinha
--       Mesmo plano / Plano inferior -> demais casos
-- =====================================================================

CREATE OR REPLACE MACRO wilson_inf(g, n) AS
    (g/n + 1.96^2/(2*n) - 1.96*sqrt((g/n)*(1-g/n)/n + 1.96^2/(4*n^2))) / (1 + 1.96^2/n);
CREATE OR REPLACE MACRO wilson_sup(g, n) AS
    (g/n + 1.96^2/(2*n) + 1.96*sqrt((g/n)*(1-g/n)/n + 1.96^2/(4*n^2))) / (1 + 1.96^2/n);

CREATE OR REPLACE TABLE an_param AS
SELECT greatest(max(data_criacao), max(data_fechamento)) AS data_ref
FROM trt_oportunidades WHERE NOT flag_teste;

CREATE OR REPLACE TABLE base_op AS
WITH o AS (
    SELECT o.*,
           c.segmento_crm, c.porte_receita, c.setor, c.uf,
           v.time_vendas, v.nome_vendedor,
           CASE o.plano WHEN 'Básico' THEN 1 WHEN 'Pro' THEN 2 WHEN 'Pro + WhatsApp' THEN 2
                        WHEN 'Enterprise' THEN 3 WHEN 'Enterprise + IA' THEN 3 END AS nivel_plano,
           o.plano LIKE '%+%' AS tem_addon
    FROM trt_oportunidades o
    LEFT JOIN trt_clientes   c USING (id_cliente)
    LEFT JOIN trt_vendedores v USING (id_vendedor)
    WHERE NOT o.flag_teste
),
ganhos AS (
    SELECT id_cliente_master, id_oportunidade, data_fechamento, nivel_plano, tem_addon
    FROM o WHERE status = 'Ganha' AND data_fechamento IS NOT NULL
),
historico_cliente AS (   -- o que o cliente já tinha contratado quando a oportunidade nasceu
    SELECT o.id_oportunidade,
           count(g.id_oportunidade) AS ganhos_previos,
           max(g.nivel_plano)       AS nivel_previo,
           bool_or(g.tem_addon)     AS addon_previo
    FROM o
    LEFT JOIN ganhos g
           ON g.id_cliente_master = o.id_cliente_master
          AND g.data_fechamento   < o.data_criacao
          AND g.id_oportunidade  <> o.id_oportunidade
    GROUP BY o.id_oportunidade
)
SELECT
    o.id_oportunidade, o.id_cliente, o.id_cliente_master, o.id_vendedor,
    o.segmento_crm, o.porte_receita, o.setor, o.uf, o.time_vendas, o.nome_vendedor,
    o.canal, o.origem, o.plano, o.utm_campaign,
    o.status, o.etapa_atual,
    o.status IN ('Ganha', 'Perdida')                        AS fechada,
    o.status = 'Ganha'                                      AS ganha,
    o.data_criacao, o.data_fechamento, o.ciclo_vendas_dias,
    o.probabilidade_crm,
    CASE WHEN NOT o.flag_mrr_suspeito AND NOT o.flag_mrr_invalido THEN o.valor_mrr END AS mrr_valido,
    CASE WHEN o.flag_mrr_suspeito OR o.flag_mrr_invalido THEN 'Inválido'
         WHEN o.valor_mrr <  1000 THEN '1. < R$ 1 mil'
         WHEN o.valor_mrr <  3000 THEN '2. R$ 1-3 mil'
         WHEN o.valor_mrr < 10000 THEN '3. R$ 3-10 mil'
         WHEN o.valor_mrr < 30000 THEN '4. R$ 10-30 mil'
         ELSE '5. >= R$ 30 mil' END                         AS faixa_mrr,
    CASE WHEN h.ganhos_previos = 0 THEN 'Novo cliente' ELSE 'Expansão' END AS tipo_negocio,
    CASE WHEN h.ganhos_previos = 0                          THEN 'NA'
         WHEN o.nivel_plano > h.nivel_previo                THEN 'Upsell'
         WHEN o.nivel_plano = h.nivel_previo
              AND o.tem_addon AND NOT h.addon_previo        THEN 'Cross-sell'
         WHEN o.nivel_plano < h.nivel_previo                THEN 'Plano inferior'
         ELSE 'Mesmo plano' END                             AS tipo_expansao,
    o.flag_status_incoerente, o.flag_data_incoerente, o.flag_cliente_duplicado
FROM o JOIN historico_cliente h USING (id_oportunidade);
