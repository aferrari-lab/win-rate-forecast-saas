-- =====================================================================
-- 05 · QA de granularidade e reconciliação (duplicação de linhas)
--
-- Risco: historico_etapas tem ~4,6 linhas por oportunidade (máx. 8). Um
-- JOIN com ele sem agregar multiplica linhas e infla contagens e somas de
-- MRR. Esta checagem garante que:
--   1. cada camada tem 1 linha por oportunidade (nenhum JOIN abriu leque);
--   2. as chaves usadas nos JOINs são únicas;
--   3. o histórico não tem linhas repetidas;
--   4. os totais do painel batem com a soma direta das oportunidades.
-- qa_granularidade : testes (resultado OK/FALHOU)
-- qa_historico_info: números de referência do histórico (informativo)
-- =====================================================================

-- número inteiro no padrão brasileiro para os textos de detalhe (14.605.717)
CREATE OR REPLACE MACRO fmt_int(x) AS replace(format('{:,}', CAST(round(x) AS BIGINT)), ',', '.');

CREATE OR REPLACE TABLE qa_granularidade AS
WITH
direto AS (   -- soma direta, sem nenhum JOIN: a "verdade" para reconciliar
    SELECT count(*) FILTER (WHERE status = 'Ganha')                         AS ganhas,
           count(*) FILTER (WHERE status IN ('Ganha', 'Perdida'))           AS fechadas,
           sum(valor_mrr) FILTER (WHERE status = 'Ganha' AND NOT flag_mrr_suspeito AND NOT flag_mrr_invalido) AS mrr_ganho,
           sum(valor_mrr) FILTER (WHERE status = 'Ganha' AND NOT flag_mrr_suspeito AND NOT flag_mrr_invalido
                                  AND data_fechamento IS NULL)              AS mrr_ganho_sem_data,
           sum(valor_mrr) FILTER (WHERE status = 'Ganha' AND NOT flag_mrr_suspeito AND NOT flag_mrr_invalido
                                  AND data_fechamento BETWEEN (SELECT ini FROM an_periodos WHERE periodo = 'YTD' AND janela = 'atual')
                                                          AND (SELECT fim FROM an_periodos WHERE periodo = 'YTD' AND janela = 'atual')) AS mrr_ganho_ytd
    FROM trt_oportunidades WHERE NOT flag_teste
),
coorte_final AS (   -- MRR acumulado no último trimestre de cada coorte
    SELECT coorte, arg_max(mrr_acumulado, trimestre_relativo) AS mrr_final FROM an_coorte_clientes GROUP BY coorte
),
coorte_direto AS (
    SELECT coorte, round(sum(mrr_valido)) AS mrr
    FROM (SELECT mrr_valido, min(date_trunc('quarter', data_fechamento)) OVER (PARTITION BY id_cliente_master) AS coorte
          FROM base_op WHERE ganha AND data_fechamento IS NOT NULL)
    GROUP BY coorte
),
t AS (
    SELECT 1 AS ordem, 'raw_oportunidades: 1 linha por id_oportunidade' AS teste,
           (SELECT count(*) = count(DISTINCT id_oportunidade) FROM raw_oportunidades) AS ok,
           (SELECT fmt_int(count(*)) || ' linhas' FROM raw_oportunidades) AS detalhe
    UNION ALL SELECT 2, 'trt_oportunidades: mesmas linhas do raw',
           (SELECT count(*) FROM trt_oportunidades) = (SELECT count(*) FROM raw_oportunidades),
           (SELECT fmt_int(count(*)) || ' linhas' FROM trt_oportunidades)
    UNION ALL SELECT 3, 'base_op: 1 linha por oportunidade (JOINs sem leque)',
           (SELECT count(*) = count(DISTINCT id_oportunidade) FROM base_op),
           (SELECT fmt_int(count(*)) || ' linhas' FROM base_op)
    UNION ALL SELECT 4, 'base_op = trt_oportunidades sem testes',
           (SELECT count(*) FROM base_op) = (SELECT count(*) FROM trt_oportunidades WHERE NOT flag_teste), NULL
    UNION ALL SELECT 5, 'chave de JOIN única: trt_clientes.id_cliente',
           (SELECT count(*) = count(DISTINCT id_cliente) FROM trt_clientes), NULL
    UNION ALL SELECT 6, 'chave de JOIN única: trt_vendedores.id_vendedor',
           (SELECT count(*) = count(DISTINCT id_vendedor) FROM trt_vendedores), NULL
    UNION ALL SELECT 7, 'histórico: nenhuma linha idêntica',
           (SELECT count(*) FROM raw_historico_etapas) = (SELECT count(*) FROM (SELECT DISTINCT * FROM raw_historico_etapas)), NULL
    UNION ALL SELECT 8, 'histórico: nenhuma (oportunidade, etapa, data) repetida',
           (SELECT count(*) = 0 FROM (SELECT id_oportunidade, etapa, data_entrada_etapa FROM raw_historico_etapas GROUP BY ALL HAVING count(*) > 1)), NULL
    UNION ALL SELECT 9, 'oportunidades: nenhuma duplicata lógica (mesmo cliente, nome, valor e data, ids diferentes)',
           (SELECT count(*) = 0 FROM (SELECT id_cliente_master, nome_oportunidade, valor_mrr, data_criacao FROM trt_oportunidades GROUP BY ALL HAVING count(*) > 1)), NULL
    UNION ALL SELECT 10, 'win rate: ganhas e fechadas = contagem direta',
           (SELECT ganhas FROM wr_global) = d.ganhas AND (SELECT fechadas FROM wr_global) = d.fechadas,
           fmt_int(d.ganhas) || ' ganhas / ' || fmt_int(d.fechadas) || ' fechadas'
      FROM direto d
    UNION ALL SELECT 11, 'MRR ganho total (base_op) = soma direta',
           abs((SELECT sum(mrr_valido) FROM base_op WHERE ganha) - d.mrr_ganho) < 0.01,
           'R$ ' || fmt_int(d.mrr_ganho)
      FROM direto d
    UNION ALL SELECT 12, 'MRR ganho YTD do painel = soma direta',
           abs((SELECT mrr_ganho FROM an_periodos_metricas WHERE periodo = 'YTD' AND janela = 'atual') - d.mrr_ganho_ytd) < 0.01,
           'R$ ' || fmt_int(d.mrr_ganho_ytd)
      FROM direto d
    UNION ALL SELECT 13, 'receita mensal acumulada + ganhas sem data de fechamento = MRR ganho total',
           abs((SELECT mrr_contratado_acum_sem_churn FROM an_receita_mensal ORDER BY mes DESC LIMIT 1)
               + coalesce(d.mrr_ganho_sem_data, 0) - d.mrr_ganho) < 0.01,
           'ganhas sem data: R$ ' || fmt_int(coalesce(d.mrr_ganho_sem_data, 0)) || ' (ficam fora das séries por mês)'
      FROM direto d
    UNION ALL SELECT 14, 'coortes: MRR acumulado final de cada coorte = vendas da coorte',
           (SELECT bool_and(abs(f.mrr_final - c.mrr) <= 1) FROM coorte_final f JOIN coorte_direto c USING (coorte)), NULL
)
SELECT ordem, teste, CASE WHEN ok THEN 'OK' ELSE 'FALHOU' END AS resultado, detalhe FROM t ORDER BY ordem;

CREATE OR REPLACE TABLE qa_historico_info AS
SELECT (SELECT count(*) FROM raw_historico_etapas)                                          AS linhas_historico,
       (SELECT count(DISTINCT id_oportunidade) FROM raw_historico_etapas)                   AS oportunidades,
       (SELECT round(count(*) / count(DISTINCT id_oportunidade), 2) FROM raw_historico_etapas) AS linhas_por_oportunidade,
       (SELECT max(n) FROM (SELECT count(*) AS n FROM raw_historico_etapas GROUP BY id_oportunidade)) AS max_linhas_por_oportunidade,
       (SELECT count(*) FROM (SELECT id_oportunidade, etapa FROM raw_historico_etapas GROUP BY ALL HAVING count(*) > 1)) AS reentradas_na_mesma_etapa,
       -- o que aconteceria com o MRR ganho se alguém juntasse o histórico sem agregar
       (SELECT round(sum(b.mrr_valido)) FROM base_op b JOIN raw_historico_etapas h USING (id_oportunidade) WHERE b.ganha) AS mrr_ganho_se_juntar_sem_agregar,
       (SELECT round(sum(mrr_valido)) FROM base_op WHERE ganha)                            AS mrr_ganho_correto;
