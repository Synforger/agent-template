"""起動の検査の行ごとの持ち主の階層の対応表 (= データだけ。 判定は owner_routing.py)。

`owner_routing.py` が読む。 行を足す・持ち主を変える時はこの file の定数だけを直す。
階層は、 親が `normal`、 それ以外は agent の folder からの path (`projects/<P>` / `projects/<P>/subprojects/<S>`)。
"""

NORMAL = "normal"

# 持ち主が normal の行 (= 機械とエージェント自身の物) → その行が健全な時の印の正規表現。
# 印に当たらない行は警告で、 normal 以外のタブには `others:` の 1 行にまとめて出す。
# remote_sync は載せない: 全部のタブが同じ checkout を読むので、 遅れはどのタブにも自分の事として出す
NORMAL_ROWS: dict[str, str] = {
    "company_terms": r"^company_terms: (0 \(clean\)|\(skipped)",
    "git_guard": r"^git_guard: armed",
    "agent_guard": r"^agent_guard: installed",
    "claude_settings": r"^claude_settings: (in sync|distributed)",
    "model_pin": r"^model_pin: (ok|\(skipped)",
    "effort_pin": r"^effort_pin: (ok|\(skipped)",
    "guard_deploy": r"^guard_deploy: (ok|\(skipped)",
    "clone_deploy": r"^clone_deploy\([^)]*\): ok",
    "platform_check": r"^platform_check: clean",
}

# `tool_actions(<道具>)` の行が健全な時の印。 持ち主は下の表で決める
TOOL_ACTIONS_HEALTHY = r"^tool_actions\([^)]*\): ok"
