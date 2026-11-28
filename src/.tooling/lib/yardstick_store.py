"""物差し (7 日枠の 1% あたりの重みつきの量) を、窓ごとにこの機械の状態の置き場へ覚える。

物差しは 7 日ぶんの会話の記録を読み直して出すので数秒かかる。窓と % が同じ間は値が変わらないので、
1 回出した値を鍵つきで置き、次からはそれを返す。読み書きだけの file で、呼ぶのは work/plan_run.py。
書けない・読めない時は覚えずに済ませる (呼ぶ側が出し直す)。
"""

import json
import os

STORE_PARTS = ("state", "token-usage", "yardstick.json")


def store_path(platform_root: str) -> str:
    return os.path.join(platform_root, *STORE_PARTS)


def window_key(account: str, resets_at: int, pct: float) -> str:
    """口座・窓の戻る時刻・その窓の % (整数に丸めた値) から鍵を作る。% が進めば鍵が変わり、出し直しになる。"""
    return f"{account}:{resets_at}:{pct:.0f}"


def load(platform_root: str, key: str) -> float | None:
    """覚えた物差しを返す。無い・読めない時は None。"""
    try:
        with open(store_path(platform_root), encoding="utf-8") as handle:
            value = json.load(handle).get(key)
    except (OSError, ValueError, AttributeError):
        return None
    return float(value) if isinstance(value, (int, float)) and value > 0 else None


def save(platform_root: str, key: str, yardstick: float) -> None:
    """同じ口座の古い鍵を落として、新しい値を 1 つ覚える。書けない時は何もしない。"""
    path = store_path(platform_root)
    try:
        with open(path, encoding="utf-8") as handle:
            stored = json.load(handle)
    except (OSError, ValueError):
        stored = {}
    account = key.split(":", 1)[0]
    kept = {name: value for name, value in stored.items() if name.split(":", 1)[0] != account} if isinstance(stored, dict) else {}
    kept[key] = yardstick
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w", encoding="utf-8") as handle:
            json.dump(kept, handle)
        os.replace(path + ".tmp", path)
    except OSError:
        return
