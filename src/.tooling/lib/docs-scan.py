#!/usr/bin/env python3
"""docs-check の走査系 5 step を 1 パスで済ませる。

置き換え前は step 1 / 2 / 3 / 4 / 5 が同じ .md を何度も開き直し、 判定 1 個ごとに
head / awk / grep / wc を起こしていた (= 302 file で数千プロセス、 45 秒のうち 42 秒)。
file の中身を読むのは 1 回だけで足りるので、 ここで全部済ませて結果だけ shell へ返す。

ツリーを歩くのも 1 回で足りる。 検査対象の .md / _README.md / repo 内の全 file 名索引は
同じ走査から作れるので、 shell 側で find を複数回起こさない。

入出力:
    docs-scan.py [--local-excludes <file>]
    stdout に `<step>\t<level>\t<message>` を 1 行ずつ (= level は fail / warn / pass)。
    pass 行の message は件数 (= shell 側で加算する)。

判定と文言は docs-check.sh の元実装と 1 対 1。 出力順も元の loop 順を保つ。
"""

import fnmatch
import os
import re
import sys

# .tooling/lib/ から 3 段上が repo root
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# dead link 判定で「外部 repo の root 慣習 file」 として見逃す名前
EXTERNAL_ROOT_DOCS = {
    "README.md", "CONTRIBUTING.md", "SECURITY.md", "ROADMAP.md",
    "CHANGELOG.md", "THIRD_PARTY_NOTICES.md", "NOTICE.md",
}

# placeholder 真値の絞り込みに使う日本語文字 (= grep -E '[一-龯ぁ-んァ-ヶ]' 相当)
JA_CHARS = re.compile(r"[一-龯ぁ-んァ-ヶ]")

REF_PATTERN = re.compile(r"`([a-zA-Z0-9_/.~-]+\.md)`")
PLACEHOLDER_PATTERN = re.compile(r"\{\{[^}]+\}\}|<[^>]{1,80}>")
INDEX_HEADING = re.compile(r"^##\s*(エントリ|ファイル|索引|各環境ファイル|エントリポイント)")

out = []


def emit(step, level, message):
    out.append(f"{step}\t{level}\t{message}")


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().split("\n")


def frontmatter(lines):
    """先頭の --- で挟まれた block を返す (= awk '/^---$/{c++...}' 相当)。"""
    if not lines or lines[0] != "---":
        return []
    block = []
    for line in lines[1:]:
        if line == "---":
            break
        block.append(line)
    return block


def collect(local_excludes):
    """ツリー走査 1 回で 3 つの一覧を作る。

    返すのは (検査対象 .md、 _README.md、 repo 内の全 file 名索引)。
    除外条件は元の find の -not -path / -not -name と 1 対 1:
      - 検査対象 .md = .git / .tooling / .claude/worktrees / journal / drafts /
        _scratch / _template* / CLAUDE.md を除く (+ 派生固有の local-excludes)
      - _README.md = .git / .claude/worktrees のみ除く (= .tooling 配下も対象)
      - file 名索引 = .git / .tooling / .claude/worktrees を除く
    """
    md_list, readme_list, basenames = [], [], set()
    for dirpath, dirnames, filenames in os.walk("."):
        # .git と worktree は全用途で不要なので歩かない
        dirnames[:] = [
            d for d in dirnames
            if os.path.join(dirpath, d).replace(os.sep, "/") not in {"./.git", "./.claude/worktrees"}
        ]
        for name in filenames:
            path = os.path.join(dirpath, name).replace(os.sep, "/")
            in_tooling = path.startswith("./.tooling/")
            if not in_tooling:
                basenames.add(name)
            if name == "_README.md":
                readme_list.append(path)
            if not name.endswith(".md") or name == "CLAUDE.md" or in_tooling:
                continue
            if any(seg in path for seg in ("/journal/", "/drafts/", "/_scratch/", "/_template")):
                continue
            if any(fnmatch.fnmatch(path, pat) for pat in local_excludes):
                continue
            md_list.append(path)
    return sorted(md_list), readme_list, basenames


