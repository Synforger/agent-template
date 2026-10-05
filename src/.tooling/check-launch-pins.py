#!/usr/bin/env python3
"""起動の model と effort が launcher の値のまま効いているかを見る (= startup-status の 2 行)。

model_pin: 起動の経路のどこかが版つき id (claude-opus-5) や変種の接尾辞 (opus[1m]) を名指ししていないか。
  見る場所 = launcher の MODEL / shell の設定 file の --model / 各 config dir の settings.json の model
  (= /model が書き戻す。 launcher を通る起動には効かないが、 素の claude はこれで決まる)。
effort_pin: launcher の --effort が何かに上書きされていないか。
  見る場所 = shell の設定 file の CLAUDE_CODE_EFFORT_LEVEL (= 環境変数は --effort に勝つ。 2026-09-28、
  launcher は high を渡し .zshenv の medium が効いていた session で CLAUDE_EFFORT=medium を実測) と、
  launcher から起動した session の実効値 CLAUDE_EFFORT。 launcher を通った session かどうかは、
  launcher が session に渡す階層の環境変数 (= launcher の `os.environ["…_TIER"] = …` の行が名指す) で見分ける。

  python3 .tooling/check-launch-pins.py   (= エージェントの repo の root で。 AGENT_ROOT / HOME で差し替え可)
"""
import json
import os
import re
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
ROOT = Path(os.environ.get("AGENT_ROOT", Path(__file__).resolve().parents[1]))
LAUNCHER = ROOT / ".tooling/lib/claude-launch.py"
SHELL_FILES = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile"]

PINNED_MODEL = re.compile(r"^claude-|\[")
SHELL_MODEL = re.compile(r"--model[= ]+.?(claude-[a-z]+-[0-9]|[a-z]+\[)")
SHELL_EFFORT = re.compile(r"^\s*(export\s+)?CLAUDE_CODE_EFFORT_LEVEL=")
# launcher が、 自分の起動した session に渡す階層の環境変数
LAUNCH_MARK = re.compile(r'os\.environ\["([A-Z][A-Z0-9_]*_TIER)"\]\s*=')


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def launcher_value(src: str, name: str) -> str:
    m = re.search(rf'^{name} = "([^"]*)"', src, re.M)
    return m.group(1) if m else ""


def short(path: Path) -> str:
    return str(path).replace(str(HOME), "~", 1)


def settings_files() -> list[Path]:
    """各 config dir の設定 (= `~/.claude` と、 口座ごとに分けた `~/.claude-*`)。"""
    return sorted(HOME.glob(".claude*/settings.json"))


def shell_hits(pattern: re.Pattern) -> list[str]:
    hits = []
    for name in SHELL_FILES:
        lines = read(HOME / name).splitlines()
        if any(pattern.search(line) and not line.lstrip().startswith("#") for line in lines):
            hits.append(name.lstrip("."))
    return hits


def model_pin(src: str) -> str:
    model = launcher_value(src, "MODEL")
    if not model or '"--model"' not in src:
        return "model_pin: UNPINNED (launcher passes no --model; the global settings default decides)"
    pinned = []
    if model.startswith("claude-"):
        pinned.append(f"launcher({model} = 版を名指し)")
    elif "[" in model:
        pinned.append(f"launcher({model} = 変種の接尾辞)")
    pinned += shell_hits(SHELL_MODEL)
    for path in settings_files():
        try:
            value = json.loads(read(path) or "{}").get("model", "")
        except ValueError:
            continue
        if isinstance(value, str) and PINNED_MODEL.search(value):
            pinned.append(f"settings({short(path)} = {value})")
    if pinned:
        return f"model_pin: PINNED {', '.join(pinned)} (= 固定要因。 alias 1 語へ直す)"
    return f"model_pin: ok (launcher={model}, alias だけ = 毎回最新へ解決)"


def effort_pin(src: str) -> str:
    effort = launcher_value(src, "EFFORT")
    if not effort or '"--effort"' not in src:
        return "effort_pin: UNPINNED (launcher passes no --effort; the settings or env default decides)"
    found = [f"{name}(CLAUDE_CODE_EFFORT_LEVEL)" for name in shell_hits(SHELL_EFFORT)]
    mark = LAUNCH_MARK.search(src)
    session = os.environ.get("CLAUDE_EFFORT", "") if mark and os.environ.get(mark.group(1)) else ""
    if session and session != effort:
        found.insert(0, f"session={session}")
    if found:
        return f"effort_pin: OVERRIDDEN launcher={effort} but {', '.join(found)} (= 環境変数が --effort に勝つ)"
    return f"effort_pin: ok (launcher={effort}, session={session or 'unmeasured'})"


def main() -> None:
    if not LAUNCHER.is_file():
        print(f"model_pin: (skipped, {LAUNCHER.relative_to(ROOT)} not found)")
        print(f"effort_pin: (skipped, {LAUNCHER.relative_to(ROOT)} not found)")
        return
    src = read(LAUNCHER)
    print(model_pin(src))
    print(effort_pin(src))


if __name__ == "__main__":
    main()
