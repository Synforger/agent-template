#!/usr/bin/env python3
"""rule-hits-summary.py - ルールの発火実績を集計する (= LLM 不使用)。

用途: 「どのルールが効いているか」 を実測値にする。 容量超過時に押し出す対象を
      文字数でなく実績下位から選ぶための材料、 および退役候補の検出。

入力: 各階層の rules/registry.jsonl (= ID 台帳) + journal/<date>/session-NN-rule-hits.jsonl
出力: 既定は 1 行 summary (= startup-status 用)

走らせ方:
  python3 .tooling/rules/rule-hits-summary.py              # 1 行 summary
  python3 .tooling/rules/rule-hits-summary.py --detail     # 発火上位 / 違反上位 / 沈黙
  python3 .tooling/rules/rule-hits-summary.py --drift      # 出自がエージェント自発のもの (= レビュー用)
  python3 .tooling/rules/rule-hits-summary.py --unresolved # 台帳に解決できなかった記録 (= 書式のずれ)
  python3 .tooling/rules/rule-hits-summary.py --find 検出機構   # 書く時に ID を引く

記録の読み方 (= 過去に 12 種類のスキーマで書かれているので、 読む側で吸収する):
  - `fired` / `violated` の配列 = ID 直書き。 そのまま使う
  - `rule` + 判定キー = 自由記述。 判定キーは kind / status / event / effect / verdict /
    hit / violation のどれか、 値は hit・effective 系か violation・violated 系
  - 自由記述の rule 名は台帳の見出しへ寄せる (= 見出しで引き、 当たらなければ rule 本文を
    引いて、 その行を含む section の ID にする)。 見出しの一部だけを書いた記録は、 寄せ先が
    1 つに決まる時だけ寄せる。 生きている rule に当たらない記録は、 台帳に残る退役の行へ
    寄せる (= 当時の見出しで書かれた記録)。 寄せられなかったものは --unresolved に出る
  - 階層が `rules/hits-since.json` で「記録を ID で書き始めた日」 を宣言していれば、 その日より
    前の寄らない記録は unresolved に数えない (= 言い換えや造語で書かれた昔の記録は宛先を
    決め直せない。 数え続けると、 今の書き方が割れた時に数字で気づけなくなる)
  - ID の頭の文字は階層の深さ (= 親 R- / project P- / subproject S-)。 記録は起動した階層の
    journal に書かれるので、 文字が指す台帳を、 その階層から親までの系列の中で引く
  - 階層が同じ file で `lettered_since` (= 頭の文字を分けた時刻) を宣言していれば、 それより前の
    R- の記録のうち、 同じ番号が系列の中の台帳 2 つ以上に在る物は数えない (= どの階層も R- の
    1 番から振っていた間の記録は、 どの台帳の番号かを決め直せない)

沈黙の判定: **skill 層だけ** (= 120 日)。 常時 load は状況が来なければ発火しないので判定しない。
記録がその窓ぶん貯まるまでも出さない (= 「記録が無い」 を「沈黙」 と読むと全ルールが死んで見える)。
"""
import datetime
import difflib
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGISTRY_GLOBS = [
    "rules/registry.jsonl",
    "projects/*/rules/registry.jsonl",
    "projects/*/subprojects/*/rules/registry.jsonl",
]
HITS_GLOBS = [
    "journal/*/*-rule-hits.jsonl",
    "projects/*/journal/*/*-rule-hits.jsonl",
    "projects/*/subprojects/*/journal/*/*-rule-hits.jsonl",
]
ID_RE = re.compile(r"[A-Z]-\d{4}")


def lineage(tier):
    """その階層から親までの系列 (= 自階層 → project → 親)。 1 つの session が読む台帳はこの中だけ。"""
    out = [tier] if tier else []
    parts = tier.split(os.sep) if tier else []
    if "subprojects" in parts:
        out.append(os.sep.join(parts[:parts.index("subprojects")]))
    out.append("")
    return out


def letter_of(tier):
    """その階層の ID の頭の文字 (= 台帳を作る側と同じ決め: 親 R / project P / subproject S)。"""
    if not tier:
        return "R"
    return "S" if "subprojects" in tier.split(os.sep) else "P"


def tier_of_id(rid, tier):
    """ID の頭の文字が指す階層を、 記録が書かれた階層の系列の中から返す (= 系列に無ければ None)。"""
    for t in lineage(tier):
        if letter_of(t) == rid[0]:
            return t
    return None


