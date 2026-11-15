"""道具の repo の Actions の結果 (= `gh` の JSON) から、 赤か緑かと起動の検査の行を決める判定 (= 外の命令に触らない)。

`tool_actions.py` が呼ぶ。 develop の最新の commit の結果は、 その commit に直接の run が在ればそれを、 無ければ
(= pull_request でだけ走る repo を squash merge した時) その commit を作った PR の検査の結果を使う。
赤に数えるのは、 結果が出て失敗した物 (failure / timed_out / startup_failure /
action_required / error)。 走っている最中・取り消し・skip・中立は赤に数えない (= まだ結果が無い、 または失敗ではない)。
"""

RED_RESULTS = frozenset({"failure", "timed_out", "startup_failure", "action_required", "error"})
SHORT_SHA_LENGTH = 7


def is_red(result: str | None) -> bool:
    """Actions の結果の語 (= 大文字小文字は問わない) が失敗か。"""
    return (result or "").lower() in RED_RESULTS


def red_workflows(runs: list[dict]) -> list[str]:
    """`gh run list --commit <sha>` の run (= 新しい順) から、 workflow ごとの最新の run が赤の workflow の名前。

    同じ commit で流し直した run は、 新しい方が古い方の結果を置き換える。"""
    latest: dict[str, dict] = {}
    for run in runs:
        latest.setdefault(run.get("workflowName") or run.get("name") or "?", run)
    return [name for name, run in latest.items() if is_red(run.get("conclusion"))]


def red_pull_requests(pulls: list[dict]) -> list[int]:
    """`gh pr list --json number,statusCheckRollup` から、 検査の結果に赤が 1 つでも在る PR の番号。"""
    red = []
    for pull in pulls:
        checks = pull.get("statusCheckRollup") or []
        if any(is_red(check.get("conclusion") or check.get("state")) for check in checks):
            red.append(pull["number"])
    return red


def branch_state(runs: list[dict], merged_pulls: list[dict], sha: str) -> tuple[list[str], str]:
    """追う branch の最新の commit の (赤の名前, 何で見たか)。 直接の run、 無ければ merge した PR の検査、 どちらも無ければ見る物が無い。"""
    if runs:
        return red_workflows(runs), f"{len(runs)} run(s)"
    for pull in merged_pulls:
        if (pull.get("mergeCommit") or {}).get("oid") == sha:
            checks = pull.get("statusCheckRollup") or []
            red = [f"merged PR #{pull['number']}"] if red_pull_requests([pull]) else []
            return red, f"{len(checks)} check(s) of merged PR #{pull['number']}"
    return [], "no run and no merged PR to read"


def verdict_line(tool: str, branch: str, sha: str, branch_red: list[str], basis: str, red_pulls: list[int],
                 open_count: int) -> str:
    """道具 1 本の結果の行 (`tool_actions(<名前>): ok (…)` か `RED develop` / `RED PR #<番号>` の並び)。"""
    short = sha[:SHORT_SHA_LENGTH]
    if not branch_red and not red_pulls:
        return f"tool_actions({tool}): ok ({branch} {short}: {basis}; {open_count} open PR(s), none red)"
    parts = []
    if branch_red:
        parts.append(f"RED {branch} ({short}: {', '.join(branch_red)})")
    parts += [f"RED PR #{number}" for number in red_pulls]
    return f"tool_actions({tool}): " + ", ".join(parts)


def unknown_line(tool: str, reason: str) -> str:
    """結果を取れなかった道具の行。"""
    return f"tool_actions({tool}): UNKNOWN ({reason})"
