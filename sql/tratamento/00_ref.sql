-- =====================================================================
-- 00 · Referências e macros de padronização
-- Depende de sql/profiling/00_raw.sql e 01_staging.sql (macros norm,
-- to_num, to_date).
--
-- data/ref/de_para.csv  -> campo, chave (texto normalizado), valor_padrao
-- A chave é norm(valor): minúsculo, sem acento, só [a-z0-9]. Assim
-- "Varejo", "VAREJO" e "varejo " caem numa única linha do de-para.
-- Para incluir uma grafia nova: acrescente uma linha no CSV.
-- =====================================================================

CREATE OR REPLACE TABLE ref_de_para AS
SELECT trim(campo) AS campo, trim(chave) AS chave, trim(valor_padrao) AS valor_padrao,
       exemplo_origem, observacao
FROM read_csv('data/ref/de_para.csv', header = true, all_varchar = true);

-- Lookup no de-para; NULL se não houver mapeamento
CREATE OR REPLACE MACRO dp(campo_, valor_) AS (
    SELECT any_value(r.valor_padrao) FROM ref_de_para r
    WHERE r.campo = campo_ AND r.chave = norm(valor_)
);

-- Regras gerais de nulo/vazio
CREATE OR REPLACE MACRO txt(s)  AS coalesce(nullif(trim(s), ''), 'NA');   -- texto vazio/nulo -> 'NA'
CREATE OR REPLACE MACRO num0(x) AS coalesce(x, 0);                          -- número nulo -> 0

-- Padroniza via de-para; sem mapeamento mantém o original (aparece no QA)
CREATE OR REPLACE MACRO padroniza(campo_, valor_) AS
    coalesce(dp(campo_, valor_), txt(valor_));
