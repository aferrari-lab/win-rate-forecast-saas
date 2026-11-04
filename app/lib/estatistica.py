"""Funções estatísticas do painel."""
import numpy as np
import pandas as pd

Z_95 = 1.96  # nível de confiança de 95%


def wilson(vendas, oportunidades, z: float = Z_95):
    """Intervalo de Wilson (Wilson Score Interval) para uma taxa de conversão.

    Aceita números ou arrays/Series (calcula elemento a elemento).
    Retorna (p_hat, limite_inferior, limite_superior), em proporção (0 a 1).

        p_hat       = vendas / oportunidades
        denominador = 1 + z² / n
        centro      = (p_hat + z² / (2n)) / denominador
        delta       = z * sqrt(p_hat(1 - p_hat)/n + z² / (4n²)) / denominador
        limites     = centro ± delta
    """
    vendas = np.asarray(vendas, dtype=float)
    n = np.asarray(oportunidades, dtype=float)
    with np.errstate(divide="ignore", invalid="ignore"):
        p_hat = vendas / n
        denominador = 1 + (z**2 / n)
        centro = (p_hat + (z**2 / (2 * n))) / denominador
        delta = (z * ((p_hat * (1 - p_hat) / n) + (z**2 / (4 * n**2))) ** 0.5) / denominador
    return p_hat, centro - delta, centro + delta


def projecao_wilson(p_base: float, volume_mensal: float, meses: int, inicio: pd.Timestamp,
                    z: float = Z_95) -> pd.DataFrame:
    """Projeção do win rate para os próximos `meses` com faixa de Wilson.

    A cada mês futuro a amostra acumulada cresce `volume_mensal` oportunidades
    fechadas; as vendas esperadas são p_base x amostra. O win rate esperado fica
    em p_base e a faixa de Wilson estreita conforme a amostra aumenta: ela mostra
    onde o win rate REALIZADO acumulado deve cair, com 95% de confiança, se a
    taxa verdadeira for p_base.
    """
    k = np.arange(1, meses + 1)
    oportunidades = volume_mensal * k
    vendas = p_base * oportunidades
    p_hat, inf, sup = wilson(vendas, oportunidades, z)
    datas = pd.date_range(inicio, periods=meses, freq="MS")
    return pd.DataFrame({"mes": datas, "oportunidades_acum": oportunidades, "vendas_esperadas": vendas,
                         "win_rate": 100 * p_hat, "limite_inferior": 100 * inf, "limite_superior": 100 * sup})
