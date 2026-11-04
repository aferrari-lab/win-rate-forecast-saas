# Win Rate Forecast — SaaS B2B

Análise de win rate de oportunidades de um CRM e proposta de forecast segmentado,
substituindo a taxa de conversão única usada hoje.

## Problema
A área comercial projetava o fechamento de vendas com uma única taxa (~33%) para
todos os clientes. A suspeita era que cada perfil de cliente converte de forma diferente.

## O que foi feito
- **Tratamento:** limpeza e padronização da extração bruta do CRM em SQL (DuckDB),
  com testes de qualidade e de granularidade.
- **Win rate:** taxa de ganho por canal, setor, porte e vendedor, com intervalo de confiança.
- **Forecast:** taxas por canal × setor, ponderadas por MRR e ajustadas para grupos pequenos.
- **Painel:** dashboard em Streamlit com filtros e comparativos.

## Principal conclusão
O win rate varia por canal e setor. A taxa única distorce a projeção de receita,
principalmente nos negócios de maior valor.

## Stack
Python · DuckDB (SQL) · Streamlit · Plotly · pandas. Somente ferramentas open source.

## Como rodar
```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python src\winrate\pipeline.py
streamlit run app\Home.py
```

## Estrutura
```
sql/          tratamento e análises em SQL
src/winrate/  pipeline que gera o banco
app/          dashboard Streamlit
data/raw/     extração do CRM (dados fictícios)
data/ref/     tabelas de de-para e premissas
```

## Dados
Os dados em `data/raw/` são fictícios e simulam uma extração bruta de CRM,
sem nenhum tratamento. O pipeline gera o banco DuckDB a partir deles.
