"""計画を回す時に手で呼ぶ道具の入口。予算の今・会話ごとの量・開いたままの物を、素の値で出す。

  python3 .tooling/work/plan_run.py budget                 口座ごとに、計画の起点から使った % と上限までの残り
  python3 .tooling/work/plan_run.py cost --since <時刻>     その時刻から後の会話を重い順に (タブの題と、分かれば %)
  python3 .tooling/work/plan_run.py leftovers [--no-pr]     repo に開いたまま残る branch・worktree・stash・書きかけ・PR
  python3 .tooling/work/plan_run.py status                 計画の単位の表から、波ごとの ✅/⬜ の木と数

設定は隣の plan-run.toml (`--config` で差し替え)。読むだけで、線を越えても何も止めない。
書くのは、出すのに数秒かかる物差しの覚えだけ (lib/yardstick_store.py)。
引数を読んで lib の判定と読みを呼ぶだけの file で、呼ぶのは人とエージェント。
"""

import argparse
import os
import sys
import time
import tomllib
from collections import defaultdict
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import plan_units  # noqa: E402
import repo_leftovers  # noqa: E402
import usage_records  # noqa: E402
import usage_window  # noqa: E402
import yardstick_store  # noqa: E402

AGENT_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEFAULT_CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "plan-run.toml")
MILLION = 1e6
DEFAULT_TOP = 20


def main() -> int:
    parser = argparse.ArgumentParser(description="Budget, per-session cost and leftovers for a running plan.")
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("budget")
    cost = commands.add_parser("cost")
    cost.add_argument("--since", required=True, help="ISO time, e.g. 2026-11-28T18:00:00+09:00")
    cost.add_argument("--account", default="personal")
    cost.add_argument("--top", type=int, default=DEFAULT_TOP)
    leftovers = commands.add_parser("leftovers")
    leftovers.add_argument("--no-pr", action="store_true")
    commands.add_parser("status")
    args = parser.parse_args()
    started = time.monotonic()
    with open(args.config, "rb") as handle:
        config = tomllib.load(handle)
    if args.command == "budget":
        print_budget(config)
    elif args.command == "cost":
        print_cost(config, datetime.fromisoformat(args.since).timestamp(), args.account, args.top)
    elif args.command == "status":
        print_status(config)
    else:
        print_leftovers(config, with_prs=not args.no_pr)
    print(f"elapsed: {time.monotonic() - started:.1f}s")
    return 0


def print_budget(config: dict) -> None:
    start = config["start"].timestamp()
    rows = usage_records.load_limit_rows()
    plan_agents = set(config.get("plan", {}).get("agents", []))
    account_roots = config.get("account_roots", {})
    uses: list[usage_records.SessionUse] | None = None
    for account, cap in config.get("caps", {}).items():
        use = usage_window.window_use(rows, account, int(start))
        if not use.started:
            latest = usage_window.window_use(rows, account, 0)
            now_pct = f"今の窓 {latest.used_pct:.0f}%・戻り {_clock(latest.resets_at)}" if latest.started else "この機械に記録なし"
            print(f"plan_budget({account}): 起点 {_clock(start)} の前 ({now_pct})・上限 {cap}%")
            continue
        if uses is None:
            uses = usage_records.load_session_uses(start, account_roots=account_roots)
        by_agent: dict[str, float] = defaultdict(float)
        for item in _of_account(uses, account, account_roots):
            by_agent[item.agent] += item.weighted
        yardstick, stick = _yardstick(rows, account, account_roots)
        changed = "・起点の後に窓が戻った (最後の窓だけの値)" if use.window_changed else ""
        if not yardstick:
            print(f"plan_budget({account}): 計画の % は出せない ({stick})・上限 {cap}%・口座の全部 {use.used_pct:.0f}%{changed}")
            continue
        plan_pct = sum(by_agent[agent] for agent in plan_agents) / yardstick
        local_pct = sum(by_agent.values()) / yardstick
        left = usage_window.remaining_to_cap(plan_pct, cap)
        print(f"plan_budget({account}): 計画 {plan_pct:.1f}% / 上限 {cap}% (残り {left:.1f}%)・口座の全部 {use.used_pct:.0f}%・窓の戻り {_clock(use.resets_at)}{changed}")
        shares = " / ".join(f"{agent} {amount / yardstick:.1f}%" for agent, amount in sorted(by_agent.items(), key=lambda kv: -kv[1]))
        print(f"  この機械の会話の計 {local_pct:.1f}% ({shares or 'なし'})・{stick}")


