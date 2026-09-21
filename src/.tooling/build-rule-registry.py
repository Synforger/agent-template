#!/usr/bin/env python3
"""build-rule-registry.py - rule file の section に安定 ID を振り、階層ごとの台帳を維持する (= LLM 不使用)。

用途: 発火記録 (= そのセッションでどのルールが効いたか / 違反したか) の宛先となる ID を作る。
      ルール本体 file は無変更 (= 見出しに ID を書くと常時 load 層の容量を食うため)、
      台帳が「file + 見出し」で紐付ける。 紐付けが切れたら --check が検出する。

台帳は**階層ごと**に置く (= 階層自己完結):
  親        -> rules/registry.jsonl
  project   -> projects/<P>/rules/registry.jsonl
  subproject-> projects/<P>/subprojects/<S>/rules/registry.jsonl

  Why: 1 本にまとめると gitignored な階層の path が tracked file へ漏れる。
       ID は階層内で一意、 発火記録も同じ階層の journal に書くので衝突しない。

走らせ方:
  python3 .tooling/build-rule-registry.py           # 全階層の台帳を更新
  python3 .tooling/build-rule-registry.py --check   # 検査のみ (= 未登録 / 消滅を報告、 exit 1)

section が消えても行は retired: true で残す (= 過去の発火記録が宛先を失わないため)。
"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 走査対象 = 全階層の rule 層 (= 親 / project / subproject)
TARGET_GLOBS = [
    "CLAUDE.md",
    "rules/always.md",
    "profile/profile.md",
    "rules/lazy/*.md",
    "projects/*/rules/always.md",
    "projects/*/rules/lazy/*.md",
    "projects/*/subprojects/*/rules/always.md",
    "projects/*/subprojects/*/rules/lazy/*.md",
]
SKIP_BASENAMES = {"_README.md", "_template.md"}
# `_` prefix の階層 (= 雛形 / system) は対象外
SKIP_PATH_PARTS = ("_template-project", "_template-subproject", "_archive")


def target_files():
    out = []
    for pat in TARGET_GLOBS:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            if os.path.basename(p) in SKIP_BASENAMES:
                continue
            rel = os.path.relpath(p, ROOT)
            if any(part in rel.split(os.sep) for part in SKIP_PATH_PARTS):
                continue
            out.append(rel)
    return out


def tier_of(rel):
    """その file が属する階層 root を返す (= 親は空文字)。"""
    parts = rel.split(os.sep)
    if parts and parts[0] == "projects":
        if "subprojects" in parts:
            i = parts.index("subprojects")
            return os.sep.join(parts[: i + 2])
        return os.sep.join(parts[:2])
    return ""


def registry_path(tier):
    return os.path.join(ROOT, tier, "rules", "registry.jsonl") if tier else \
        os.path.join(ROOT, "rules", "registry.jsonl")


def sections(relpath):
    """H2 / H3 見出しを (level, text, breadcrumb) で返す。 fenced code block 内は除外。"""
    out = []
    h2 = None
    infence = False
    with open(os.path.join(ROOT, relpath), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.lstrip().startswith("```"):
                infence = not infence
                continue
            if infence:
                continue
            if line.startswith("### "):
                text = line[4:].strip()
                out.append((3, text, f"{h2} > {text}" if h2 else text))
            elif line.startswith("## "):
                h2 = line[3:].strip()
                out.append((2, h2, h2))
    return out


def born_of(relpath, heading):
    """その見出しが最初に現れた commit を git log -S で引く。 追えなければ file の誕生で代替。"""
    for args in (
        ["git", "log", "--diff-filter=AM", "--format=%h\t%ad\t%s", "--date=short",
         "-S", heading, "--", relpath],
        ["git", "log", "--diff-filter=A", "--format=%h\t%ad\t%s", "--date=short", "--", relpath],
    ):
        try:
            r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=20)
        except Exception:
            continue
        lines = [ln for ln in r.stdout.strip().split("\n") if ln.strip()]
        if lines:
            parts = lines[-1].split("\t")
            if len(parts) == 3:
                return {"born_commit": parts[0], "born_date": parts[1], "born_subject": parts[2]}
    return {"born_commit": "", "born_date": "", "born_subject": ""}


def load_registry(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(ln) for ln in f if ln.strip()]


def main():
    check_only = "--check" in sys.argv

    by_tier = {}
    for rel in target_files():
        by_tier.setdefault(tier_of(rel), []).append(rel)

    total_live = total_added = total_retired = 0
    problems = []

    for tier, files in sorted(by_tier.items()):
        path = registry_path(tier)
        rows = load_registry(path)
        by_key = {(r["file"], r["heading"]): r for r in rows}
        max_id = 0
        for r in rows:
            m = re.match(r"R-(\d+)$", r["id"])
            if m:
                max_id = max(max_id, int(m.group(1)))

        seen, added, retired = set(), [], []
        for rel in files:
            for level, text, crumb in sections(rel):
                key = (rel, text)
                if key in seen:
                    continue  # 同一 file 内の同名見出しは 1 件として扱う
                seen.add(key)
                row = by_key.get(key)
                if row is None:
                    max_id += 1
                    row = {"id": f"R-{max_id:04d}", "file": rel, "heading": text,
                           "path": crumb, "level": level, "retired": False}
                    row.update(born_of(rel, text))
                    by_key[key] = row
                    added.append(row)
                else:
                    row["path"] = crumb
                    row["level"] = level
                    row["retired"] = False

        for key, row in by_key.items():
            if key not in seen and not row.get("retired"):
                row["retired"] = True
                retired.append(row)

        live = [r for r in by_key.values() if not r.get("retired")]
        total_live += len(live)
        total_added += len(added)
        total_retired += len(retired)

        if check_only:
            for r in added:
                problems.append(f"registry: unregistered section → {r['file']} :: {r['heading']}")
            for r in retired:
                problems.append(f"registry: section gone (id {r['id']}) → {r['file']} :: {r['heading']}")
            continue

        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            for r in sorted(by_key.values(), key=lambda x: x["id"]):
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    if check_only:
        if problems:
            for line in problems:
                print(line)
            print("run: python3 .tooling/build-rule-registry.py")
            return 1
        print(f"registry: in sync ({total_live} live rules across {len(by_tier)} tiers)")
        return 0

    print(f"registry: {total_live} live rules across {len(by_tier)} tiers "
          f"({total_added} added, {total_retired} retired)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # fail-open (= 主処理を止めない)
        print(f"build-rule-registry: {e}", file=sys.stderr)
        sys.exit(0)
