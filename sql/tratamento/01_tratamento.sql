-- =====================================================================
-- 01 · Camada TRATADA (trt_*)
--
-- Regras de padronização:
--   * Texto nulo/vazio -> 'NA' | número nulo -> 0 | datas nulas continuam NULL
--   * Exceção: num_funcionarios nulo/vazio/'n/d' -> NULL (mantém tipo INTEGER, não vira 0)
--     (0 não é uma data; ex.: data_fechamento nula = oportunidade aberta)
--   * Quando um número nulo vira 0, uma coluna *_informado guarda se o valor
--     era real, para não confundir "0 real" com "não informado" nas médias.
--   * cidade_uf -> uf (sigla) | setor, segmento_crm, origem, utm_campaign,
--     flag_migrado_v2, ativo -> via de-para (data/ref/de_para.csv)
--   * utm_campaign nula/vazia -> 'not set' | flag_migrado_v2 nula -> 0
--
-- Princípio: nenhuma linha é apagada. Problemas que dependem de decisão
-- do negócio (status x etapa, datas incoerentes, CNPJ duplicado) viram
-- flags (flag_*), para a análise escolher filtrar ou não.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Clientes
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE trt_clientes AS
WITH base AS (
    SELECT *,
           regexp_replace(cnpj, '[^0-9]', '', 'g') AS cnpj_digitos,
           TRY_CAST(trim(num_funcionarios) AS INTEGER) AS n_func,
           to_date(data_criacao) AS dt_criacao
    FROM raw_clientes
)
SELECT
    id_cliente,
    -- mesma empresa (CNPJ) com vários IDs: master = cadastro mais antigo
    first(id_cliente ORDER BY dt_criacao, id_cliente)
        OVER (PARTITION BY coalesce(nullif(cnpj_digitos, ''), id_cliente)) AS id_cliente_master,
    txt(cnpj_digitos)                                  AS cnpj,
    txt(razao_social)                                  AS razao_social,
    txt(nome_fantasia)                                 AS nome_fantasia,
    padroniza('setor', setor)                          AS setor,
    padroniza('segmento_crm', segmento_crm)            AS segmento_crm,
    txt(porte_receita)                                 AS porte_receita,
    -- INTEGER; NULL quando não informado (nulo, vazio ou 'n/d') - evita conflito de tipo
    n_func                                             AS num_funcionarios,
    n_func IS NOT NULL                                 AS num_funcionarios_informado,
    padroniza('uf', cidade_uf)                         AS uf,
    dt_criacao                                         AS data_criacao,
    CAST(coalesce(dp('flag_migrado_v2', flag_migrado_v2), '0') AS INTEGER) AS flag_migrado_v2,
    txt(id_legado_metrics)                             AS id_legado_metrics,
    txt(url_logo)                                      AS url_logo,
    txt(campo_custom_17)                               AS campo_custom_17,
    txt(observacoes)                                   AS observacoes,
    count(*) OVER (PARTITION BY nullif(cnpj_digitos, '')) > 1
        AND nullif(cnpj_digitos, '') IS NOT NULL       AS flag_cnpj_duplicado
FROM base;

-- ---------------------------------------------------------------------
-- Vendedores
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE trt_vendedores AS
SELECT
    id_vendedor,
    txt(nome_vendedor)                     AS nome_vendedor,
    txt("time")                            AS time_vendas,
    to_date(data_admissao)                 AS data_admissao,
    to_date(data_desligamento)             AS data_desligamento,
    padroniza('ativo', ativo)              AS ativo,
    txt(email_legado)                      AS email_legado,
    txt(cod_centro_custo)                  AS cod_centro_custo,
    num0(TRY_CAST(meta_mensal_2024 AS INTEGER)) AS meta_mensal_2024,
    TRY_CAST(meta_mensal_2024 AS INTEGER) IS NOT NULL AS meta_mensal_2024_informada,
    (padroniza('ativo', ativo) = 'S') = (to_date(data_desligamento) IS NOT NULL) AS flag_ativo_incoerente
FROM raw_vendedores;

