"""7 日枠の記録の行と、会話ごとの量から、計画の予算の今 (使った %・上限までの残り・1% あたりの量) を計算する。

file にも時計にも触らない判定だけの file で、呼ぶのは work/plan_run.py。行は statusline が書く
`rate-limits.jsonl` の形 (`timestamp`・`account_id`・`seven_day_pct`・`seven_day_resets_at`)。
"""

from dataclasses import dataclass

MIN_PCT_FOR_YARDSTICK = 10.0
WEEK_S = 7 * 24 * 3600


@dataclass(frozen=True)
class WindowUse:
    """口座 1 つの、計画の起点から後の 7 日枠の使われ方。"""

    account: str
    started: bool
    used_pct: float
    resets_at: int | None
    window_changed: bool


def _latest_window(rows: list[dict], account: str) -> tuple[int | None, list[dict]]:
    """その口座の一番新しい窓 (戻る時刻が一番後の物) と、その窓の行を返す。

    長く開いたままの session は古い値の行を書き続けるので、窓は最後の行でなく戻る時刻の最大で決める。
    """
    mine = [r for r in rows if r.get("account_id") == account and r.get("seven_day_pct") is not None and r.get("seven_day_resets_at")]
    if not mine:
        return None, []
    resets_at = max(r["seven_day_resets_at"] for r in mine)
    return resets_at, [r for r in mine if r["seven_day_resets_at"] == resets_at]


def window_use(rows: list[dict], account: str, start: int) -> WindowUse:
    """起点 `start` (epoch 秒) より後に戻る窓のうち一番新しい物の % を返す。% は窓の中の最大で読む。

    そういう窓の行が無ければ `started=False`。起点の後に窓が 2 つ以上在れば `window_changed=True`
    (予算は 1 つの窓の中で数える)。
    """
    resets_at, window = _latest_window(rows, account)
    if resets_at is None or resets_at <= start:
        return WindowUse(account, False, 0.0, None, False)
    later = {r["seven_day_resets_at"] for r in rows if r.get("account_id") == account and (r.get("seven_day_resets_at") or 0) > start}
    return WindowUse(account, True, max(float(r["seven_day_pct"]) for r in window), resets_at, len(later) > 1)


def tokens_per_pct(total_weighted: float, used_pct: float) -> float | None:
    """口座の全部の会話の重みつきの量と、同じ間に進んだ % から、1% あたりの量を返す。% が小さすぎる間は None。"""
    if used_pct < MIN_PCT_FOR_YARDSTICK or total_weighted <= 0:
        return None
    return total_weighted / used_pct


def share_pct(part_weighted: float, total_weighted: float, used_pct: float) -> float:
    """口座の % のうち、ある組 (agent・タブ) の会話が占める分を返す。"""
    if total_weighted <= 0:
        return 0.0
    return used_pct * part_weighted / total_weighted


def remaining_to_cap(plan_pct: float, cap_pct: float) -> float:
    """計画の上限までの残りの %。超えていれば負。"""
    return cap_pct - plan_pct


def yardstick_window(rows: list[dict], account: str) -> tuple[int, int, float] | None:
    """物差しを取る窓を返す: % が `MIN_PCT_FOR_YARDSTICK` 以上進んだ窓のうち一番新しい物の (始まり, 戻り, %)。

    短い間の % は整数の丸めと別の機械の分で大きくぶれるので、十分に進んだ窓だけを使う。無ければ None。
    """
    by_window: dict[int, float] = {}
    for row in rows:
        if row.get("account_id") != account or row.get("seven_day_pct") is None or not row.get("seven_day_resets_at"):
            continue
        resets_at = row["seven_day_resets_at"]
        by_window[resets_at] = max(by_window.get(resets_at, 0.0), float(row["seven_day_pct"]))
    usable = [resets_at for resets_at, pct in by_window.items() if pct >= MIN_PCT_FOR_YARDSTICK]
    if not usable:
        return None
    resets_at = max(usable)
    return resets_at - WEEK_S, resets_at, by_window[resets_at]


def pct_progress(rows: list[dict], account: str, since: int) -> float | None:
    """`since` から後に、その口座の一番新しい窓の % が何 % 進んだかを返す。

    % は窓の中で増えるだけなので、`since` より前の最大と、窓の全部の最大の差で読む (古い値を持つ行に引かれない)。
    窓が `since` の後に始まっていれば窓の頭からの値。行が無ければ None。
    """
    _, window = _latest_window(rows, account)
    if not window:
        return None
    before = [float(r["seven_day_pct"]) for r in window if (r.get("timestamp") or 0) < since]
    return max(float(r["seven_day_pct"]) for r in window) - (max(before) if before else 0.0)
