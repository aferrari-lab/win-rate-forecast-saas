-- =====================================================================
-- 01 · Macros de apoio + camada STAGING (tipagem com fallback)
-- O staging NÃO limpa regra de negócio: só converte tipos e expõe
-- colunas auxiliares (_raw, _norm) para os checks. Será reaproveitado
-- no tratamento.
-- =====================================================================

-- Texto -> chave de comparação: minúsculo, sem acento, só [a-z0-9]
CREATE OR REPLACE MACRO norm(s) AS
    regexp_replace(lower(strip_accents(trim(s))), '[^a-z0-9]', '', 'g');

-- Formato do valor: troca dígitos por 9 ("16/03/2026" -> "99/99/9999")
CREATE OR REPLACE MACRO mascara(s) AS regexp_replace(s, '[0-9]', '9', 'g');

-- Número: padrão (1234.56); fallback para vírgula decimal BR (1.234,56)
CREATE OR REPLACE MACRO to_num(s) AS coalesce(
    TRY_CAST(trim(s) AS DOUBLE),
    CASE WHEN s LIKE '%,%'
         THEN TRY_CAST(replace(replace(trim(s), '.', ''), ',', '.') AS DOUBLE) END);

-- Data: ISO (aaaa-mm-dd); fallback dd/mm/aaaa
CREATE OR REPLACE MACRO to_date(s) AS CAST(coalesce(
    TRY_STRPTIME(trim(s), '%Y-%m-%d'),
    TRY_STRPTIME(trim(s), '%d/%m/%Y')) AS DATE);

CREATE OR REPLACE MACRO is_iso_date(s) AS regexp_full_match(trim(s), '\d{4}-\d{2}-\d{2}');

-- CNPJ: dígitos verificadores (módulo 11)
CREATE OR REPLACE MACRO _d(c, i) AS TRY_CAST(substr(c, i, 1) AS INTEGER);  -- TRY: CNPJ curto não quebra
CREATE OR REPLACE MACRO _dv(s) AS CASE WHEN s % 11 < 2 THEN 0 ELSE 11 - s % 11 END;
CREATE OR REPLACE MACRO cnpj_d1(c) AS _dv(
      5*_d(c,1) + 4*_d(c,2) + 3*_d(c,3) + 2*_d(c,4) + 9*_d(c,5)  + 8*_d(c,6)
    + 7*_d(c,7) + 6*_d(c,8) + 5*_d(c,9) + 4*_d(c,10) + 3*_d(c,11) + 2*_d(c,12));
CREATE OR REPLACE MACRO cnpj_d2(c) AS _dv(
      6*_d(c,1) + 5*_d(c,2) + 4*_d(c,3) + 3*_d(c,4) + 2*_d(c,5)  + 9*_d(c,6)
    + 8*_d(c,7) + 7*_d(c,8) + 6*_d(c,9) + 5*_d(c,10) + 4*_d(c,11) + 3*_d(c,12)
    + 2*cnpj_d1(c));
CREATE OR REPLACE MACRO cnpj_valido(c) AS
    coalesce(regexp_full_match(c, '\d{14}'), false)
    AND c <> repeat(substr(c, 1, 1), 14)
    AND coalesce(_d(c, 13) = cnpj_d1(c) AND _d(c, 14) = cnpj_d2(c), false);

-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stg_oportunidades AS
SELECT
    id_oportunidade, id_cliente, id_vendedor,
    origem,                       norm(origem)        AS origem_norm,
    plano,
    to_num(valor_mrr)             AS valor_mrr,        valor_mrr        AS valor_mrr_raw,
    etapa_atual, status,
    to_date(data_criacao)         AS data_criacao,     data_criacao     AS data_criacao_raw,
    to_date(data_fechamento)      AS data_fechamento,
    to_date(data_assinatura_contrato) AS data_assinatura_contrato,
    motivo_perda,
    TRY_CAST(probabilidade_crm AS INTEGER) AS probabilidade_crm,
    utm_campaign,                 norm(utm_campaign)  AS utm_campaign_norm,
    TRY_CAST(ultima_atualizacao_sistema AS TIMESTAMP) AS ultima_atualizacao_sistema
FROM raw_oportunidades;

CREATE OR REPLACE VIEW stg_clientes AS
SELECT
    id_cliente,
    cnpj                                   AS cnpj_raw,
    regexp_replace(cnpj, '[^0-9]', '', 'g') AS cnpj,
    razao_social,
    setor,                                 norm(setor)        AS setor_norm,
    segmento_crm,                          norm(segmento_crm) AS segmento_norm,
    porte_receita,
    TRY_CAST(num_funcionarios AS INTEGER)  AS num_funcionarios, num_funcionarios AS num_funcionarios_raw,
    cidade_uf,
    to_date(data_criacao)                  AS data_criacao,
    flag_migrado_v2
FROM raw_clientes;

CREATE OR REPLACE VIEW stg_vendedores AS
SELECT
    id_vendedor, nome_vendedor, "time" AS time_vendas,
    to_date(data_admissao)     AS data_admissao,
    to_date(data_desligamento) AS data_desligamento,
    ativo                      AS ativo_raw,
    norm(ativo) IN ('s', 'sim', '1', 'true') AS ativo
FROM raw_vendedores;

CREATE OR REPLACE VIEW stg_historico_etapas AS
SELECT
    id_oportunidade, etapa,
    CASE etapa WHEN 'Novo' THEN 1 WHEN 'Qualificação' THEN 2 WHEN 'Demonstração' THEN 3
               WHEN 'Proposta' THEN 4 WHEN 'Negociação' THEN 5 ELSE 6 END AS ordem_etapa,
    to_date(data_entrada_etapa)   AS data_entrada_etapa,
    id_vendedor_responsavel,
    to_num(valor_mrr_na_etapa)    AS valor_mrr_na_etapa
FROM raw_historico_etapas;

-- Data de referência da extração (última atualização registrada no CRM)
CREATE OR REPLACE VIEW param AS
SELECT CAST(max(ultima_atualizacao_sistema) AS DATE) AS data_extracao FROM stg_oportunidades;
