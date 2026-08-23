#!/usr/bin/env python3
"""ルール本文が指す repo 内 file の実在検査 (= 陳腐化した参照の機械検出)。

なぜ要るか: ルールに書いた path は、 その file が消えても改名されても黙って残る。
読んだ側は在ると思って探し、 無いと分かるまで時間を使う。 「時間と共に無効になる」
の最も多い形がこれなので、 書いた場所で落とす。

対象 = 各階層の常時 load と lazy (= CLAUDE.md / profile / rules/always.md / rules/lazy/*.md)。
検出 = バッククォート内の **この repo 内を明示的に指す path** のうち、 実在しないもの。

測れないものは検査しない (= 偽陽性を出すと、 黙らせるための除外が増えて検知が死ぬ):
  - work repo の file (= `Taskfile.yml` `configs/eval.yaml` 等)。 repo の場所は階層ごとに
    違い gitignored でもあるので、 この repo からは実在を測れない
  - 裸の file 名 (= `release-cut.sh`)。 この repo の script か work repo の script か区別できない
    → この repo の機構を指すなら `.tooling/` から書く
  - placeholder を含む綴り (= `<P>` `{{...}}` `session-NN.md` 等、 埋める前提のもの)

解決は「その階層の root からの相対」 → 「repo root からの相対」 の順 (= 各階層の
rules/always.md が `rules/lazy/x.md` と書いたら自階層のそれを指す)。

走らせ方: python3 .tooling/lib/check-rule-references.py [--verbose]
出力: 1 行 1 件の `<file>\t<参照>`。 終了コードは常に 0 (= 判定は呼び出し側)。
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

TARGET_GLOBS = [
    "CLAUDE.md",
    "profile/profile.md",
    "rules/always.md",
    "rules/lazy/*.md",
    "projects/*/rules/always.md",
    "projects/*/rules/lazy/*.md",
    "projects/*/subprojects/*/rules/always.md",
    "projects/*/subprojects/*/rules/lazy/*.md",
]

# この repo に固有の綴り (= work repo が同名の dir を持たない。 全階層で測る)
INTERNAL_PREFIXES = ("rules/", "profile/", "projects/", "meetings/", "templates/", ".staledocs/")
INTERNAL_FILES = ("CLAUDE.md", "vision.md")

# work repo 側にも同名で存在しうる dir (= 親階層の file から書かれた時だけ repo 内と判る。
# 下位階層の rule が `journal/weekly/` と書いた時、 それは work repo の journal でありうる)
AMBIGUOUS_PREFIXES = (".tooling/", "journal/", "todos/", "plans/", "research/", "docs/")

def _home_prefix(root: str):
    """`~/...` 表記でこの repo を指す綴りを実 path から導出する。

    置き場所は派生ごとに違うので固定値では書けない。 home の外に clone した場合は
    `~/` 表記でこの repo を指せないので、 その解決自体を無効化する (= None)。
    """
    rel = os.path.relpath(root, os.path.expanduser("~"))
    if rel.startswith(".."):
        return None
    return "~/" + rel.replace(os.sep, "/") + "/"


HOME_PREFIX = _home_prefix(ROOT)

# 埋める前提の綴りを含むものは測らない
PLACEHOLDER = re.compile(r"[<>{}]|\bNN\b|\bYYYY\b|\bP\b|\bS\b")

BACKTICK = re.compile(r"`([^`\n]+)`")


def tier_root(rel_path: str) -> str:
    """その file が属する階層の root を repo 相対で返す (= `projects/X/` 等、 親なら空)。"""
    parts = rel_path.split("/")
    if "rules" in parts:
        return "/".join(parts[: parts.index("rules")])
    if parts[0] == "profile":
        return ""
    return os.path.dirname(rel_path)


def is_internal_reference(token: str, tier: str) -> bool:
    if PLACEHOLDER.search(token) or " " in token.strip():
        return False
    if HOME_PREFIX and token.startswith(HOME_PREFIX):
        return True
    if token.startswith("~/"):
        return False  # この repo の下でない home path は測れない
    if token.startswith(INTERNAL_PREFIXES) or token in INTERNAL_FILES:
        return True
    # 曖昧な dir 名は親階層から書かれた時だけ repo 内と確定する
    return tier == "" and token.startswith(AMBIGUOUS_PREFIXES)


def exists(candidate: str) -> bool:
    if "*" in candidate:
        return bool(glob.glob(candidate, recursive=True))
    return os.path.exists(candidate)


def resolve(token: str, tier: str) -> bool:
    if HOME_PREFIX and token.startswith(HOME_PREFIX):
        token = token[len(HOME_PREFIX):]
        return exists(os.path.join(ROOT, token))
    for base in ([os.path.join(ROOT, tier)] if tier else []) + [ROOT]:
        if exists(os.path.join(base, token)):
            return True
    return False


def main() -> int:
    verbose = "--verbose" in sys.argv
    checked = 0
    missing = []

    for pat in TARGET_GLOBS:
        for path in sorted(glob.glob(os.path.join(ROOT, pat))):
            rel = os.path.relpath(path, ROOT)
            tier = tier_root(rel)
            try:
                text = open(path, encoding="utf-8").read()
            except OSError:
                continue
            seen = set()
            for token in BACKTICK.findall(text):
                token = token.strip()
                if token in seen or not is_internal_reference(token, tier):
                    continue
                seen.add(token)
                checked += 1
                if not resolve(token, tier):
                    missing.append((rel, token))

    for rel, token in missing:
        print(f"{rel}\t{token}")
    if verbose:
        print(f"# checked={checked} missing={len(missing)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # fail-open (= 検査が落ちても本体を止めない)
        print(f"check-rule-references: {e}", file=sys.stderr)
        sys.exit(0)
