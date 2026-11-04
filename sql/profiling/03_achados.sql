-- =====================================================================
-- 03 · Registro de achados
-- Cada check é um SELECT que devolve: tabela, coluna, problema,
-- severidade e linhas_afetadas. Tudo junto por UNION ALL numa tabela só.
--
-- Severidade (pensando no win rate):
--   alta  = distorce o rótulo ganho/perda ou a atribuição do grupo (segmento, origem...)
--   media = distorce valores, datas ou ciclo (MRR, safra, tempo de fechamento)
--   baixa = cosmético / informativo
-- Para criar um check novo: copie um bloco e ajuste a condição.
-- =====================================================================

CREATE OR REPLACE TABLE achados AS
WITH
o AS (FROM stg_oportunidades),
c AS (FROM stg_clientes),
v AS (FROM stg_vendedores),
h AS (FROM stg_historico_etapas),
p AS (FROM param),

cnpj_dup AS (
    SELECT cnpj,
           count(DISTINCT segmento_norm) AS segmentos,
           count(DISTINCT setor_norm)    AS setores
    FROM c GROUP BY cnpj HAVING count(*) > 1
),
moda_prob AS (
    SELECT etapa_atual, mode(probabilidade_crm) AS prob FROM o GROUP BY etapa_atual
),
mrr_iqr AS (   -- quartis de log10(MRR) dentro de cada plano (regra de Tukey)
    SELECT plano,
           quantile_cont(log10(valor_mrr), 0.25) AS q1,
           quantile_cont(log10(valor_mrr), 0.75) AS q3
    FROM o WHERE valor_mrr > 0 GROUP BY plano
),
h_ord AS (
    SELECT *,
           row_number() OVER w                       AS rn,
           count(*)     OVER (PARTITION BY id_oportunidade) AS n_etapas,
           lag(ordem_etapa) OVER w                   AS ordem_anterior
    FROM h
    WINDOW w AS (PARTITION BY id_oportunidade ORDER BY data_entrada_etapa, ordem_etapa)
),
hist_op AS (   -- uma linha por oportunidade, resumindo o histórico
    SELECT id_oportunidade,
           min(data_entrada_etapa)                              AS hist_inicio,
           max(data_entrada_etapa)                              AS hist_fim,
           any_value(etapa)                   FILTER (rn = n_etapas) AS ultima_etapa,
           any_value(valor_mrr_na_etapa)      FILTER (rn = n_etapas) AS mrr_ultimo,
           any_value(id_vendedor_responsavel) FILTER (rn = n_etapas) AS vendedor_ultimo,
           count(DISTINCT valor_mrr_na_etapa)      AS mrr_distintos,
           count(DISTINCT id_vendedor_responsavel) AS vendedores_distintos,
           count(*) - count(DISTINCT etapa)        AS etapas_repetidas,
           bool_or(ordem_etapa < ordem_anterior)   AS voltou_no_funil
    FROM h_ord GROUP BY id_oportunidade
),
espacos AS (   -- espaços sobrando em qualquer coluna (UNPIVOT de todas as colunas)
    SELECT 'clientes' AS tabela, coluna, count(*) AS n
    FROM (UNPIVOT raw_clientes ON COLUMNS(*) INTO NAME coluna VALUE valor)
    WHERE valor <> trim(valor) GROUP BY ALL
    UNION ALL
    SELECT 'oportunidades', coluna, count(*)
    FROM (UNPIVOT raw_oportunidades ON COLUMNS(*) INTO NAME coluna VALUE valor)
    WHERE valor <> trim(valor) GROUP BY ALL
),

