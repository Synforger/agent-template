"""7 日枠の記録の行と、会話ごとの量から、計画の予算の今 (使った %・上限までの残り・1% あたりの $) を計算する。

file にも時計にも触らない判定だけの file で、呼ぶのは work/plan_run.py。行は statusline が書く
`rate-limits.jsonl` の形 (`timestamp`・`account_id`・`seven_day_pct`・`seven_day_resets_at`)。
口座の契約を変えると、窓の途中で枠の大きさが変わり % が測り直される (= 51% から 1% へ落ちた実例)。
その所を「1 時間ごとの最大が前の 1 時間の最大より `RESIZE_DROP_PCT` 以上落ちた所」で見つけ、物差しと公式の値はその後だけで読む。
"""

from dataclasses import dataclass

MIN_PCT_FOR_YARDSTICK = 10.0
WEEK_S = 7 * 24 * 3600
#: 枠の大きさが変わったと読む、1 時間ごとの最大の落ち幅 (古い値を持つ session の行は最大を下げないので、最大だけを比べる)
RESIZE_DROP_PCT = 10.0
BUCKET_S = 3600
#: 公式の値と会話からの値が離れたと言う倍率と、公式の値が整数に丸められている分の幅 (% の点)
DIVERGE_RATIO = 1.25
ROUNDING_PCT = 1.0


@dataclass(frozen=True)
class YardstickWindow:
    """物差しを測る間: その窓の戻る時刻・測る間の始まり・その間に進んだ %・枠の大きさが変わった後だけか・今の窓か。"""

    resets_at: int
    begins: int
    pct: float
    after_resize: bool
    is_current: bool


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


def cost_per_pct(total_cost: float, used_pct: float) -> float | None:
    """口座の全部の会話の $ と、同じ間に進んだ % から、1% あたりの $ を返す。% が小さすぎる間は None。"""
    if used_pct < MIN_PCT_FOR_YARDSTICK or total_cost <= 0:
        return None
    return total_cost / used_pct


def remaining_to_cap(plan_pct: float, cap_pct: float) -> float:
    """計画の上限までの残りの %。超えていれば負。"""
    return cap_pct - plan_pct


def resize_at(rows: list[dict], account: str, resets_at: int) -> int | None:
    """その窓の中で枠の大きさが変わった一番後の時刻 (= % が落ちた 1 時間の頭)。変わっていなければ None。"""
    peaks: dict[int, float] = {}
    for row in _window_rows(rows, account, resets_at):
        bucket = int(row.get("timestamp") or 0) // BUCKET_S * BUCKET_S
        peaks[bucket] = max(peaks.get(bucket, 0.0), float(row["seven_day_pct"]))
    found = None
    previous = None
    for bucket in sorted(peaks):
        if previous is not None and peaks[bucket] <= previous - RESIZE_DROP_PCT:
            found = bucket
        previous = peaks[bucket]
    return found


def yardstick_window(rows: list[dict], account: str, now: float) -> YardstickWindow | None:
    """物差しを測る間を返す: 戻り終えた窓のうち、% が `MIN_PCT_FOR_YARDSTICK` 以上進んだ一番新しい物。

    今の窓で測ると、会話から積んだ値が公式の値と同じ物で割られ、離れたかを見られないので、戻り終えた窓を先に使う。
    無ければ今の窓。枠の大きさが変わった窓は、変わった後だけで測る。どれも足りなければ None。
    """
    candidates: list[YardstickWindow] = []
    for resets_at in sorted({int(r["seven_day_resets_at"]) for r in _account_rows(rows, account)}, reverse=True):
        begins = resets_at - WEEK_S
        resized = resize_at(rows, account, resets_at)
        if resized is not None:
            begins = resized
        pct = max((float(r["seven_day_pct"]) for r in _window_rows(rows, account, resets_at) if (r.get("timestamp") or 0) >= begins), default=0.0)
        if pct >= MIN_PCT_FOR_YARDSTICK:
            candidates.append(YardstickWindow(resets_at, begins, pct, resized is not None, resets_at > now))
    finished = [window for window in candidates if not window.is_current]
    return (finished or candidates or [None])[0]


def pct_progress(rows: list[dict], account: str, since: int) -> float | None:
    """`since` から後に、その口座の一番新しい窓の % が何 % 進んだかを返す。

    % は窓の中で増えるだけなので、`since` より前の最大と、窓の全部の最大の差で読む (古い値を持つ行に引かれない)。
    窓が `since` の後に始まっていれば窓の頭からの値。`since` の後に枠の大きさが変わっていれば、変わった後の値
    (= 前の大きさの分は足せないので数えない)。行が無ければ None。
    """
    resets_at, window = _latest_window(rows, account)
    if not window:
        return None
    resized = resize_at(rows, account, resets_at)
    if resized is not None and resized > since:
        return max(float(r["seven_day_pct"]) for r in window if (r.get("timestamp") or 0) >= resized)
    before = [float(r["seven_day_pct"]) for r in window if (r.get("timestamp") or 0) < since and (resized is None or (r.get("timestamp") or 0) >= resized)]
    after = [float(r["seven_day_pct"]) for r in window if resized is None or (r.get("timestamp") or 0) >= resized]
    return max(after) - (max(before) if before else 0.0)


def diverges(official_pct: float, estimate_pct: float) -> bool:
    """公式の値と会話から積んだ値が `DIVERGE_RATIO` 倍より離れているか。公式の値の丸めの幅の分は離れたと数えない。"""
    high = official_pct + ROUNDING_PCT
    low = max(official_pct - ROUNDING_PCT, 0.0)
    return estimate_pct > high * DIVERGE_RATIO or estimate_pct * DIVERGE_RATIO < low


def _account_rows(rows: list[dict], account: str) -> list[dict]:
    return [r for r in rows if r.get("account_id") == account and r.get("seven_day_pct") is not None and r.get("seven_day_resets_at")]


def _window_rows(rows: list[dict], account: str, resets_at: int) -> list[dict]:
    return [r for r in _account_rows(rows, account) if r["seven_day_resets_at"] == resets_at]