-- ---------------------------------------------------------------------
-- Oportunidades
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE trt_oportunidades AS
WITH base AS (
    SELECT o.*,
           to_num(o.valor_mrr)                     AS mrr,
           to_date(o.data_criacao)                 AS dt_criacao,
           to_date(o.data_fechamento)              AS dt_fechamento,
           to_date(o.data_assinatura_contrato)     AS dt_assinatura,
           TRY_CAST(o.ultima_atualizacao_sistema AS TIMESTAMP) AS ts_atualizacao
    FROM raw_oportunidades o
),
p AS (SELECT CAST(max(ts_atualizacao) AS DATE) AS data_extracao FROM base)
SELECT
    b.id_oportunidade,
    b.id_cliente,
    c.id_cliente_master,
    b.id_vendedor,
    txt(b.nome_oportunidade)                   AS nome_oportunidade,
    padroniza('origem', b.origem)              AS origem,
    coalesce(dp('canal', b.origem), 'NA')      AS canal,
    txt(b.plano)                               AS plano,
    num0(b.mrr)                                AS valor_mrr,
    b.mrr IS NOT NULL                          AS valor_mrr_informado,
    txt(b.etapa_atual)                         AS etapa_atual,
    txt(b.status)                              AS status,
    b.dt_criacao                               AS data_criacao,
    b.dt_fechamento                            AS data_fechamento,
    b.dt_assinatura                            AS data_assinatura_contrato,
    -- NULL para abertas de propósito (ver exceção no QA)
    CASE WHEN b.status IN ('Ganha', 'Perdida') AND b.dt_fechamento >= b.dt_criacao
         THEN date_diff('day', b.dt_criacao, b.dt_fechamento) END AS ciclo_vendas_dias,
    txt(b.motivo_perda)                        AS motivo_perda,
    num0(TRY_CAST(b.probabilidade_crm AS INTEGER)) AS probabilidade_crm,
    CASE WHEN nullif(trim(b.utm_campaign), '') IS NULL THEN 'not set'
         ELSE padroniza('utm_campaign', b.utm_campaign) END AS utm_campaign,
    txt(b.id_hubspot_legado)                   AS id_hubspot_legado,
    b.ts_atualizacao                           AS ultima_atualizacao_sistema,
    -- campo_custom_3 removido: 100% nulo na extração
    -- ---- flags de qualidade (decisão de filtrar fica para a análise) ----
    b.status <> CASE b.etapa_atual WHEN 'Ganho' THEN 'Ganha' WHEN 'Perdido' THEN 'Perdida'
                                   ELSE 'Aberta' END            AS flag_status_incoerente,
    coalesce(b.dt_fechamento < b.dt_criacao, false)
        OR coalesce(b.dt_fechamento > p.data_extracao, false)
        OR (b.status IN ('Ganha', 'Perdida') AND b.dt_fechamento IS NULL) AS flag_data_incoerente,
    coalesce(b.mrr <= 0, true)                                AS flag_mrr_invalido,
    coalesce(c.flag_cnpj_duplicado, false)                    AS flag_cliente_duplicado,
    -- oportunidades de teste/QA do CRM: excluir de qualquer análise
    regexp_matches(lower(strip_accents(coalesce(b.nome_oportunidade, ''))),
                   'teste|nao usar|demo interna')               AS flag_teste,
    -- valores de preenchimento (999.999, 1.250.000, 5.000.000): o maior MRR real
    -- da base é ~R$ 60 mil (Enterprise + IA); acima de R$ 100 mil é inválido
    coalesce(b.mrr > 100000, false)                           AS flag_mrr_suspeito
FROM base b
CROSS JOIN p
LEFT JOIN trt_clientes c USING (id_cliente);

-- ---------------------------------------------------------------------
-- Histórico de etapas
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE trt_historico_etapas AS
SELECT
    id_oportunidade,
    txt(etapa)                                 AS etapa,
    CASE etapa WHEN 'Novo' THEN 1 WHEN 'Qualificação' THEN 2 WHEN 'Demonstração' THEN 3
               WHEN 'Proposta' THEN 4 WHEN 'Negociação' THEN 5 ELSE 6 END AS ordem_etapa,
    to_date(data_entrada_etapa)                AS data_entrada_etapa,
    txt(id_vendedor_responsavel)               AS id_vendedor_responsavel,
    num0(to_num(valor_mrr_na_etapa))           AS valor_mrr_na_etapa
FROM raw_historico_etapas;