def main():
    args = dict(zip(sys.argv[1::2], sys.argv[2::2]))

    os.chdir(ROOT)

    # 派生固有除外 (= 1 行 1 path pattern、 base には混入させない)
    local_excludes = []
    lx = args.get("--local-excludes")
    if lx and os.path.exists(lx):
        for line in read_lines(lx):
            line = line.split("#", 1)[0].strip()
            if line:
                local_excludes.append(line)

    md_list, readme_list, all_basenames = collect(local_excludes)

    # file の中身は 1 度だけ読む (= step 1 / 2 / 4 / 5 が同じものを見る)
    cache = {}
    for f in md_list:
        try:
            with open(f, "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        text = raw.decode("utf-8", errors="replace")
        lines = text.split("\n")
        cache[f] = {"size": len(raw), "lines": lines, "fm": frontmatter(lines)}

    # ===== 1. frontmatter =====
    passes = 0
    for f in md_list:
        entry = cache.get(f)
        if entry is None or not entry["lines"] or entry["lines"][0] != "---":
            emit(1, "fail", f"{f}: no frontmatter (missing leading ---)")
            continue
        fm = entry["fm"]
        if not any(line.startswith("title:") for line in fm):
            emit(1, "fail", f"{f}: frontmatter title missing")
        if not any(line.startswith("description:") for line in fm):
            emit(1, "warn", f"{f}: frontmatter description missing (recommended)")
        passes += 1
    emit(1, "pass", passes)

    # ===== 2. capacity =====
    claude_md = os.path.join(ROOT, "CLAUDE.md")
    if os.path.exists(claude_md):
        size = os.path.getsize(claude_md)
        if size > 17408:
            emit(2, "fail", f"CLAUDE.md: {size} bytes > 17KB limit")
    for f in md_list:
        entry = cache.get(f)
        if entry is None:
            continue
        decl = next((line for line in entry["fm"] if line.startswith("capacity:")), None)
        if decl is None:
            continue
        num = re.search(r"[0-9]+", decl)
        if num is None:
            continue
        declared = int(num.group()) * 1024
        size = entry["size"]
        if size <= declared:
            continue
        # 常時 load 層はハード FAIL、 lazy 文書庫と profile lazy は目安 (= WARN)
        if f.endswith("/profile/profile.md"):
            emit(2, "fail", f"{f}: {size} bytes > declared capacity {num.group()}KB")
        elif "/lazy/" in f or re.search(r"/profile/profile-[^/]*\.md$", f):
            emit(2, "warn", f"{f}: {size} bytes > soft capacity {num.group()}KB (目安)")
        else:
            emit(2, "fail", f"{f}: {size} bytes > declared capacity {num.group()}KB")

    # ===== 3. _README.md 索引整合 =====
    for readme in readme_list:
        try:
            body = open(readme, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if not any(INDEX_HEADING.match(line) for line in body.split("\n")):
            continue
        d = os.path.dirname(readme) or "."
        try:
            siblings = sorted(n for n in os.listdir(d) if n.endswith(".md"))
        except OSError:
            continue
        for name in siblings:
            if not os.path.isfile(os.path.join(d, name)):
                continue
            if name in ("_README.md", "_template.md") or name.startswith("_template-"):
                continue
            base = name[:-3]
            if name not in body and base not in body:
                emit(3, "warn", f"{readme}: sibling {name} not mentioned (missing from the index?)")

    # ===== 4. dead link =====
    # 引き先の basename 索引は collect() が走査 1 回で作ったものを使う
    staledocs_scoped = os.path.exists(os.path.join(ROOT, ".staledocs.yaml"))
    for f in md_list:
        entry = cache.get(f)
        if entry is None:
            continue
        if "archive/" in f or "history/" in f:
            continue
        if any(re.match(r"^status: *snapshot", line) for line in entry["fm"]):
            continue
        # .staledocs.yaml の docs スコープは staledocs 側がアンカー生存を担当
        if staledocs_scoped and (f.startswith("./rules/") or f == "./profile/profile.md"):
            continue
        refs = sorted(set(REF_PATTERN.findall("\n".join(entry["lines"]))))
        for ref in refs:
            if any(tok in ref for tok in ("kebab-case", "session-NN", "_template", "YYYY-MM", "0000-", "000X-")):
                continue
            if ".tooling/_output/" in ref:
                continue
            if ref.startswith("~/") or ref.startswith("/"):
                continue
            d = os.path.dirname(f) or "."
            if os.path.isfile(os.path.join(d, ref)) or os.path.isfile(ref):
                continue
            refname = os.path.basename(ref)
            if refname in EXTERNAL_ROOT_DOCS:
                continue
            if refname in all_basenames:
                continue
            # 第 1 階層が repo 内に無い path は外部 repo 引用と推定して見逃す
            first_seg = ref.split("/", 1)[0]
            if ref == first_seg or os.path.isdir(first_seg):
                emit(4, "warn", f"{f}: dead link → {ref}")

    # ===== 5. 雛形 placeholder の残り =====
    placeholders = set()
    for dirpath, _dirnames, filenames in os.walk(os.path.join(ROOT, "projects/_template-project")):
        for name in filenames:
            if not name.endswith(".md"):
                continue
            try:
                body = open(os.path.join(dirpath, name), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for hit in PLACEHOLDER_PATTERN.findall(body):
                # 二重中括弧は全部、 山括弧は日本語を含むものだけ (= `<project>` 等の path 例示を除く)
                if hit.startswith("{{") or JA_CHARS.search(hit):
                    placeholders.add(hit)

    if placeholders:
        for f in md_list:
            entry = cache.get(f)
            if entry is None:
                continue
            if "/_archive/" in f or "/_output/" in f:
                continue
            in_fence = False
            for no, line in enumerate(entry["lines"], 1):
                if line.startswith("```"):
                    in_fence = not in_fence
                    continue
                if in_fence:
                    continue
                if any(ph in line for ph in placeholders):
                    emit(5, "fail", f"{f}: leftover placeholder -> {no}:{line}")
    else:
        emit(5, "warn", "placeholder truth (projects/_template-project) is empty, skipping")

    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    main()