def print_cost(config: dict, since: float, account: str, top: int) -> None:
    account_roots = config.get("account_roots", {})
    uses = _of_account(usage_records.load_session_uses(since, account_roots=account_roots), account, account_roots)
    uses = sorted(uses, key=lambda item: -item.weighted)
    total = sum(item.weighted for item in uses)
    rows = usage_records.load_limit_rows()
    yardstick, stick = _yardstick(rows, account, account_roots)
    progress = usage_window.pct_progress(rows, account, int(since))
    moved = f"・{account} の枠はこの間に {progress:.0f}% 進んだ" if progress is not None else ""
    print(f"cost: {_clock(since)} から後・会話 {len(uses)} 本・重みつきの計 {total / MILLION:.1f}M{moved}・{stick}")
    print("順 | 量 | % の見当 | 応答 | agent | 階層 | タブ")
    for index, item in enumerate(uses[:top], 1):
        pct = f"{item.weighted / yardstick:.2f}%" if yardstick else "-"
        tab = f"{'子 ' if item.is_child else ''}{item.title or '(題なし)'} {item.tab or item.session[:8]}"
        print(f"{index} | {item.weighted / MILLION:.2f}M | {pct} | {item.answers} | {item.agent} | {item.tier or '-'} | {tab}")


def _of_account(uses: list[usage_records.SessionUse], account: str, account_roots: dict[str, str]) -> list[usage_records.SessionUse]:
    """その口座の会話だけを返す。設定に記録の根が無い口座は分けられないので、全部の会話を返す。"""
    if account not in account_roots:
        return uses
    return [item for item in uses if item.account == account]


def _yardstick(rows: list[dict], account: str, account_roots: dict[str, str]) -> tuple[float | None, str]:
    """1% あたりの重みつきの量と、その出どころの 1 文を返す。出せない時は (None, 理由)。

    窓と % が同じ間は覚えた値を返し、7 日ぶんの会話の記録を読み直さない。
    """
    window = usage_window.yardstick_window(rows, account)
    if window is None:
        return None, "物差しなし (10% 以上進んだ窓の記録が無い)"
    begins, resets_at, pct = window
    platform_root = usage_records.platform_root()
    key = yardstick_store.window_key(account, resets_at, pct)
    yardstick = yardstick_store.load(platform_root, key)
    if yardstick is None:
        window_uses = usage_records.load_session_uses(begins, resets_at, account_roots=account_roots)
        yardstick = usage_window.tokens_per_pct(sum(item.weighted for item in _of_account(window_uses, account, account_roots)), pct)
        if yardstick is None:
            return None, "物差しなし (その窓の会話の記録が無い)"
        yardstick_store.save(platform_root, key, yardstick)
    return yardstick, f"物差し 1% = {yardstick / MILLION:.1f}M ({_clock(resets_at)} に戻る窓の実績 {pct:.0f}%。この機械の会話だけで測った値)"


def print_status(config: dict) -> None:
    settings = config.get("status", {})
    path = os.path.expanduser(settings.get("plan", ""))
    if not os.path.isabs(path):
        path = os.path.join(AGENT_ROOT, path)
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        print(f"plan_status: 計画の file を読めない ({path})")
        return
    units = plan_units.parse_units(text, settings.get("units_heading", ""))
    if not units:
        print(f"plan_status: 単位の表が見つからない ({path} の「{settings.get('units_heading', '')}」)")
        return
    for line in plan_units.status_lines(units, plan_units.parse_wave_names(text, settings.get("waves_heading", ""))):
        print(line)


def print_leftovers(config: dict, with_prs: bool) -> None:
    settings = config.get("leftovers", {})
    roots = [os.path.expanduser(root) for root in settings.get("roots", [])]
    gh_command = [os.path.expanduser(part) for part in settings.get("gh", [])] if with_prs else []
    counts: dict[str, int] = defaultdict(int)
    repos = repo_leftovers.find_repos(roots)
    for repo in repos:
        for item in repo_leftovers.list_leftovers(repo, gh_command or None):
            counts[item.kind] += 1
            print(f"{item.repo} | {item.kind} | {item.name} | {item.detail}")
    summary = " / ".join(f"{kind} {count}" for kind, count in sorted(counts.items())) or "なし"
    print(f"leftovers: repo {len(repos)} 本・{summary}")


def _clock(epoch: float | None) -> str:
    return datetime.fromtimestamp(epoch).strftime("%m-%d %H:%M") if epoch else "不明"


if __name__ == "__main__":
    sys.exit(main())
