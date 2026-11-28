"""会話の応答 1 つの usage を、 model ごとの API の単価で $ に直す (= 7 日枠の減り方を測る単位)。

file にも時計にも触らない計算だけの file で、 呼ぶのは lib/usage_records.py。 単価の表は work/model-prices.toml で、
work/plan_run.py が読んで `price_table` に渡す。
"""

from dataclasses import dataclass

MILLION = 1e6
#: 記録に cache の持ち時間の内訳が無い書き込みを数える持ち時間 (= API の既定)
DEFAULT_CACHE_WRITE = "ephemeral_5m"
#: usage の `cache_creation` の内訳の欄の名前 → 単価の表の持ち時間の名前
CACHE_WRITE_FIELDS = {"ephemeral_5m_input_tokens": "ephemeral_5m", "ephemeral_1h_input_tokens": "ephemeral_1h"}
TOKEN_FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


@dataclass(frozen=True)
class ModelPrice:
    """model 1 つの単価 ($ / 100 万 token)。"""

    input: float
    output: float
    cache_read: float


@dataclass(frozen=True)
class PriceTable:
    """model ごとの単価と、 cache の書き込みが入力の何倍か (持ち時間ごと)。"""

    models: dict[str, ModelPrice]
    cache_write: dict[str, float]


def price_table(data: dict) -> PriceTable:
    """単価の表の file (`model-prices.toml`) を読んだ dict から表を作る。 欠けた欄の model は表に入れない。"""
    models: dict[str, ModelPrice] = {}
    for name, price in (data.get("models") or {}).items():
        try:
            models[name] = ModelPrice(float(price["input"]), float(price["output"]), float(price["cache_read"]))
        except (KeyError, TypeError, ValueError):
            continue
    cache_write = {name: float(ratio) for name, ratio in (data.get("cache_write") or {}).items()}
    return PriceTable(models, cache_write)


def token_count(usage: dict) -> int:
    """応答 1 つの token の数 (入力・cache の書き込みと読み・出力の和)。"""
    return sum(int(usage.get(field) or 0) for field in TOKEN_FIELDS)


def message_cost(usage: dict, model: str, table: PriceTable) -> float | None:
    """応答 1 つの $。 model が単価の表に無い時は None (= token が 0 の応答は 0.0)。"""
    if token_count(usage) == 0:
        return 0.0
    price = table.models.get(model)
    if price is None:
        return None
    written = int(usage.get("cache_creation_input_tokens") or 0)
    breakdown = usage.get("cache_creation") if isinstance(usage.get("cache_creation"), dict) else {}
    write_cost = 0.0
    for field, ttl in CACHE_WRITE_FIELDS.items():
        tokens = int(breakdown.get(field) or 0)
        write_cost += tokens * price.input * table.cache_write.get(ttl, 1.0)
        written -= tokens
    write_cost += max(written, 0) * price.input * table.cache_write.get(DEFAULT_CACHE_WRITE, 1.0)
    read_cost = int(usage.get("cache_read_input_tokens") or 0) * price.cache_read
    plain_cost = int(usage.get("input_tokens") or 0) * price.input + int(usage.get("output_tokens") or 0) * price.output
    return (plain_cost + write_cost + read_cost) / MILLION
