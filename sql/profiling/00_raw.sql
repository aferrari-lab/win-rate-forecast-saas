-- =====================================================================
-- 00 · Camada RAW
-- Tabelas com a cópia fiel dos CSVs, tudo como VARCHAR (all_varchar): nada é inferido,
-- para que valores sujos ("975,60", "n/d", "16/03/2026") apareçam como são.
-- Gravadas como TABLE (não VIEW) para o banco funcionar fora da raiz do projeto (ex.: DBeaver).
-- O pipeline roda a partir da raiz (caminhos relativos) e recria as tabelas a cada execução.
-- =====================================================================

CREATE OR REPLACE TABLE raw_oportunidades AS
SELECT * FROM read_csv('data/raw/oportunidades.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw_clientes AS
SELECT * FROM read_csv('data/raw/clientes.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw_vendedores AS
SELECT * FROM read_csv('data/raw/vendedores.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw_historico_etapas AS
SELECT * FROM read_csv('data/raw/historico_etapas.csv', header = true, all_varchar = true);