checks AS (
    -- ---------------- Estrutura -----------------------------------------
    SELECT tabela, column_name AS coluna,
           'coluna ' || CAST(round(CAST(null_percentage AS DOUBLE)) AS INTEGER) || '% nula (candidata a descarte)' AS problema,
           'baixa' AS severidade,
           CAST(round("count" * CAST(null_percentage AS DOUBLE) / 100) AS BIGINT) AS linhas_afetadas
    FROM perfil_colunas WHERE CAST(null_percentage AS DOUBLE) > 90
    UNION ALL
    SELECT tabela, coluna, 'espaços sobrando no início/fim', 'baixa', n FROM espacos
    UNION ALL
    SELECT tabela, coluna,
           'grafias redundantes (' || distintos_brutos || ' -> ' || distintos_normalizados || ' após normalizar)',
           CASE WHEN coluna IN ('setor', 'segmento_crm', 'porte_receita', 'origem', 'plano', 'time', 'status', 'etapa_atual')
                THEN 'alta' ELSE 'baixa' END,
           preenchidos
    FROM resumo_categoricas WHERE distintos_brutos > distintos_normalizados

    -- ---------------- Chaves e integridade ------------------------------
    UNION ALL SELECT 'oportunidades', 'id_oportunidade', 'chave primária duplicada', 'alta',
        count(*) - count(DISTINCT id_oportunidade) FROM o
    UNION ALL SELECT 'clientes', 'id_cliente', 'chave primária duplicada', 'alta',
        count(*) - count(DISTINCT id_cliente) FROM c
    UNION ALL SELECT 'vendedores', 'id_vendedor', 'chave primária duplicada', 'alta',
        count(*) - count(DISTINCT id_vendedor) FROM v
    UNION ALL SELECT 'oportunidades', 'id_cliente', 'sem correspondência em clientes', 'alta',
        count(*) FROM o ANTI JOIN c USING (id_cliente)
    UNION ALL SELECT 'oportunidades', 'id_vendedor', 'sem correspondência em vendedores', 'alta',
        count(*) FROM o ANTI JOIN v USING (id_vendedor)
    UNION ALL SELECT 'historico_etapas', 'id_oportunidade', 'sem correspondência em oportunidades', 'media',
        count(*) FROM h ANTI JOIN o USING (id_oportunidade)
    UNION ALL SELECT 'oportunidades', 'id_oportunidade', 'oportunidade sem histórico de etapas', 'media',
        count(*) FROM o ANTI JOIN h USING (id_oportunidade)

    -- ---------------- Clientes / CNPJ -----------------------------------
    UNION ALL SELECT 'clientes', 'cnpj', 'formato misto (com máscara . / -)', 'baixa',
        count(*) FILTER (WHERE regexp_matches(cnpj_raw, '[./-]')) FROM c
    UNION ALL SELECT 'clientes', 'cnpj', 'não tem 14 dígitos após normalizar', 'media',
        count(*) FILTER (WHERE length(cnpj) <> 14) FROM c
    UNION ALL SELECT 'clientes', 'cnpj',
        CASE WHEN avg(CAST(NOT cnpj_valido(cnpj) AS INTEGER)) > 0.5
             THEN 'DV inválido na maioria: CNPJs fictícios/mascarados (usar só p/ dedup)'
             ELSE 'dígito verificador inválido' END, 'baixa',
        count(*) FILTER (WHERE NOT cnpj_valido(cnpj)) FROM c
    UNION ALL SELECT 'clientes', 'cnpj', 'mesmo CNPJ em mais de um id_cliente', 'alta',
        count(*) FROM c SEMI JOIN cnpj_dup USING (cnpj)
    UNION ALL SELECT 'clientes', 'cnpj', 'CNPJ duplicado com segmento divergente entre cópias', 'alta',
        count(*) FILTER (WHERE segmentos > 1) FROM cnpj_dup
    UNION ALL SELECT 'oportunidades', 'id_cliente', 'oportunidade de cliente com CNPJ duplicado', 'alta',
        count(*) FROM o SEMI JOIN (FROM c SEMI JOIN cnpj_dup USING (cnpj)) cc USING (id_cliente)
    UNION ALL SELECT 'clientes', 'segmento_crm', 'segmento nulo', 'alta',
        count(*) FILTER (WHERE segmento_crm IS NULL) FROM c
    UNION ALL SELECT 'clientes', 'num_funcionarios', 'valor não numérico (' || coalesce(any_value(num_funcionarios_raw), '') || ')', 'baixa',
        count(*) FROM c WHERE num_funcionarios IS NULL AND num_funcionarios_raw IS NOT NULL

    -- ---------------- Oportunidades: valores ----------------------------
    UNION ALL SELECT 'oportunidades', 'valor_mrr', 'vírgula decimal (formato BR) - recuperável', 'media',
        count(*) FROM o WHERE TRY_CAST(valor_mrr_raw AS DOUBLE) IS NULL AND valor_mrr IS NOT NULL
    UNION ALL SELECT 'oportunidades', 'valor_mrr', 'valor irrecuperável', 'media',
        count(*) FROM o WHERE valor_mrr IS NULL AND valor_mrr_raw IS NOT NULL
    UNION ALL SELECT 'oportunidades', 'valor_mrr', 'valor negativo', 'media',
        count(*) FILTER (WHERE valor_mrr < 0) FROM o
    UNION ALL SELECT 'oportunidades', 'valor_mrr', 'valor zero', 'media',
        count(*) FILTER (WHERE valor_mrr = 0) FROM o
    UNION ALL SELECT 'oportunidades', 'valor_mrr', 'outlier de MRR dentro do próprio plano', 'media',
        count(*) FROM o JOIN mrr_iqr USING (plano)
        WHERE valor_mrr > 0 AND (log10(valor_mrr) < q1 - 1.5 * (q3 - q1) OR log10(valor_mrr) > q3 + 1.5 * (q3 - q1))
    UNION ALL SELECT 'oportunidades', 'probabilidade_crm', 'probabilidade fora do padrão da etapa', 'baixa',
        count(*) FROM o JOIN moda_prob USING (etapa_atual) WHERE o.probabilidade_crm <> moda_prob.prob

    UNION ALL SELECT 'oportunidades', 'nome_oportunidade', 'oportunidade de teste (teste / não usar / demo interna)', 'alta',
        count(*) FILTER (WHERE regexp_matches(lower(strip_accents(nome_oportunidade)), 'teste|nao usar|demo interna'))
        FROM raw_oportunidades
    UNION ALL SELECT 'oportunidades', 'valor_mrr', 'valor de preenchimento (MRR > R$ 100 mil: 999.999, 1,25 mi, 5 mi)', 'alta',
        count(*) FILTER (WHERE valor_mrr > 100000) FROM o

    -- ---------------- Oportunidades: datas ------------------------------
    UNION ALL SELECT 'oportunidades', 'data_criacao',
        'data fora do padrão ISO (' || coalesce(any_value(mascara(data_criacao_raw)), '') || ') - recuperável', 'media',
        count(*) FROM o WHERE NOT is_iso_date(data_criacao_raw) AND data_criacao IS NOT NULL
    UNION ALL SELECT 'oportunidades', 'data_criacao', 'data irrecuperável', 'media',
        count(*) FROM o WHERE data_criacao IS NULL AND data_criacao_raw IS NOT NULL
    UNION ALL SELECT 'oportunidades', 'datas', 'fechamento antes da criação', 'media',
        count(*) FILTER (WHERE data_fechamento < data_criacao) FROM o
    UNION ALL SELECT 'oportunidades', 'datas', 'assinatura antes do fechamento', 'media',
        count(*) FILTER (WHERE data_assinatura_contrato < data_fechamento) FROM o
    UNION ALL SELECT 'oportunidades', 'datas', 'fechamento no futuro', 'media',
        count(*) FILTER (WHERE data_fechamento > p.data_extracao) FROM o, p
    UNION ALL SELECT 'oportunidades', 'datas', 'criação no futuro', 'media',
        count(*) FILTER (WHERE data_criacao > p.data_extracao) FROM o, p
    UNION ALL SELECT 'oportunidades', 'datas', 'fechada (Ganha/Perdida) sem data_fechamento', 'media',
        count(*) FILTER (WHERE status IN ('Ganha', 'Perdida') AND data_fechamento IS NULL) FROM o
    UNION ALL SELECT 'oportunidades', 'datas', 'aberta com data_fechamento preenchida (data prevista?)', 'media',
        count(*) FILTER (WHERE status = 'Aberta' AND data_fechamento IS NOT NULL) FROM o
    UNION ALL SELECT 'oportunidades', 'datas', 'ganha sem data_assinatura_contrato', 'baixa',
        count(*) FILTER (WHERE status = 'Ganha' AND data_assinatura_contrato IS NULL) FROM o
    UNION ALL SELECT 'oportunidades', 'datas', 'não ganha com data_assinatura_contrato', 'alta',
        count(*) FILTER (WHERE status <> 'Ganha' AND data_assinatura_contrato IS NOT NULL) FROM o
    UNION ALL SELECT 'oportunidades', 'datas', 'oportunidade criada antes do cadastro do cliente', 'baixa',
        count(*) FROM o JOIN c USING (id_cliente) WHERE o.data_criacao < c.data_criacao

    -- ---------------- Oportunidades: regras de negócio ------------------
    UNION ALL SELECT 'oportunidades', 'status x etapa_atual', 'status incoerente com a etapa atual', 'alta',
        count(*) FILTER (WHERE status <> CASE etapa_atual WHEN 'Ganho' THEN 'Ganha'
                                                          WHEN 'Perdido' THEN 'Perdida'
                                                          ELSE 'Aberta' END) FROM o
    UNION ALL SELECT 'oportunidades', 'motivo_perda', 'perdida sem motivo_perda', 'baixa',
        count(*) FILTER (WHERE status = 'Perdida' AND motivo_perda IS NULL) FROM o
    UNION ALL SELECT 'oportunidades', 'motivo_perda', 'não perdida com motivo_perda', 'alta',
        count(*) FILTER (WHERE status <> 'Perdida' AND motivo_perda IS NOT NULL) FROM o

    -- ---------------- Histórico de etapas --------------------------------
    UNION ALL SELECT 'historico_etapas', 'etapa', 'última etapa do histórico difere de etapa_atual', 'alta',
        count(*) FROM o JOIN hist_op USING (id_oportunidade) WHERE ultima_etapa <> etapa_atual
    UNION ALL SELECT 'historico_etapas', 'etapa', 'mesma etapa registrada mais de uma vez', 'baixa',
        sum(etapas_repetidas) FROM hist_op
    UNION ALL SELECT 'historico_etapas', 'etapa', 'oportunidade voltou etapa no funil', 'baixa',
        count(*) FILTER (WHERE voltou_no_funil) FROM hist_op
    UNION ALL SELECT 'historico_etapas', 'data_entrada_etapa', 'histórico começa antes da criação', 'media',
        count(*) FROM o JOIN hist_op USING (id_oportunidade) WHERE hist_inicio < data_criacao
    UNION ALL SELECT 'historico_etapas', 'data_entrada_etapa', 'histórico termina depois do fechamento', 'media',
        count(*) FROM o JOIN hist_op USING (id_oportunidade) WHERE hist_fim > data_fechamento
    UNION ALL SELECT 'historico_etapas', 'valor_mrr_na_etapa', 'MRR final do histórico ≠ valor_mrr', 'media',
        count(*) FROM o JOIN hist_op USING (id_oportunidade) WHERE abs(mrr_ultimo - valor_mrr) > 0.01
    UNION ALL SELECT 'historico_etapas', 'valor_mrr_na_etapa', 'MRR mudou ao longo do funil (informativo)', 'baixa',
        count(*) FILTER (WHERE mrr_distintos > 1) FROM hist_op
    UNION ALL SELECT 'historico_etapas', 'id_vendedor_responsavel', 'vendedor final do histórico ≠ id_vendedor', 'media',
        count(*) FROM o JOIN hist_op USING (id_oportunidade) WHERE vendedor_ultimo <> id_vendedor
    UNION ALL SELECT 'historico_etapas', 'id_vendedor_responsavel', 'vendedor trocou ao longo do funil (informativo)', 'baixa',
        count(*) FILTER (WHERE vendedores_distintos > 1) FROM hist_op

    -- ---------------- Vendedores -----------------------------------------
    UNION ALL SELECT 'vendedores', 'ativo', 'flag ativo incoerente com data_desligamento', 'baixa',
        count(*) FILTER (WHERE ativo = (data_desligamento IS NOT NULL)) FROM v
    UNION ALL SELECT 'oportunidades', 'id_vendedor', 'oportunidade criada após desligamento do vendedor', 'media',
        count(*) FROM o JOIN v USING (id_vendedor) WHERE o.data_criacao > v.data_desligamento
    UNION ALL SELECT 'oportunidades', 'id_vendedor', 'oportunidade criada antes da admissão do vendedor', 'media',
        count(*) FROM o JOIN v USING (id_vendedor) WHERE o.data_criacao < v.data_admissao
)
SELECT *
FROM checks
WHERE linhas_afetadas > 0
ORDER BY CASE severidade WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
         linhas_afetadas DESC;