# 沈黙判定が成立するのは skill だけ。 skill は使う場面に入った時にしか読まないので、 長く読まれない
# = trigger が一度も来ていない が言える。 常時 load は毎 session 読まれるが、 効くかどうかは状況
# 次第で、 発火が無いのは「その状況が来なかった」 だけ (= 破壊操作 / 第三者操作 / メモリ上限)。
# そちらの退役は機械で決めず、 読み直して判断する。
SILENT_DAYS_LAZY = 120


def silent_window(rule_file):
    """そのルールの沈黙窓 (= 日数)。 判定が成立しない層は None。"""
    return SILENT_DAYS_LAZY if ".claude/skills/" in (rule_file or "") else None

VERDICT_KEYS = ("kind", "status", "event", "effect", "verdict")
HIT_WORDS = ("hit", "effective", "fired")
VIOLATION_WORDS = ("violation", "violated", "miss")
DATE_RE = re.compile(r"/(\d{4}-\d{2}-\d{2})/")
MATCH_THRESHOLD = 0.60


# ---------- 台帳 ----------

_ALL_TIERS = []


def load_registry():
    rows = []
    for pat in REGISTRY_GLOBS:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            tier = os.path.relpath(os.path.dirname(os.path.dirname(p)), ROOT)
            tier = "" if tier == "." else tier
            if tier and tier not in _ALL_TIERS:
                _ALL_TIERS.append(tier)
            with open(p, encoding="utf-8") as f:
                for ln in f:
                    if ln.strip():
                        r = json.loads(ln)
                        r["tier"] = tier
                        rows.append(r)
    return rows


# ---------- 記録の正規化 ----------

def _verdict_of(rec):
    """12 種類のスキーマから hit / violation を取り出す。 不明なら None。"""
    for key in VERDICT_KEYS:
        v = rec.get(key)
        if isinstance(v, str):
            low = v.strip().lower()
            if low in VIOLATION_WORDS:
                return "violation"
            if low in HIT_WORDS:
                return "hit"
    # キー名自体が判定を表す形 (= {"rule": X, "violation": "説明"})。
    # `violated` は正規形では配列だが、 行単位の旧形では真偽値の判定キーとして使われている。
    if "violation" in rec:
        return "violation"
    if not isinstance(rec.get("violated"), (list, tuple)) and rec.get("violated"):
        return "violation"
    if "hit" in rec:
        v = rec.get("hit")
        if isinstance(v, str) and v.strip().lower() in VIOLATION_WORDS:
            return "violation"
        return "hit"
    return None


def load_hits():
    """全書式を {tier, session, day, ref, id, verdict, by} の列へ潰す。"""
    out = []
    for pat in HITS_GLOBS:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            rel = os.path.relpath(p, ROOT)
            tier = rel.split("/journal/")[0]
            tier = "" if tier == rel else tier
            m = DATE_RE.search("/" + rel)
            day_from_path = m.group(1) if m else ""
            with open(p, encoding="utf-8") as f:
                for ln in f:
                    ln = ln.strip()
                    if not ln:
                        continue
                    try:
                        rec = json.loads(ln)
                    except json.JSONDecodeError:
                        continue
                    # 書き漏らした session を後から閉じた印 (= 事実は無いので数えない)
                    if rec.get("unrecorded"):
                        continue
                    day = (rec.get("ts") or "")[:10] or day_from_path
                    session = rec.get("session") or f"{day_from_path}-?"
                    base = {"tier": tier, "session": session, "day": day, "ts": rec.get("ts") or ""}

                    # 正規形は fired / violated がどちらも配列。 型が違う記録は
                    # 行単位の旧形なので、 下の吸収経路へ落とす (= ここで回すと死ぬ)
                    if isinstance(rec.get("fired"), (list, tuple)) or \
                            isinstance(rec.get("violated"), (list, tuple)):
                        for rid in rec.get("fired") or []:
                            out.append({**base, "id": rid, "ref": None,
                                        "verdict": "hit", "by": None})
                        for v in rec.get("violated") or []:
                            rid = v.get("id") if isinstance(v, dict) else v
                            by = v.get("by") if isinstance(v, dict) else None
                            if rid:
                                out.append({**base, "id": rid, "ref": None,
                                            "verdict": "violation", "by": by})
                        continue

                    ref = rec.get("rule") or rec.get("id")
                    if not ref:
                        continue
                    verdict = _verdict_of(rec) or "hit"
                    rid = ref if ID_RE.fullmatch(str(ref)) else None
                    out.append({**base, "id": rid, "ref": None if rid else ref,
                                "verdict": verdict, "by": rec.get("by")})
    return out


