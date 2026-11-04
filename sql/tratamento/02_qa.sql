-- =====================================================================
-- 02 · QA do tratamento
-- qa_tratamento     : testes que precisam dar OK (ver coluna "resultado")
-- qa_nao_mapeados   : valores sem linha no de-para (incluir no CSV)
-- qa_depara_aplicado: antes -> depois de cada campo padronizado (auditoria)
-- =====================================================================

CREATE OR REPLACE TABLE qa_nao_mapeados AS
WITH v AS (
    SELECT 'setor' AS campo, setor AS valor FROM raw_clientes
    UNION ALL SELECT 'segmento_crm', segmento_crm FROM raw_clientes
    UNION ALL SELECT 'uf', cidade_uf FROM raw_clientes
    UNION ALL SELECT 'flag_migrado_v2', flag_migrado_v2 FROM raw_clientes
    UNION ALL SELECT 'origem', origem FROM raw_oportunidades
    UNION ALL SELECT 'canal', origem FROM raw_oportunidades
    UNION ALL SELECT 'utm_campaign', utm_campaign FROM raw_oportunidades
    UNION ALL SELECT 'ativo', ativo FROM raw_vendedores
)
SELECT campo, valor, norm(valor) AS chave_sugerida, count(*) AS qtd
FROM v
WHERE nullif(trim(valor), '') IS NOT NULL AND dp(campo, valor) IS NULL
GROUP BY ALL ORDER BY campo, qtd DESC;

CREATE OR REPLACE TABLE qa_depara_aplicado AS
SELECT 'setor' AS campo, r.setor AS antes, t.setor AS depois, count(*) AS qtd
  FROM raw_clientes r JOIN trt_clientes t USING (id_cliente) GROUP BY ALL
UNION ALL SELECT 'segmento_crm', r.segmento_crm, t.segmento_crm, count(*)
  FROM raw_clientes r JOIN trt_clientes t USING (id_cliente) GROUP BY ALL
UNION ALL SELECT 'uf', r.cidade_uf, t.uf, count(*)
  FROM raw_clientes r JOIN trt_clientes t USING (id_cliente) GROUP BY ALL
UNION ALL SELECT 'flag_migrado_v2', r.flag_migrado_v2, CAST(t.flag_migrado_v2 AS VARCHAR), count(*)
  FROM raw_clientes r JOIN trt_clientes t USING (id_cliente) GROUP BY ALL
UNION ALL SELECT 'origem -> canal', r.origem, t.origem || ' | ' || t.canal, count(*)
  FROM raw_oportunidades r JOIN trt_oportunidades t USING (id_oportunidade) GROUP BY ALL
UNION ALL SELECT 'utm_campaign', r.utm_campaign, t.utm_campaign, count(*)
  FROM raw_oportunidades r JOIN trt_oportunidades t USING (id_oportunidade) GROUP BY ALL
UNION ALL SELECT 'ativo', r.ativo, t.ativo, count(*)
  FROM raw_vendedores r JOIN trt_vendedores t USING (id_vendedor) GROUP BY ALL
ORDER BY campo, depois, qtd DESC;

-- Nulos remanescentes por coluna. Exceções por regra:
--   datas (DATE/TIMESTAMP): nula = evento não ocorreu (ex.: oportunidade aberta)
--   ciclo_vendas_dias: métrica derivada, só existe para fechadas; 0 distorceria a média
--   num_funcionarios: NULL = não informado (decisão: manter INTEGER, sem 0 nem texto)
CREATE OR REPLACE TABLE qa_nulos AS
SELECT 'trt_clientes' AS tabela, column_name, column_type, CAST(null_percentage AS DOUBLE) AS nulos_pct FROM (SUMMARIZE trt_clientes)
UNION ALL SELECT 'trt_oportunidades', column_name, column_type, CAST(null_percentage AS DOUBLE) FROM (SUMMARIZE trt_oportunidades)
UNION ALL SELECT 'trt_vendedores', column_name, column_type, CAST(null_percentage AS DOUBLE) FROM (SUMMARIZE trt_vendedores)
UNION ALL SELECT 'trt_historico_etapas', column_name, column_type, CAST(null_percentage AS DOUBLE) FROM (SUMMARIZE trt_historico_etapas);

CREATE OR REPLACE TABLE qa_tratamento AS
WITH t AS (
    SELECT 'linhas preservadas: clientes' AS teste,
           (SELECT count(*) FROM trt_clientes) = (SELECT count(*) FROM raw_clientes) AS ok, NULL AS detalhe
    UNION ALL SELECT 'linhas preservadas: oportunidades',
           (SELECT count(*) FROM trt_oportunidades) = (SELECT count(*) FROM raw_oportunidades), NULL
    UNION ALL SELECT 'linhas preservadas: vendedores',
           (SELECT count(*) FROM trt_vendedores) = (SELECT count(*) FROM raw_vendedores), NULL
    UNION ALL SELECT 'linhas preservadas: historico_etapas',
           (SELECT count(*) FROM trt_historico_etapas) = (SELECT count(*) FROM raw_historico_etapas), NULL
    UNION ALL SELECT 'PK única: trt_clientes',
           (SELECT count(*) = count(DISTINCT id_cliente) FROM trt_clientes), NULL
    UNION ALL SELECT 'PK única: trt_oportunidades',
           (SELECT count(*) = count(DISTINCT id_oportunidade) FROM trt_oportunidades), NULL
    UNION ALL SELECT 'todos os valores mapeados no de-para',
           (SELECT count(*) = 0 FROM qa_nao_mapeados),
           (SELECT string_agg(campo || '=' || valor, '; ') FROM qa_nao_mapeados)
    UNION ALL SELECT 'sem nulos em texto/número',
           (SELECT count(*) = 0 FROM qa_nulos WHERE nulos_pct > 0 AND column_type NOT IN ('DATE', 'TIMESTAMP')
               AND column_name NOT IN ('ciclo_vendas_dias', 'num_funcionarios')),
           (SELECT string_agg(tabela || '.' || column_name, '; ') FROM qa_nulos
             WHERE nulos_pct > 0 AND column_type NOT IN ('DATE', 'TIMESTAMP')
               AND column_name NOT IN ('ciclo_vendas_dias', 'num_funcionarios'))
    UNION ALL SELECT 'uf só com siglas de 2 letras (ou NA)',
           (SELECT bool_and(regexp_full_match(uf, '[A-Z]{2}|NA')) FROM trt_clientes), NULL
    UNION ALL SELECT 'flag_migrado_v2 só 0/1',
           (SELECT bool_and(flag_migrado_v2 IN (0, 1)) FROM trt_clientes), NULL
    UNION ALL SELECT 'ativo só S/N',
           (SELECT bool_and(ativo IN ('S', 'N')) FROM trt_vendedores), NULL
    UNION ALL SELECT 'utm_campaign sem nulo/vazio',
           (SELECT bool_and(utm_campaign <> '' AND utm_campaign <> 'NA') FROM trt_oportunidades), NULL
)
SELECT teste, CASE WHEN ok THEN 'OK' ELSE 'FALHOU' END AS resultado, detalhe FROM t;
