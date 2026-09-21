#!/usr/bin/env python3
"""ルール本文が指す repo 内 file の実在検査 (= 陳腐化した参照の機械検出)。

なぜ要るか: ルールに書いた path は、 その file が消えても改名されても黙って残る。
読んだ側は在ると思って探し、 無いと分かるまで時間を使う。 「時間と共に無効になる」
の最も多い形がこれなので、 書いた場所で落とす。

対象 = 各階層の常時 load と lazy に加えて、 folder の運用 1 本と各階層の玄関
(= `<kind>/_README.md` / `<tier>/_README.md` / `vision.md`)。
検出 = バッククォート内の **この repo 内を明示的に指す path** のうち、 実在しないもの。

測れないものは検査しない (= 偽陽性を出すと、 黙らせるための除外が増えて検知が死ぬ):
  - work repo の file のうち、 **その repo に実在する top-level dir で始まらないもの**。
    階層の `_README.md § repo` が宣言した repo が手元に在り、 `docs/` のように repo 側に
    実体のある入口で始まる綴りだけ測る (= branch 名 / owner+repo / 別 repo の path /
    リモートの絶対 path は、 この条件で自然に外れる)
  - `external-paths: true` を宣言した file の全参照 (= 自階層の repo でなく別の場所の話)
  - 裸の file 名 (= `release-cut.sh`)。 この repo の script か work repo の script か区別できない
    → この repo の機構を指すなら `.tooling/` から書く
  - placeholder を含む綴り (= `<P>` `{{...}}` `session-NN.md` 等、 埋める前提のもの)
  - 実行時に生まれる生成物 (= `.tooling/_output/*`) と、 雛形から作る実体
    (= `pc-labels.txt` に対する `pc-labels.example.txt`)。 未生成 / 未作成の段階で
    赤にすると、 clone 直後の派生が常時赤になって検査そのものが無視される

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
    "vision.md",
    "profile/profile.md",
    "rules/always.md",
    "rules/lazy/*.md",
    # folder の運用 1 本と各階層の玄関 (= ここが指す path も「在ると思って探す時間」 を奪う。
    # rule file だけを見ていた頃、 消えた dir への参照が _README に何か月も残っていた)
    "*/_README.md",
    "projects/*/_README.md",
    "projects/*/vision.md",
    "projects/*/rules/always.md",
    "projects/*/rules/lazy/*.md",
    "projects/*/subprojects/_README.md",
    "projects/*/subprojects/*/_README.md",
    "projects/*/subprojects/*/vision.md",
    "projects/*/subprojects/*/rules/always.md",
    "projects/*/subprojects/*/rules/lazy/*.md",
]

# この repo に固有の綴り (= work repo が同名の dir を持たない。 全階層で測る)
INTERNAL_PREFIXES = ("rules/", "profile/", "projects/", "templates/", ".staledocs/")
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

# 実行時に生まれる生成物 (= gitignore 済、 走らせるまで存在しない)
GENERATED_PREFIXES = (".tooling/_output/",)

# 埋める前提の綴りを含むものは測らない
PLACEHOLDER = re.compile(r"[<>{}]|\bNN\b|\bYYYY\b|\bP\b|\bS\b")

BACKTICK = re.compile(r"`([^`\n]+)`")

# `<file>.md § <見出し>` = 「その節に書いてある」 という主張。 節ごと消える / 改名される
# ことがあるので、 file の実在だけでなく見出しの実在も測る。
SECTION_REF = re.compile(r"^(\S+\.md)\s*§\s*(.+)$")
HEADING = "^#{2,4}\\s*§?\\s*"


def tier_repo(tier: str):
    """その階層の `_README.md` が `## repo` で宣言している repo root (= 手元に在る時だけ)。"""
    readme = os.path.join(ROOT, tier, "_README.md") if tier else os.path.join(ROOT, "_README.md")
    if not os.path.isfile(readme):
        return None
    try:
        text = open(readme, encoding="utf-8").read()
    except OSError:
        return None
    section = re.search(r"^##\s+repo\s*$(.*?)(?=^##\s|\Z)", text, re.M | re.S)
    if not section:
        return None
    for token in BACKTICK.findall(section.group(1)):
        token = token.strip()
        if token.startswith("~/") and os.path.isdir(os.path.expanduser(token)):
            return os.path.expanduser(token)
    return None


TIER_REPO_CACHE = {}


def repo_for(tier: str):
    if tier not in TIER_REPO_CACHE:
        TIER_REPO_CACHE[tier] = tier_repo(tier)
    return TIER_REPO_CACHE[tier]


EXTERNAL_DECL = re.compile(r"^external-paths:\s*true\b", re.M)


def declares_external_paths(text: str) -> bool:
    """frontmatter の `external-paths: true` = この file は自階層の repo 以外を指す。

    1 つの階層が 2 つ目の repo やリモートホストの中身を書く手順書は、 宣言した repo で
    解決できないのが正しい姿なので測らない (= 行ごとの allow-list ではなく、 file が
    「どこの話か」 を宣言する形にしてある)。
    """
    head = text.split("---", 2)
    return bool(head) and bool(EXTERNAL_DECL.search(head[1] if len(head) > 2 else text))


def measurable_in_repo(token: str, tier: str, external: bool = False):
    """repo 側で実在を測れる綴りなら repo root を返す。

    測るのは **その repo に実在する top-level dir で始まる相対 path** だけ
    (= `docs/...` は repo に docs/ が在る時だけ測る)。 branch 名 / owner+repo /
    別 repo の path / リモートホストの絶対 path は、 この条件で自然に外れる。
    """
    if external or token.startswith("/") or "/" not in token:
        return None
    repo = repo_for(tier)
    if not repo:
        return None
    head = token.split("/")[0]
    if head and os.path.isdir(os.path.join(repo, head)):
        return repo
    return None


def tier_root(rel_path: str) -> str:
    """その file が属する階層の root を repo 相対で返す (= `projects/X/` 等、 親なら空)。"""
    parts = rel_path.split("/")
    if "rules" in parts:
        return "/".join(parts[: parts.index("rules")])
    if parts[0] == "profile":
        return ""
    return os.path.dirname(rel_path)


def is_internal_reference(token: str, tier: str, external: bool = False) -> bool:
    if PLACEHOLDER.search(token) or " " in token.strip():
        return False
    if HOME_PREFIX and token.startswith(HOME_PREFIX):
        return True
    if token.startswith("~/"):
        return False  # この repo の下でない home path は測れない
    if token.startswith(INTERNAL_PREFIXES) or token in INTERNAL_FILES:
        return True
    if tier == "" and token.startswith(AMBIGUOUS_PREFIXES):
        return True
    # その階層の repo に実在する top-level dir で始まるなら repo 側で測れる
    return measurable_in_repo(token, tier, external) is not None


def exists(candidate: str) -> bool:
    if "*" in candidate:
        return bool(glob.glob(candidate, recursive=True))
    if os.path.exists(candidate):
        return True
    return has_scaffold(candidate)


def has_scaffold(candidate: str) -> bool:
    """`a/b.txt` の実体が無くても `a/b.example.txt` / `a/b.template.txt` が在れば在り扱い。

    雛形から各環境で作る file は、 作る前の段階では存在しない。 雛形の在処で判定する。
    """
    directory, name = os.path.split(candidate)
    stem, dot, ext = name.partition(".")
    if not dot:
        return False
    return any(
        os.path.exists(os.path.join(directory, f"{stem}.{kind}.{ext}"))
        for kind in ("example", "template")
    )


def resolve(token: str, tier: str, external: bool = False) -> bool:
    # 実行時に生まれる生成物は測らない (= 走らせる前は必ず無い)
    if token.startswith(GENERATED_PREFIXES):
        return True
    if HOME_PREFIX and token.startswith(HOME_PREFIX):
        token = token[len(HOME_PREFIX):]
        return exists(os.path.join(ROOT, token))
    bases = ([os.path.join(ROOT, tier)] if tier else []) + [ROOT]
    repo = measurable_in_repo(token, tier, external)
    if repo:
        bases.append(repo)
    for base in bases:
        if exists(os.path.join(base, token)):
            return True
    return False


def section_missing(token: str, tier: str):
    """`<file>.md § <見出し>` の見出しが対象 file に無ければ、 その綴りを返す。"""
    m = SECTION_REF.match(token)
    if not m:
        return None
    rel, section = m.group(1), m.group(2).strip()
    if PLACEHOLDER.search(section) or PLACEHOLDER.search(rel):
        return None
    # 自階層 → 親 → … → repo root の順に辿り、 **その見出しを持つ file** を探す
    # (= 下の階層が親の節を名指すのは普通の書き方。 同名 file が在るだけで打ち切らない)
    bases = []
    walk = tier
    while walk:
        bases.append(os.path.join(ROOT, walk))
        walk = os.path.dirname(walk)
    bases.append(ROOT)
    seen_file = False
    for base in bases:
        cand = os.path.join(base, rel)
        if not os.path.isfile(cand):
            continue
        seen_file = True
        try:
            body = open(cand, encoding="utf-8").read()
        except OSError:
            continue
        if re.search(HEADING + re.escape(section), body, re.M):
            return None
    return f"{rel} § {section}" if seen_file else None


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
            external = declares_external_paths(text)
            seen = set()
            for token in BACKTICK.findall(text):
                token = token.strip()
                if token in seen:
                    continue
                gone = section_missing(token, tier)
                if gone:
                    seen.add(token)
                    checked += 1
                    missing.append((rel, gone))
                    continue
                if not is_internal_reference(token, tier, external):
                    continue
                seen.add(token)
                checked += 1
                if not resolve(token, tier, external):
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