# 階層が「記録を ID で書き始めた日」 を宣言する file (= 台帳の隣)。 形は
# {"by_id_since": "YYYY-MM-DD", "why": "..."}。 日付を code に持たないための置き場
BASELINE_NAME = "hits-since.json"


LETTERED_KEY = "lettered_since"


def load_lettered():
    """階層 → 頭の文字を分けた時刻 (= 台帳を作る script が、 文字を直した時に 1 度だけ書く)。"""
    out = {}
    for pat in REGISTRY_GLOBS:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            tier = os.path.relpath(os.path.dirname(os.path.dirname(p)), ROOT)
            tier = "" if tier == "." else tier
            try:
                with open(os.path.join(os.path.dirname(p), BASELINE_NAME), encoding="utf-8") as f:
                    when = json.load(f).get(LETTERED_KEY)
                datetime.datetime.fromisoformat(when)
            except (OSError, ValueError, AttributeError, TypeError):
                continue
            out[tier] = when
    return out


def written_before(rec, when):
    """その記録が `when` より前に書かれたか。 時刻の無い記録は日付で比べ、 同じ日なら前とみなす
    (= 決められない記録を数に入れない側へ倒す)。"""
    cut = datetime.datetime.fromisoformat(when)
    if rec.get("ts"):
        try:
            ts = datetime.datetime.fromisoformat(rec["ts"])
            if (ts.tzinfo is None) == (cut.tzinfo is None):
                return ts < cut
        except ValueError:
            pass
    return bool(rec.get("day")) and rec["day"] <= cut.date().isoformat()


