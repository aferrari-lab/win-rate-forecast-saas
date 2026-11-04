"""Tema visual único do dashboard: identidade visual, cores, template Plotly e formatadores.

Paleta institucional (azul-marinho e azuis claros):
  marinho #29354D (símbolo e textos) · azul #B1CFF5 · azul-claro #F3F8FE (fundos)
  verde-menta #86DFA7 (botões de ação) · amarelo #F9BD38 · azul primário #1366C9 · fonte Poppins

Regras:
  * Interface (textos, fundos, realces) usa a marca.
  * Séries de dados usam a paleta categórica abaixo, validada para daltonismo
    (dataviz/validate_palette.js: todos os checks PASS). Slot 1 = azul primário da
    marca. Marinho e menta NÃO entram como série: o marinho reprova (escuro e
    acinzentado demais) e o menta some sobre o branco.
  * Ordem fixa: nunca reordenar nem gerar cores novas; 9ª série vira "Outros".
"""
import pandas as pd
import plotly.graph_objects as go
import plotly.io as pio

# Categórica em ordem fixa (slot 1..8)
CATEGORICA = ["#1366c9", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
# Sequencial (azul, claro -> escuro) para magnitudes / mapas de calor
SEQUENCIAL = ["#e8f1fc", "#b1cff5", "#7fb0ec", "#4a8ddf", "#1366c9", "#164f97", "#29354d"]  # azul-claro -> marinho da marca
# Status: reservadas para bom/ruim, nunca usar como "série 4"
BOM, ALERTA, RUIM = "#0ca30c", "#fab219", "#d03b3b"

# Cores da interface
MARINHO, AZUL_MARCA, AZUL_CLARO, MENTA, AMARELO_MARCA, AZUL_PRIMARIO = (
    "#29354d", "#b1cff5", "#f3f8fe", "#86dfa7", "#f9bd38", "#1366c9")
FONTE = "Poppins, Arial, sans-serif"

SUPERFICIE, TEXTO, TEXTO_2, MUTED, GRADE, EIXO = "#ffffff", MARINHO, "#4f5464", "#70757f", "#dde0e4", "#c4c8ce"

# Cor fixa por entidade: a cor segue o grupo, não a posição no gráfico
CORES_CANAL = {"Inbound": CATEGORICA[0], "Outbound": CATEGORICA[1], "Parceiro": CATEGORICA[2], "Evento": CATEGORICA[3]}
CORES_NEGOCIO = {"Novo cliente": CATEGORICA[0], "Expansão": CATEGORICA[2],
                 "Upsell": CATEGORICA[2], "Cross-sell": CATEGORICA[3], "Mesmo plano": CATEGORICA[4],
                 "Plano inferior": CATEGORICA[6]}

pio.templates["winrate"] = go.layout.Template(
    # barras: separação de 1px na cor do fundo entre segmentos empilhados
    data=dict(bar=[go.Bar(marker=dict(line=dict(width=1, color=SUPERFICIE)))]),
    layout=dict(
        font=dict(family=FONTE, size=13, color=TEXTO_2),
        # título no topo e legenda logo abaixo dele, sem sobrepor
        title=dict(font=dict(size=15, color=TEXTO), x=0, xanchor="left", y=0.98, yanchor="top"),
        paper_bgcolor=SUPERFICIE, plot_bgcolor=SUPERFICIE,
        colorway=CATEGORICA,
        xaxis=dict(gridcolor=GRADE, linecolor=EIXO, zeroline=False, tickfont=dict(color=MUTED)),
        yaxis=dict(gridcolor=GRADE, linecolor=EIXO, zeroline=False, tickfont=dict(color=MUTED)),
        legend=dict(orientation="h", yanchor="bottom", y=1.0, x=0, title_text=""),
        hoverlabel=dict(bgcolor="white", bordercolor=AZUL_MARCA, font=dict(family=FONTE, size=12, color=TEXTO)),
        margin=dict(l=10, r=10, t=90, b=10),
        bargap=0.25,
        barcornerradius=4,
    )
)
pio.templates.default = "winrate"


def brl(v, casas=0):
    """R$ no padrão brasileiro: 1.234.567 / 1.234,56."""
    if v is None or v != v:
        return "—"
    s = f"{v:,.{casas}f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return f"R$ {s}"


def brl_curto(v):
    if v is None or v != v:
        return "—"
    for lim, suf in [(1e9, "bi"), (1e6, "mi"), (1e3, "mil")]:
        if abs(v) >= lim:
            return f"R$ {v / lim:,.1f} {suf}".replace(".", ",")
    return brl(v)


def num(v, casas=0):
    if v is None or v != v:
        return "—"
    return f"{v:,.{casas}f}".replace(",", "X").replace(".", ",").replace("X", ".")


def pct(v, casas=1):
    return "—" if v is None or v != v else f"{num(v, casas)}%"


def _vazio(v):
    try:
        return bool(pd.isna(v))
    except (TypeError, ValueError):
        return False


def _sinal(v, casas, suf):
    if _vazio(v):
        return "—"
    return ("+" if v > 0 else "") + num(v, casas) + suf


# Tipos de formato aceitos por tabela(): nome -> função que recebe o número e devolve o texto
FORMATOS = {
    "int": num,                                   # 12.345
    "dec1": lambda v: num(v, 1),                  # 12.345,6
    "brl": brl,                                   # R$ 1.234.567
    "brl2": lambda v: brl(v, 2),                  # R$ 1.234,56
    "pct": pct,                                   # 33,0%
    "var_pct": lambda v: _sinal(v, 1, "%"),       # +4,8%
    "var_pp": lambda v: _sinal(v, 1, " pp"),      # -0,6 pp
    "dias": lambda v: "—" if v is None or v != v else f"{num(v, 1)} dias",
    "meses": lambda v: "—" if v is None or v != v else f"{num(v, 1)} meses",
    "vezes": lambda v: "—" if v is None or v != v else f"{num(v, 2)}x",
}


def _seguro(f):
    return lambda v: "—" if _vazio(v) else f(v)


def tabela(df: pd.DataFrame, formatos: dict | None = None, rotulos: dict | None = None,
           por_linha: list | None = None):
    """Tabela com números no padrão brasileiro, pronta para st.dataframe.

    formatos : {coluna: tipo} para colunas inteiras (tipos em FORMATOS)
    rotulos  : {coluna: "Nome exibido"} para renomear colunas
    por_linha: [(máscara booleana, [colunas], tipo)] quando a mesma coluna mistura
               unidades em linhas diferentes (ex.: R$ numa linha e % na outra)
    Os valores continuam numéricos: a ordenação ao clicar no cabeçalho segue o número.
    """
    rotulos = rotulos or {}
    d = df.rename(columns=rotulos)
    sty = d.style.format(na_rep="—")  # vazio vira "—" em todas as colunas
    for col, tipo in (formatos or {}).items():
        c = rotulos.get(col, col)
        if c in d.columns:
            sty = sty.format(_seguro(FORMATOS[tipo]), subset=[c], na_rep="—")
    for mascara, cols, tipo in (por_linha or []):
        idx = d.index[pd.Series(mascara, index=d.index).fillna(False).astype(bool)]
        cs = [rotulos.get(c, c) for c in cols]
        if len(idx):
            sty = sty.format(_seguro(FORMATOS[tipo]), subset=pd.IndexSlice[idx, cs], na_rep="—")
    return sty
