-- =====================================================================
-- 02 · Perfil estrutural
-- perfil_tabelas      : linhas e linhas duplicadas por tabela
-- perfil_colunas      : SUMMARIZE do DuckDB (nulos %, distintos, min/max...)
-- dist_categoricas    : distribuição de valores das colunas de corte
-- resumo_categoricas  : distintos brutos x distintos normalizados
-- =====================================================================

CREATE OR REPLACE TABLE perfil_tabelas AS
SELECT 'oportunidades' AS tabela, count(*) AS linhas,
       count(*) - (SELECT count(*) FROM (SELECT DISTINCT * FROM raw_oportunidades)) AS linhas_duplicadas
FROM raw_oportunidades
UNION ALL
SELECT 'clientes', count(*),
       count(*) - (SELECT count(*) FROM (SELECT DISTINCT * FROM raw_clientes))
FROM raw_clientes
UNION ALL
SELECT 'vendedores', count(*),
       count(*) - (SELECT count(*) FROM (SELECT DISTINCT * FROM raw_vendedores))
FROM raw_vendedores
UNION ALL
SELECT 'historico_etapas', count(*),
       count(*) - (SELECT count(*) FROM (SELECT DISTINCT * FROM raw_historico_etapas))
FROM raw_historico_etapas;

CREATE OR REPLACE TABLE perfil_colunas AS
SELECT 'oportunidades' AS tabela, * FROM (SUMMARIZE raw_oportunidades)
UNION ALL BY NAME
SELECT 'clientes' AS tabela, * FROM (SUMMARIZE raw_clientes)
UNION ALL BY NAME
SELECT 'vendedores' AS tabela, * FROM (SUMMARIZE raw_vendedores)
UNION ALL BY NAME
SELECT 'historico_etapas' AS tabela, * FROM (SUMMARIZE raw_historico_etapas);

-- Colunas categóricas que serão eixos de corte do win rate (UNPIVOT -> formato longo)
CREATE OR REPLACE TABLE dist_categoricas AS
WITH longo AS (
    SELECT 'clientes' AS tabela, coluna, valor
    FROM raw_clientes
    UNPIVOT INCLUDE NULLS (valor FOR coluna IN (setor, segmento_crm, porte_receita, cidade_uf, flag_migrado_v2))
    UNION ALL
    SELECT 'oportunidades', coluna, valor
    FROM raw_oportunidades
    UNPIVOT INCLUDE NULLS (valor FOR coluna IN (origem, plano, etapa_atual, status, motivo_perda, probabilidade_crm, utm_campaign))
    UNION ALL
    SELECT 'vendedores', coluna, valor
    FROM raw_vendedores
    UNPIVOT INCLUDE NULLS (valor FOR coluna IN ("time", ativo))
    UNION ALL
    SELECT 'historico_etapas', 'etapa', etapa FROM raw_historico_etapas
)
SELECT tabela, coluna, valor, norm(valor) AS valor_norm, count(*) AS qtd
FROM longo
GROUP BY ALL
ORDER BY tabela, coluna, qtd DESC;

CREATE OR REPLACE TABLE resumo_categoricas AS
SELECT tabela, coluna,
       count(DISTINCT valor)                           AS distintos_brutos,
       count(DISTINCT valor_norm)                      AS distintos_normalizados,
       sum(qtd) FILTER (WHERE valor IS NULL)           AS nulos,
       sum(qtd) FILTER (WHERE valor IS NOT NULL)       AS preenchidos
FROM dist_categoricas
GROUP BY ALL
ORDER BY tabela, coluna;