def load_baselines():
    """階層 → 宣言された日。 file が無い階層は載らない (= 全期間を数える)。"""
    out = {}
    for pat in REGISTRY_GLOBS:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            tier = os.path.relpath(os.path.dirname(os.path.dirname(p)), ROOT)
            tier = "" if tier == "." else tier
            try:
                with open(os.path.join(os.path.dirname(p), BASELINE_NAME), encoding="utf-8") as f:
                    day = json.load(f).get("by_id_since")
            except (OSError, ValueError, AttributeError):
                continue
            if isinstance(day, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
                out[tier] = day
    return out


# ---------- 自由記述 → ID ----------

_FILE_CACHE = {}


def _rule_files(tier):
    """その階層でルールとして読まれる file (= 記録が指しうる先)。 返すのは ROOT 相対。"""
    base = os.path.join(ROOT, tier) if tier else ROOT
    pats = ["rules/always.md", ".claude/skills/*/SKILL.md"]
    if not tier:
        pats += ["profile/profile.md", "CLAUDE.md"]
    found = []
    for pat in pats:
        for p in sorted(glob.glob(os.path.join(base, pat))):
            found.append(os.path.relpath(p, ROOT))
    return found


# 記録の第 1 セグメントは「どこのルールか」 を指している (= 12 種類の書式に共通する唯一の癖)。
# ここで候補を親か自階層に絞らないと、 短い抜粋が無関係な階層の本文へ誤って寄る。
PARENT_AREAS = {
    "profile": "profile/profile.md",
    "claude": "CLAUDE.md",
    "quality": "rules/always.md",
    "style": "rules/always.md",
    "git": "rules/always.md",
    "forbidden": "rules/always.md",
    "meta": "rules/always.md",
}
# `lazy` は skill へ移す前 (= 2026-09-26 まで) の記録が使っていた語
SELF_AREAS = ("always", "skill", "skills", "lazy", "rules")


def _headings_of(path):
    """file 内の (行番号, level, 見出し) を返す。"""
    if path in _FILE_CACHE:
        return _FILE_CACHE[path]
    heads, lines = [], []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        pass
    for i, ln in enumerate(lines):
        m = re.match(r"^(#{2,3})\s+(.*)$", ln)
        if m:
            heads.append((i, len(m.group(1)), m.group(2).strip()))
    _FILE_CACHE[path] = (heads, lines)
    return _FILE_CACHE[path]


def _norm(s):
    """照合用の正規化。 補足の括弧・強調・句読点は記録側で落ちがちなので、 両方から外す。"""
    s = re.sub(r"[（(][^）)]*[）)]", "", s or "")
    return re.sub(r"[\s`*、。,.:：]+", "", s).lower()


def _score(a, b):
    return difflib.SequenceMatcher(None, _norm(a), _norm(b)).ratio()


# 寄せる先として採る一致度の下限 (= 見出しでも本文の行でも同じ線)
ACCEPT = 0.72
# 記録が見出しや本文の行の一部かで寄せる時に要る、 記録の長さ (= 正規化した後の文字数。
# これより短い語は無関係な見出しや行にも含まれる)
CONTAIN_MIN = 5
_PREPARED = {}


def _prepared(cand):
    """寄せる先の 1 件 (= 見出し or 本文の行) を、 比べる側として 1 回だけ下ごしらえする。

    difflib は 2 本目の列から作る索引を持ち回るので、 寄せる先を 2 本目に固定して 1 本目
    (= 記録の抜粋) だけ差し替える。 `.b` が正規化済みの文字列。
    """
    m = _PREPARED.get(cand)
    if m is None:
        m = _PREPARED[cand] = difflib.SequenceMatcher(None, "", _norm(cand))
    return m


def _closer(nbody, cand):
    """`_score` と同じ値。 ただし採る線 (= ACCEPT) に届かないと分かる相手は None。

    difflib の 2 つの上限 (= 長さだけ / 文字の数だけ) は本計算より桁違いに安く、 どちらも
    本当の一致度を下回らない。 上限が届かない相手は本計算しても採られないので省ける。
    """
    m = _prepared(cand)
    m.set_seq1(nbody)
    if m.real_quick_ratio() < ACCEPT or m.quick_ratio() < ACCEPT:
        return None
    return m.ratio()


def _rule_name(rel):
    """ルール file の名前 (= skill は folder 名、 それ以外は拡張子を除いた file 名)。"""
    if os.path.basename(rel) == "SKILL.md":
        return os.path.basename(os.path.dirname(rel))
    return os.path.basename(rel)[:-3]


def _skill_area(head, tier):
    """第 1 セグメントが skill の名前 (= `sub-agent` など) なら、 その file へ絞る。"""
    for t in lineage(tier):
        for rel in _rule_files(t):
            if _rule_name(rel).lower() == head:
                return (t, rel)
    return None


def _scope_of(ref, tier):
    """記録の第 1 セグメントから、 探す階層と file を絞る。 返り値 = [(tier, file or None)]。

    絞った先で当たらなかった時のために、 末尾には必ず自階層から親までの系列を残す
    (= 階層をまたいで移したルールの記録は、 書かれた当時の階層を指したままになる)。
    """
    segments = [s.strip() for s in re.split(r"[/:>]", str(ref)) if s.strip()]
    head = segments[0].lower() if segments else ""
    scopes = []

    if head in PARENT_AREAS:
        scopes.append(("", PARENT_AREAS[head]))
    elif head in SELF_AREAS:
        scopes.append((tier, None))
    else:
        skill = _skill_area(head, tier)
        if skill:
            scopes.append(skill)
        for t in _ALL_TIERS:
            if t and head and head in os.path.basename(t).lower():
                scopes.append((t, None))
                break

    for fallback in [(t, None) for t in lineage(tier)]:
        if fallback not in scopes:
            scopes.append(fallback)
    return scopes, segments


def _owner_heading(rel, lineno):
    """その行を抱えている直近の見出しを返す。"""
    heads, _ = _headings_of(os.path.join(ROOT, rel))
    owner = None
    for i, _lvl, text in heads:
        if i <= lineno:
            owner = text
        else:
            break
    return owner


def _match_heading(nbody, tier, want_file, reg_by_tier, retired):
    """台帳の見出しへ寄せる。 `retired` で、 生きている行だけ / 退役した行だけを選ぶ。

    一致度が採る線に届く見出しが無い時は、 記録が見出しの一部かを見る (= 見出しの前半だけを
    書いた形。 見出しは後ろへ補足が伸びるので、 短い抜粋は一致度では届かない)。 採るのは
    寄せ先が 1 つに決まる時だけ。 逆向き (= 見出しが記録の一部) は採らない: 記録が
    「大見出し + 小見出しの言い換え」 の形だと、 大見出しへ粗く寄ってしまう。
    """
    best = (0.0, None)
    holders = set()
    for row in reg_by_tier.get(tier, []):
        if bool(row.get("retired")) != retired:
            continue
        if want_file and not row.get("file", "").endswith(want_file):
            continue
        for cand in (row.get("heading", ""), row.get("path", "")):
            s = _closer(nbody, cand)
            if s is not None and s > best[0]:
                best = (s, (tier, row["id"]))
        if len(nbody) >= CONTAIN_MIN and nbody in _prepared(row.get("heading", "")).b:
            holders.add(row["id"])
    if best[0] >= ACCEPT:
        return best[1]
    if len(holders) == 1:
        return (tier, holders.pop())
    return None


def _match_in_scope(nbody, tier, want_file, reg_by_tier):
    """1 つの scope の中だけで、 見出し → 本文 → 退役した見出し の順に寄せる。"""
    # ① 台帳の見出しと直接 (= 記録が section 名で書かれている場合)
    hit = _match_heading(nbody, tier, want_file, reg_by_tier, retired=False)
    if hit:
        return hit

    # ② rule 本文の行から、 その行を抱える section へ (= bullet で書かれている場合)。
    # 抜粋が本文にそのまま含まれるのは強い signal なので、 短くても採る
    best_line = (0.0, None, None)
    for rel in _rule_files(tier):
        if want_file and not rel.endswith(want_file):
            continue
        _heads, lines = _headings_of(os.path.join(ROOT, rel))
        for i, ln in enumerate(lines):
            if not ln.strip() or ln.startswith("#"):
                continue
            if len(nbody) >= CONTAIN_MIN and nbody in _prepared(ln).b:
                best_line = (1.0, rel, i)
                break
            s = _closer(nbody, ln)
            if s is not None and s > best_line[0]:
                best_line = (s, rel, i)
        if best_line[0] == 1.0:
            break
    if best_line[0] >= ACCEPT:
        owner = _owner_heading(best_line[1], best_line[2])
        for row in reg_by_tier.get(tier, []):
            if owner and row.get("file") == best_line[1] and row.get("heading") == owner:
                return (tier, row["id"])

    # ③ 退役した見出し (= 台帳は消えた section の行を残している。 当時の見出しで書かれた
    # 記録はそこへ寄せる。 生きている rule の実績には混ざらない)
    return _match_heading(nbody, tier, want_file, reg_by_tier, retired=True)


def resolve_ref(ref, tier, reg_by_tier):
    """自由記述のルール名を台帳の (tier, ID) へ寄せる。 当たらなければ None。

    絞った scope から順に試し、 最初に当たったものを採る (= 全 scope をまとめて探すと、
    短い抜粋が無関係な階層の本文へ寄る)。 同じ階層の同じ記録は 1 回だけ解く。
    """
    known = (tier, str(ref))
    if known not in _RESOLVED:
        _RESOLVED[known] = _resolve(ref, tier, reg_by_tier)
    return _RESOLVED[known]


_RESOLVED = {}


def _resolve(ref, tier, reg_by_tier):
    scopes, segments = _scope_of(ref, tier)
    if not segments:
        return None
    body = segments[-1]
    nbody = _norm(body)
    for t, want_file in scopes:
        hit = _match_in_scope(nbody, t, want_file, reg_by_tier)
        if hit:
            return hit
    return None


# ---------- 集計 ----------

def summarize():
    reg = load_registry()
    hits = load_hits()
    live = [r for r in reg if not r.get("retired")]
    reg_by_tier = {}
    for r in reg:
        reg_by_tier.setdefault(r["tier"], []).append(r)

    fired, violated, last_seen = {}, {}, {}
    unresolved = {}
    baselines = load_baselines()
    before = {}  # 階層 → 宣言された日より前の、 寄らなかった記録の数
    lettered = load_lettered()
    ambiguous = {}  # 階層 → 頭の文字を分ける前に書かれ、 番号が系列の台帳 2 つ以上に在る記録の数
    numbers = {}  # 階層 → その台帳に在る番号 (= 文字を除いた数字)
    for r in reg:
        numbers.setdefault(r["tier"], set()).add(r["id"][2:])
    sessions = set()
    days = set()

    for rec in hits:
        sessions.add((rec["tier"], rec["session"]))
        if rec["day"]:
            days.add(rec["day"])
        # 記録に ID が書き込まれていればそれが最も確か (= 文の中に書かれた ID も同じに扱う)
        rid = rec["id"]
        if not rid and rec["ref"]:
            inline = ID_RE.search(str(rec["ref"]))
            rid = inline.group(0) if inline else None
        if rid:
            chain = lineage(rec["tier"])
            cuts = [lettered[t] for t in chain if t in lettered]
            if (rid[0] == "R" and cuts and written_before(rec, max(cuts))
                    and sum(rid[2:] in numbers.get(t, ()) for t in chain) >= 2):
                ambiguous[rec["tier"]] = ambiguous.get(rec["tier"], 0) + 1
                continue
            # 頭の文字が指す台帳を系列の中で引く。 系列に無い文字は、 書かれた階層の知らない ID として残す
            owner = tier_of_id(rid, rec["tier"])
            key = (rec["tier"] if owner is None else owner, rid)
        elif rec["ref"]:
            key = resolve_ref(rec["ref"], rec["tier"], reg_by_tier)
            if not key:
                since = baselines.get(rec["tier"])
                if since and rec["day"] and rec["day"] < since:
                    before[rec["tier"]] = before.get(rec["tier"], 0) + 1
                else:
                    unresolved[(rec["tier"], rec["ref"])] = unresolved.get(
                        (rec["tier"], rec["ref"]), 0) + 1
                continue
        else:
            continue
        if rec["verdict"] == "violation":
            # self 以外 = ユーザに指摘された違反 (= 記録の綴りは環境で違うので、
            # 「自分で気づいた」 の否定で判定する)
            weight = 3 if rec.get("by") != "self" else 1
            violated[key] = violated.get(key, 0) + weight
        else:
            fired[key] = fired.get(key, 0) + 1
        if rec["day"] and rec["day"] > last_seen.get(key, ""):
            last_seen[key] = rec["day"]

    span = 0
    if days:
        try:
            span = (datetime.date.fromisoformat(max(days))
                    - datetime.date.fromisoformat(min(days))).days
        except ValueError:
            span = 0
    return (reg, live, hits, fired, violated, last_seen, unresolved, sessions, span, days,
            before, baselines, ambiguous)


def _label(reg, key):
    tier, rid = key
    for r in reg:
        if r["id"] == rid and r["tier"] == tier:
            return f"{r['file']} :: {r['path']}"  # file は ROOT 相対 (= 台帳の実体)
    return f"{tier or '.'} {rid} (unknown id)"


def main():
    if "--find" in sys.argv:
        i = sys.argv.index("--find")
        needle = " ".join(sys.argv[i + 1:]).strip()
        if not needle:
            print("usage: --find <keyword>")
            return 2
        reg = load_registry()
        nneedle = _norm(needle)
        rows = []
        for r in reg:
            if r.get("retired"):
                continue
            # 語がそのまま含まれるものが最優先 (= 短い見出しほど類似度が上がる性質を打ち消す)
            if nneedle and nneedle in _norm(r.get("path", "")):
                rows.append((r, 1.0))
                continue
            s = _score(needle, r.get("heading", ""))
            if s >= 0.45:
                rows.append((r, s))
        rows.sort(key=lambda x: -x[1])
        if not rows:
            print("(no match)")
        for r, s in rows[:12]:
            print(f"  {r['id']}  [{r['tier'] or '.'}]  {r['file']} :: {r['path']}")
        return 0

    (reg, live, hits, fired, violated, last_seen, unresolved, sessions, span, days,
     before, baselines, ambiguous) = summarize()
    if not reg:
        print("rule_hits: no registry (run build-rule-registry.py)")
        return 0

    if "--drift" in sys.argv:
        rules_kind = ("rules", "docs(rules)", "refactor(rules)", "docs(profile)", "chore(rules)")
        primary = [r for r in live if r.get("born_subject", "").startswith("session-end")]
        secondary = [r for r in live
                     if r not in primary
                     and r.get("born_date", "") >= "2026-06-01"
                     and not r.get("born_subject", "").split(":")[0].startswith(rules_kind)]
        print(f"# A. session-end 中に生まれたルール ({len(primary)} / {len(live)})")
        for r in sorted(primary, key=lambda x: (x.get("born_date", ""), x["id"])):
            print(f"{r['id']}  {r.get('born_date','?')}  {r['file']} :: {r['path']}")
            print(f"          ← {r.get('born_subject','')[:96]}")
        print()
        print(f"# B. 他作業の commit に混ざって入ったルール ({len(secondary)}、 2026-06 以降)")
        for r in sorted(secondary, key=lambda x: (x.get("born_date", ""), x["id"])):
            print(f"{r['id']}  {r.get('born_date','?')}  {r['file']} :: {r['path']}")
        return 0

    if "--unresolved" in sys.argv:
        total = sum(unresolved.values())
        print(f"# 台帳に寄せられなかった記録 {len(unresolved)} 種 / {total} 件")
        print("# (= 記録の書き方が見出しからも本文からも離れている。 次に書く時は --find で ID を引く)")
        for tier in sorted(before):
            print(f"# 数えない記録 {before[tier]} 件  [{tier or '.'}]  "
                  f"(= {baselines[tier]} より前。 宣言 = その階層の rules/{BASELINE_NAME})")
        for tier in sorted(ambiguous):
            print(f"# 数えない記録 {ambiguous[tier]} 件  [{tier or '.'}]  "
                  f"(= ID の頭の文字を階層で分ける前に書かれ、 同じ番号が系列の台帳 2 つ以上に在る)")
        for (tier, ref), n in sorted(unresolved.items(), key=lambda x: -x[1]):
            print(f"  {n:3}  [{tier or '.'}]  {ref}")
        return 0

    # 沈黙判定は、 その層の窓ぶん記録が貯まってから (= 記録が無い ≠ 効いていない)
    silent = []
    today = datetime.date.today()
    for r in live:
        window = silent_window(r.get("file"))
        if window is None or span < window:
            continue  # 判定が成立しない層 / まだ記録が足りない
        key = (r["tier"], r["id"])
        day = last_seen.get(key)
        if not day:
            silent.append((r, None))
            continue
        try:
            age = (today - datetime.date.fromisoformat(day)).days
        except ValueError:
            continue
        if age >= window:
            silent.append((r, age))
    measurable = span >= SILENT_DAYS_LAZY

    if "--detail" in sys.argv:
        resolved = sum(fired.values()) + sum(violated.values())
        unres = sum(unresolved.values())
        print(f"registry: {len(live)} live rules / {len(sessions)} sessions recorded "
              f"({len(days)} days, span {span}d)")
        print(f"records: {resolved} resolved, {unres} unresolved "
              f"({100 * resolved / max(1, resolved + unres):.0f}% resolved)")
        if before:
            print(f"         {sum(before.values())} unresolved before a tier's declared day "
                  f"(not counted; rules/{BASELINE_NAME})")
        if ambiguous:
            print(f"         {sum(ambiguous.values())} written before the tiers' ids took their own letter, "
                  f"with a number more than one registry holds (not counted; rules/{BASELINE_NAME})")
        print()
        print("--- 発火上位 15 ---")
        for key, n in sorted(fired.items(), key=lambda x: -x[1])[:15]:
            print(f"  {key[1]}  発火 {n:3}  違反 {violated.get(key,0):3}  {_label(reg, key)}")
        print()
        print("--- 違反上位 15 (= ユーザ指摘は 3 倍で重み付け) ---")
        for key, n in sorted(violated.items(), key=lambda x: -x[1])[:15]:
            print(f"  {key[1]}  違反 {n:3}  発火 {fired.get(key,0):3}  {_label(reg, key)}")
        print()
        if not measurable:
            print(f"--- 沈黙判定は保留 (記録期間 {span} 日 < skill の窓 {SILENT_DAYS_LAZY} 日) ---")
            print("    記録が無いことは、 効いていないことの証拠にならない")
            print("    常時 load は判定対象外 (= 読まれても状況が来なければ発火しない)")
        else:
            print(f"--- 沈黙 (skill のみ、 {SILENT_DAYS_LAZY} 日以上) {len(silent)} 件 ---")
            for r, age in silent[:30]:
                print(f"  {r['id']}  {'記録なし' if age is None else str(age)+' 日'}  "
                      f"{r['tier'] or '.'}/{r['file']} :: {r['path']}")
        return 0

    unres = sum(unresolved.values())
    tail = f", unresolved={unres}" if unres else ""
    if not measurable:
        print(f"rule_hits: {len(live)} live rules, {len(sessions)} sessions over {span}d "
              f"(skill silence needs {SILENT_DAYS_LAZY}d){tail}")
    else:
        print(f"rule_hits: {len(live)} live rules, {len(sessions)} sessions, "
              f"silent={len(silent)}{tail}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # fail-open
        print(f"rule-hits-summary: {e}", file=sys.stderr)
        sys.exit(0)
