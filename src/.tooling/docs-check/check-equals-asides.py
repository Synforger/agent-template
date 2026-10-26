#!/usr/bin/env python3
"""決まりの文に `(= …)` の言い足しが残っていないかを検査する。

`(= …)` は、文の途中で言い換え・例・理由・出典を括弧に詰める書き方で、どれを言っているかを
読む側が毎回見分けることになる。決まりの文は、言い換えなら言い換えの文、例なら「例えば」、
理由なら Why の行と、役割の分かる形で書く。書式の真値は skill `rule-registry` の「表現形式」。

検査するのは常時読み込みの 3 本 (CLAUDE.md・profile・rules/always.md) と、全階層の
rules/always.md と skill の本体。`_` で始まる folder と file、code block、`code` の中は数えない。

file を引数で渡すと、その file だけを検査する (worktree の中の書きかけを確かめる時)。

出力は 1 file 1 行の TSV (path <TAB> message)。無ければ何も出さない。
`--selftest` で見本を通し、残した見本で鳴り、直した見本で黙ることを確かめる。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from md_fences import fence_states  # noqa: E402

ASIDE = re.compile(r"[(（]=\s")
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)[^\n]+?(?<!`)\1(?!`)")
GLOBS = (
    "CLAUDE.md", "profile/profile.md", "rules/always.md", ".claude/skills/*/SKILL.md",
    "projects/*/rules/always.md", "projects/*/.claude/skills/*/SKILL.md",
    "projects/*/subprojects/*/rules/always.md",
    "projects/*/subprojects/*/.claude/skills/*/SKILL.md",
)




def rule_files() -> list[Path]:
    keep = set()
    for pat in GLOBS:
        for p in ROOT.glob(pat):
            inner = p.relative_to(ROOT).parts
            if any(seg.startswith("_") for seg in inner):
                continue
            keep.add(p)
    return sorted(keep)


def aside_lines(text: str) -> list[int]:
    hits = []
    lines = text.splitlines()
    for i, (line, in_fence) in enumerate(zip(lines, fence_states(lines)), 1):
        if in_fence:
            continue
        if ASIDE.search(CODE_SPAN.sub("", line)):
            hits.append(i)
    return hits


SAMPLE_LEFT = """\
- 「環境がない」 を理由に断らない (= 実際に無いことを確かめてから言う)
- 期日は file に書く（= 会話に置かない）
"""
SAMPLE_FIXED = """\
- 「環境がない」と言うのは、実際に無いことを確かめてからにする。
- 書き方の検査は `(= ` を探す。

```
(= code block の中は数えない)
```

````
入れ子の ``` も中に数える
```
(= 4 本で開いた block は 4 本で閉じる)
````
"""


def selftest() -> int:
    left = aside_lines(SAMPLE_LEFT)
    fixed = aside_lines(SAMPLE_FIXED)
    ok = left == [1, 2] and fixed == []
    print(f"left sample  -> 行 {left} (期待 [1, 2])")
    print(f"fixed sample -> 行 {fixed} (期待 [])")
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    named = [Path(a) for a in sys.argv[1:] if not a.startswith("--")]
    for f in named or rule_files():
        lines = aside_lines(f.read_text(encoding="utf-8"))
        if lines:
            rel = f if named else f.relative_to(ROOT)
            head = ", ".join(str(n) for n in lines[:5]) + (" ほか" if len(lines) > 5 else "")
            print(f"{rel}\t(= …) の言い足しが {len(lines)} 行 (行 {head}): 役割の分かる文に書き直す")
    return 0


if __name__ == "__main__":
    sys.exit(main())
