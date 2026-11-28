#!/usr/bin/env python3
"""エージェントの起動: 最初の発話から階層を決め、 Claude Code を起動する。

入口は `.tooling/claude-launch.sh` (= エージェントを起動する alias が呼ぶ。 agent ごとに足す claude の旗はそこで渡す)。
本体はここで、 型 (= agent-template) が配る (= 派生では書き換えない)。

    claude-launch.sh                              最初の発話を端末の 1 行で受け取る
    claude-launch.sh --first-message-file FILE    最初の発話を file で受け取る (= PWA。 読んだら消す)
    claude-launch.sh --resume ID [--fork-session] 会話を、 その記録が置かれた口座で開き直す
    claude-launch.sh --child ...                  子のタブとして起動する (= 上のどれとも組める。 PWA の子のタブ用の agent)
    (後ろに続く引数は claude へそのまま渡す)

階層の決め方の真値は `projects/_README.md` § プロジェクト判定 (= ここはそれを実装する。 サブプロジェクトの下に
サブプロジェクトが続く階層も、 同じ手順で何段でも)。 決めた階層は
環境変数 `AGENT_TIER` で session に渡し、 階層の folder は `GUARD_WORK_FOLDER` で番人に渡す。 自動の入れ替えで起動し直された時 (= 最初の発話が
`<session-rollover phase="start">` の封筒) は、 前の会話が封筒に書いた階層 (= `tier=` の行) をそのまま採る。
子のタブ (= 親のタブが `tabs new` で立てたタブ) の最初の発話は `<child-start>` の塊を持ち、 その `tier=` の行
(= 親の階層) を採る。 client が階層ごとに立てたタブの最初の発話 (= `<tab-open>` の封筒) も、 その `tier=` の行を採る。 子のタブは `--child` で起動され、 `AGENT_CHILD=1` を session に渡す (= 起動と締めの手順が
子のタブ用になる。 手順は skill `pwa-client:tabs-children` と `sub-agent § 子の側の決まり`)。 子はエージェントを pull しない (= 親が同じ clone で作業している)。 口座は `CLAUDE_CONFIG_DIR` (= PWA のアカウント)、 無ければ `~/.claude`。
再開は、 会話の記録が在る口座で開く (= `~/.claude*/projects/*/<ID>.jsonl`)。 起動の前にエージェントを pull する
(= session が最初に読む CLAUDE.md を、 別の PC が締めた分まで揃える)。 エージェントの folder は `AGENT_ROOT` で
session に渡す (= `AGENT_TIER` はこの folder からの階層で、 タブの中の道具 (= `tabs`) が自分のエージェントを探す口)。

model / effort / fastMode の既定もここが持つ。 /model・/fast・/effort は session の中で
変えると CLI が settings.json に残し、 次の起動が最後の選択のまま始まる (= 重い model や
fast の付けっぱなしに気づけない)。 model と effort は起動ごとの引数で渡し (= settings.json に
触れない)、 fastMode は引数が無いので起動の直前に settings.json へ書き戻す。 配布の
`sync-claude-settings.sh` は 3 つとも機械ごとの鍵として触らない。

子のタブの model と effort の既定、 親が `<child-start>` の `model=`・`effort=` の行で選べる値、 子にだけ足す
環境変数・設定・外す道具は、 エージェントの `templates/claude-child.json` が持つ (= 子が呼ぶたびに読み直す
起動の固定分を削る口)。 file が無ければ子は `CHILD_MODEL` と `EFFORT` で、 何も足さずに起動する。
"""

from __future__ import annotations

import json
import os
import re
import sys
import unicodedata
from pathlib import Path

# model は **alias 1 語だけで書く** (= 版も文脈の変種も名指ししない)。 alias は CLI が持つ表で
# 毎回その時点の最新へ解決される。 版つき id も変種の接尾辞 (= [1m]) も、 既定が変わった日に古い形へ貼り付く。
MODEL = "opus"
#: 階層ごとに既定と違う model で起動するタブ (= 階層 → alias)。 `normal` は操作者との接点で、 操作者の言葉を読んで
#: ほかのタブを動かす決めを持つので、 判断の強い model で起動する。 ここに無い階層は `MODEL`
TIER_MODELS = {"normal": "fable"}
#: 子のタブ (= `--child`) の model。 子は親が渡した持ち場を commit まで書く体で、 判断は親が持つ
CHILD_MODEL = "sonnet"
EFFORT = "high"
FAST_MODE = False
#: 子のタブの起動の設定 (= エージェントの folder からの置き場)。 鍵は `model`・`effort` (= 既定)、 `models`・`efforts`
#: (= 親が選べる値)、 `env` (= 子にだけ足す環境変数)、 `settings` (= `--settings` で足す設定)、 `disallowed_tools`
CHILD_PROFILE = Path("templates") / "claude-child.json"
#: 階層ごとの model をエージェントが決める設定 (= 鍵 `models` に 階層 → alias)。 在れば `TIER_MODELS` に代わり、 無ければ型の既定
TIER_PROFILE = Path("templates") / "claude-tiers.json"
#: 上書きに書ける alias の形 (= 英小文字の 1 語。 版も変種も書かない)
ALIAS = re.compile(r"[a-z]+")
#: 起動の前の pull が網を待つ上限の秒。 普段の fetch は 1 秒前後で、 返らない ssh を待つと Claude が立たない。
#: 試験は環境変数で縮める
PULL_TIMEOUT_SECONDS = float(os.environ.get("AGENT_PULL_TIMEOUT", "20"))

#: 呼び手の道具が自分のために立てた Python の環境の変数 (= client の backend が自分の環境で動き、 立てるタブへ
#: そのまま受け継がせる)。 残すと、 タブで別の repo の uv を打った時に、 その道具の動いている環境が作り直される
CALLER_ENV_VARS = ("UV_PROJECT_ENVIRONMENT", "UV_RUN_RECURSION_DEPTH")
#: Anthropic の API の鍵の変数。 Claude Code はこれが環境に在るとサブスクのログインより鍵を使い、 タブとタブが打つ
#: `claude -p` が API の請求になる。 タブはサブスクで動かし、 鍵はプログラムが自分の置き場から読む
API_KEY_ENV_VARS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")

HOME = Path.home()
#: エージェントの folder は、 この file の置き場だけで決める (= 受け継いだ `AGENT_ROOT` は別のエージェントの
#: session の物かもしれないので読まない。 決めた folder は `AGENT_ROOT` で session へ渡す)
AGENT = Path(__file__).resolve().parents[2]
CLAUDE = os.environ.get("AGENT_CLAUDE_BIN", "claude")
#: 起動の言葉の頭に付ける名前 (= エージェントの folder の名前)
NAME = AGENT.name


def drop_caller_environment() -> None:
    """呼び手の道具の Python の環境 (= 変数と PATH の中のその bin) と API の鍵を、 claude へ渡す環境から外す。"""
    for name in CALLER_ENV_VARS + API_KEY_ENV_VARS:
        os.environ.pop(name, None)
    venv = os.environ.pop("VIRTUAL_ENV", None)
    if venv:
        venv_bin = os.path.join(venv, "bin")
        os.environ["PATH"] = os.pathsep.join(p for p in os.environ.get("PATH", "").split(os.pathsep) if p != venv_bin)


def say(message: str) -> None:
    print(f"{NAME}: {message}", file=sys.stderr)


# ひらがな (= ぁ〜ゖ と ゝゞ) を同じ音のカタカナへ寄せる表。 発話と folder 名のどちらで書いても当たる。
KANA = {c: c + 0x60 for c in [*range(0x3041, 0x3097), 0x309D, 0x309E]}


def fold(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold().translate(KANA)


def folders(parent: Path) -> list[Path]:
    try:
        return [d for d in parent.iterdir() if d.is_dir() and not d.name.startswith(("_", "."))]
    except OSError:
        return []


#: 英字と数字だけの名前 (= `AP`)。 この名前は、 前後に英字か数字が続く所 (= `API`・`app` の中) では当てない
ASCII_NAME = re.compile(r"[a-z0-9]+")


def found_at(name: str, said: str) -> int:
    """畳んだ名前が畳んだ発話のどこに在るか (= 無ければ -1)。 英字と数字だけの名前は単語として在る所だけ。"""
    folded = fold(name)
    if not ASCII_NAME.fullmatch(folded):
        return said.find(folded)
    hit = re.search(rf"(?<![a-z0-9]){re.escape(folded)}(?![a-z0-9])", said)
    return hit.start() if hit else -1


def pick_tier(message: str) -> tuple[str, Path]:
    """発話から階層を決める。 返り値 = (`AGENT_TIER` の値, 階層の folder)。

    親プロに当たったら発話の残りで `subprojects/` を探し、 当たったらその残りでさらに下の `subprojects/` を探す
    (= 当たらなくなるまで何段でも繰り返す)。"""
    said = fold(message)
    hits = [p for p in folders(AGENT / "projects") if found_at(p.name, said) >= 0]
    if not hits:
        return "normal", AGENT
    folder = max(hits, key=lambda p: len(p.name))
    tier = f"projects/{folder.name}"
    # 発話の残り = 当たった名前より後ろ。
    rest = said[found_at(folder.name, said) + len(fold(folder.name)):]
    while True:
        subs = [s for s in folders(folder / "subprojects") if found_at(s.name, rest) >= 0]
        if not subs:
            return tier, folder
        folder = max(subs, key=lambda s: len(s.name))
        tier = f"{tier}/subprojects/{folder.name}"
        rest = rest[found_at(folder.name, rest) + len(fold(folder.name)):]


# 自動の入れ替えで起動し直された時の最初の発話 (= PWA の backend が封筒に入れて渡す)。 中身は前の会話が
# 書いた物で、 `tier=` の行が前の会話の居た階層。
ROLLOVER = re.compile(r'<session-rollover phase="start">\n(.*?)\n</session-rollover>', re.S)
# 子のタブの最初の発話 (= 親のタブからの連絡の封筒) が本文の頭に持つ塊。 中身は `tabs new` が書き、 `tier=` の
# 行が子の階層 (= 親と同じ階層)。
CHILD_START = re.compile(r"<child-start>\n(.*?)\n</child-start>", re.S)
# client が階層ごとにタブを立てて起動した時の最初の発話 (= 封筒だけで本文は無い)。 `tier=` の行が立てた階層。
TAB_OPEN = re.compile(r"<tab-open>\n(.*?)\n</tab-open>", re.S)
# `AGENT_TIER` の値の形 (= `_` と `.` で始まる名前は階層ではない)。
TIER = re.compile(r"projects/[^/\n._][^/\n]*(/subprojects/[^/\n._][^/\n]*)*")


def tier_folder(tier: str) -> Path | None:
    """`AGENT_TIER` の値が指す階層の folder。 値は `normal` / `projects/<P>` / `projects/<P>/subprojects/<S>` と、
    その下に `/subprojects/<S>` が何段でも続く形。 その形でないか、 folder が無ければ None。"""
    if tier == "normal":
        return AGENT
    if not TIER.fullmatch(tier):
        return None
    folder = AGENT / tier
    return folder if folder.is_dir() else None


def handed_tier(message: str) -> str | None:
    """自動の入れ替え・子のタブ・client が立てたタブの最初の発話が運んでいる階層 (= `tier=` の行。 行が無ければ空)。 その発話でなければ None。

    発話の部分一致には任せない: 封筒の 1 行目も本文も、 階層の名前と同じ語を含み得る。"""
    found = ROLLOVER.search(message) or CHILD_START.search(message) or TAB_OPEN.search(message)
    if not found:
        return None
    return next((line[5:].strip() for line in found.group(1).splitlines() if line.startswith("tier=")), "")


def child_fields(message: str) -> dict[str, str]:
    """子のタブの最初の発話の `<child-start>` の塊 (= 入れ替えで起き直した子は `<session-rollover>` の封筒) に
    ある `<名前>=<値>` の行。 塊が無ければ空。"""
    found = CHILD_START.search(message) or ROLLOVER.search(message)
    if not found:
        return {}
    pairs = (line.partition("=") for line in found.group(1).splitlines())
    return {key.strip(): value.strip() for key, sep, value in pairs if sep}


def load_child_profile() -> dict:
    """子のタブの起動の設定。 file が無いか読めなければ空 (= 読めない時は 1 行で言う)。"""
    path = AGENT / CHILD_PROFILE
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        say(f"{path} を読めません (= 子は既定で起動します): {error}")
        return {}
    return data if isinstance(data, dict) else {}


def load_tier_models() -> dict:
    """階層ごとの model。 エージェントの `templates/claude-tiers.json` の `models` が在ればそれ、 無いか読めなければ `TIER_MODELS`。"""
    path = AGENT / TIER_PROFILE
    if not path.is_file():
        return TIER_MODELS
    try:
        models = json.loads(path.read_text(encoding="utf-8")).get("models")
    except (OSError, ValueError, AttributeError) as error:
        say(f"{path} を読めません (= 型の既定の model で起動します): {error}")
        return TIER_MODELS
    if not isinstance(models, dict) or not all(
            isinstance(tier, str) and isinstance(alias, str) and ALIAS.fullmatch(alias) for tier, alias in models.items()):
        say(f"{path} の models は 階層 → alias 1 語 で書きます (= 型の既定の model で起動します)")
        return TIER_MODELS
    return models


#: 子の起動の設定の鍵と、 その値の形 (= 形の違う値は 1 行で言って使わない)
PROFILE_SHAPES = {"model": str, "effort": str, "models": list, "efforts": list, "env": dict, "settings": dict,
                  "disallowed_tools": list}
#: 子の設定の `env` では書けない名前の頭。 起動の script が階層・番人の folder・口座・タブを渡す変数と、 外す API の鍵で、
#: 設定から書けると番人の入力や鍵の除去を上書きできる
RESERVED_ENV_PREFIXES = ("AGENT_", "GUARD_", "ANTHROPIC_", "PWA_", "CLAUDE_CONFIG_DIR")


def checked_profile(profile: dict, notes: list[str]) -> dict:
    """設定のうち、 知っている鍵で形の合う値だけ (= 外した鍵は `notes` に 1 行ずつ足す)。"""
    kept = {}
    for key, value in profile.items():
        shape = PROFILE_SHAPES.get(key)
        if shape is None:
            notes.append(f"{CHILD_PROFILE} の知らない鍵 {key} を使いません")
        elif not isinstance(value, shape) or (shape is list and not all(isinstance(v, str) for v in value)) \
                or (shape is str and not value):
            notes.append(f"{CHILD_PROFILE} の {key} の形が違うので使いません")
        else:
            kept[key] = value
    env = kept.get("env", {})
    for name in [n for n in env if not isinstance(env[n], str) or n.startswith(RESERVED_ENV_PREFIXES)]:
        notes.append(f"{CHILD_PROFILE} の env の {name} は書けないので使いません")
        del env[name]
    return kept


def child_launch(message: str, profile: dict) -> tuple[str, str, list[str], dict[str, str], list[str]]:
    """子のタブの (model, effort, claude へ足す引数, 足す環境変数, 子に知らせる行)。

    親が `<child-start>` の行で選んだ model と effort は、 設定の file の `models`・`efforts` に在る時だけ採る
    (= 無い値は既定で起動し、 そのことを知らせる行に足す)。"""
    notes: list[str] = []
    profile = checked_profile(profile, notes)
    chosen = {"model": profile.get("model", CHILD_MODEL), "effort": profile.get("effort", EFFORT)}
    fields = child_fields(message)
    for key, allowed_key in (("model", "models"), ("effort", "efforts")):
        asked = fields.get(key)
        if not asked:
            continue
        if asked in profile.get(allowed_key, [chosen[key]]):
            chosen[key] = asked
        else:
            notes.append(f"子の {key}={asked} は {CHILD_PROFILE} の {allowed_key} に無いので、 {chosen[key]} で起動します")
    args: list[str] = []
    if profile.get("settings"):
        args += ["--settings", json.dumps(profile["settings"], ensure_ascii=False)]
    if profile.get("disallowed_tools"):
        args += ["--disallowedTools", ",".join(profile["disallowed_tools"])]
    env = {str(k): str(v) for k, v in profile.get("env", {}).items()}
    return chosen["model"], chosen["effort"], args, env, notes


def tier_of(message: str) -> tuple[str, Path]:
    """会話の最初の発話から階層を決める。 返り値 = (`AGENT_TIER` の値, 階層の folder)。 自動の入れ替えの発話・子のタブ・client が立てたタブなら
    封筒が運ぶ階層、 でなければ発話の中の名前 (= `pick_tier`)。 起動も、 再開も、 タブの一覧もこれで決める。"""
    handed = handed_tier(message)
    folder = tier_folder(handed) if handed is not None else None
    if handed is not None and folder is not None:
        return handed, folder
    if handed is not None:
        say(f"引き継いだ階層が見つかりません (= {handed or '書かれていない'})。 発話から決め直します")
    return pick_tier(message)


def skill_dirs(folder: Path) -> list[str]:
    """階層の skill を session に読ませる `--add-dir` 引数 (= サブプロなら、 親プロから自分までの各段の分も)。

    session はエージェントの根で始まるので、 階層の `.claude/skills/` は深い folder の扱いになり一覧に載らない。
    skill を持つ folder だけ、 追加の作業 folder として渡す。
    """
    chain = [folder]
    while chain[0].parent.name == "subprojects":
        chain.insert(0, chain[0].parent.parent)
    return [arg for d in chain if (d / ".claude" / "skills").is_dir() for arg in ("--add-dir", str(d))]


def first_message(config_dir: Path, session: str) -> str:
    """再開する会話の最初の発話 (= 記録の最初の user の文字。 無ければ空)。"""
    for path in config_dir.glob(f"projects/*/{session}.jsonl"):
        try:
            with path.open(encoding="utf-8") as f:
                for line in f:
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if record.get("type") != "user" or record.get("isMeta"):
                        continue
                    content = (record.get("message") or {}).get("content")
                    if isinstance(content, str):
                        return content
                    texts = [b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text"]
                    if texts:
                        return "\n".join(texts)
        except OSError:
            continue
    return ""


def pull_agent() -> None:
    """エージェントを pull する。 止まっても起動は続ける (= 1 行で言う)。

    網を待つ fetch と手元だけの rebase に分け、 fetch にだけ時間の上限を付ける。 github.com への ssh が
    返らないと、 上限が無ければ Claude が立たないまま待ち続ける。 時間切れは ssh を含む process の組ごと止め、
    rebase はしない (= 途中で切っても作業の木は前のまま)。
    """
    import signal  # noqa: PLC0415
    import subprocess  # noqa: PLC0415
    fetch = subprocess.Popen(["git", "-C", str(AGENT), "fetch", "--quiet"], stdout=subprocess.DEVNULL,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        _, error = fetch.communicate(timeout=PULL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        os.killpg(fetch.pid, signal.SIGKILL)
        fetch.wait()
        say(f"{NAME} の pull が {PULL_TIMEOUT_SECONDS:g} 秒で返らないので諦めます (= 起動は続けます。 取り込みは次の起動か session の中で)")
        return
    if fetch.returncode != 0:
        say(f"{NAME} の pull が止まりました (= 起動は続けます): {(error.strip().splitlines() or ['?'])[-1]}")
        return
    rebase = subprocess.run(["git", "-C", str(AGENT), "rebase", "--autostash", "--quiet", "@{upstream}"],
                            capture_output=True, text=True, check=False)
    if rebase.returncode != 0:
        say(f"{NAME} の pull が止まりました (= 起動は続けます): {(rebase.stderr.strip().splitlines() or ['?'])[-1]}")


def account_dir() -> Path:
    return Path(os.path.realpath(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")))


DEFAULT_ACCOUNT = Path(os.path.realpath(HOME / ".claude"))


def record_account(session: str) -> Path | None:
    """再開する会話の記録が在る口座。 起動の口座 (= `account_dir()`) を先に見て、 無ければ他の口座を見る。"""
    found = [p for p in HOME.glob(f".claude*/projects/*/{session}.jsonl") if p.is_file()]
    accounts = [Path(os.path.realpath(p.parents[2])) for p in found]
    here = account_dir()
    return here if here in accounts else (accounts[0] if accounts else None)


def state_file(account: Path) -> Path:
    """口座の状態の file (= 既定の口座は家の直下の `.claude.json`、 ほかは口座の folder の中)。"""
    return HOME / ".claude.json" if account == DEFAULT_ACCOUNT else account / ".claude.json"


def trust_key(folder: Path) -> str:
    """Claude Code が folder の信頼を覚える鍵 (= folder の git の repo の根。 repo の外なら folder 自身)。"""
    import subprocess  # noqa: PLC0415
    done = subprocess.run(["git", "-C", str(folder), "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, check=False)
    return done.stdout.strip() if done.returncode == 0 and done.stdout.strip() else os.path.realpath(folder)


def trust_added_dirs(account: Path, extra: list[str]) -> None:
    """`--add-dir` で渡すエージェントの中の folder を、 口座の状態の file で信頼済みにする。

    Claude Code (2.1.326 から) は、 追加の folder が自前の git の repo だと、 根の信頼が届かず、 起動の前に信頼の窓を
    出して止まる (= 既定の選びは「No, exit」)。 鍵は窓が覚えるのと同じ repo の根で、 エージェントの folder の中の物だけを書く。
    """
    root = os.path.realpath(AGENT)
    keys = [key for key in dict.fromkeys(trust_key(Path(d)) for d in extra[1::2])
            if key == root or key.startswith(root + os.sep)]
    path = state_file(account)
    if not keys or not path.is_file():
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        say(f"{path} を読めません: {error}")
        return
    projects = data.setdefault("projects", {})
    missing = [key for key in keys if not projects.get(key, {}).get("hasTrustDialogAccepted")]
    if not missing:
        return
    for key in missing:
        projects[key] = {**projects.get(key, {}), "hasTrustDialogAccepted": True}
    tmp = path.with_name(path.name + ".launch-tmp")
    try:
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.chmod(tmp, path.stat().st_mode & 0o777)
        os.replace(tmp, path)
    except OSError as error:
        say(f"{path} を更新できません: {error}")


def pin_fast_mode(dirs: list[Path]) -> None:
    for d in dict.fromkeys(dirs):
        path = d / "settings.json"
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            say(f"{path} を読めません: {error}")
            continue
        if data.get("fastMode") == FAST_MODE:
            continue
        data["fastMode"] = FAST_MODE
        tmp = path.with_name(path.name + ".launch-tmp")
        try:
            tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            os.replace(tmp, path)
        except OSError as error:
            say(f"{path} を更新できません: {error}")


def note_can_follow(handed: Path, folder: Path) -> bool:
    """渡されたメモの置き場 (= `<階層>/pages/<id>/memo.md`) の階層が、 起動した階層 `folder` と同じか外側なら真。"""
    if handed.parent.parent.name != "pages":
        return False
    return folder.resolve().is_relative_to(handed.parent.parent.parent.resolve())


def place_note(folder: Path) -> None:
    """タブのメモ (= PWA の 📋) を、 階層の folder の `pages/<タブの id>/memo.md` に普通の file として置く。

    PWA は `PWA_NOTE` にエージェントの folder の置き場を渡し (= 立てる時点では階層が分からない)、 claude が
    立った後はその `AGENT_TIER` の階層の folder の置き場を読み書きする。 ここで階層の側に file を置き、
    エージェントにはその path を渡す。 渡された置き場に先に file が在れば (= `tabs new` が子のメモを書いた時)、
    中身を連れて行く。 PWA の外の起動は何もしない。

    連れて行くのは、 渡された置き場の階層が起動した階層と同じか外側の時だけ。 内側か横の階層の置き場が
    渡されたら (= client が覚えた階層と、 発話から決まった階層が食い違った)、 移さず、 新しい file も作らず、
    渡された置き場をそのまま使う。 移すと境界の中の物が外の階層へ運ばれ、 📋 (= client が覚えた置き場を読む)
    からもメモが消える。
    """
    sid, given = os.environ.get("PWA_SID"), os.environ.get("PWA_NOTE")
    if not sid or not given:
        return
    handed, kept = Path(given), folder / "pages" / sid / "memo.md"
    if handed != kept and not note_can_follow(handed, folder):
        say(f"タブのメモの置き場 ({handed}) が起動した階層の外にあるので、 移さずにそのまま使います")
        return
    kept.parent.mkdir(parents=True, exist_ok=True)
    if handed != kept and handed.is_file() and not handed.is_symlink() and not kept.exists():
        handed.rename(kept)
    kept.touch(exist_ok=True)
    os.environ["PWA_NOTE"] = str(kept)


def parse(argv: list[str]) -> tuple[str | None, Path | None, list[str]]:
    """→ (再開する会話の ID, 発話の file, claude へ渡す残り)。 `--child` は取り除いて `AGENT_CHILD` に残す。"""
    resume, message_file, rest = None, None, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--child":
            os.environ["AGENT_CHILD"] = "1"
            i += 1
            continue
        if a in ("--resume", "--first-message-file"):
            if i + 1 >= len(argv):
                raise SystemExit(f"{NAME}: {a} には値が要ります")
            if a == "--resume":
                resume = argv[i + 1]
            else:
                message_file = Path(argv[i + 1])
            i += 2
            continue
        rest.append(a)
        i += 1
    if resume and message_file:
        raise SystemExit(f"{NAME}: --resume と --first-message-file は同時に使えません")
    return resume, message_file, rest


def main() -> int:
    # 子かどうかは起動の引数だけで決める (= 子のタブの中で人が起動の alias を打った時に、 子の印を受け継がない)
    os.environ.pop("AGENT_CHILD", None)
    resume, message_file, rest = parse(sys.argv[1:])

    if resume:
        account = record_account(resume) or account_dir()
        claude_args = ["--resume", resume, *rest]
        # 階層は最初の発話から決め直す (= 番人の folder・PWA の 📋 と一覧が、 同じ階層を見る)
        message = first_message(account, resume)
        tier, folder = tier_of(message)
        extra = skill_dirs(folder) if tier != "normal" else []
    else:
        if message_file is not None:
            message = message_file.read_text(encoding="utf-8")
            message_file.unlink(missing_ok=True)
        else:
            try:
                import readline  # noqa: F401, PLC0415  (= 行の編集と日本語の消去)
            except ImportError:
                pass
            try:
                message = input("最初の発話 > ")
            except EOFError:
                message = ""
        message = message.strip()
        tier, folder = tier_of(message)
        extra = skill_dirs(folder) if tier != "normal" else []
        account = account_dir()
        claude_args = [*rest, *([message] if message else [])]

    if not os.environ.get("AGENT_CHILD"):
        pull_agent()
    pin_fast_mode([account])
    trust_added_dirs(account, extra)
    # 番人はこの folder から、 このタブが読んでよい境界を決める (= 含む境界と外側の境界、 folder の
    # guard-reads.txt に書いた境界)。 再開でも同じ階層の folder を渡す
    os.environ["GUARD_WORK_FOLDER"] = str(folder)
    place_note(folder)
    # 呼び手の session から受け継いだ値は、 ここで決めた階層とエージェントで上書きする
    os.environ["AGENT_TIER"] = tier
    os.environ["AGENT_ROOT"] = str(AGENT)
    # 既定の口座は CLAUDE_CONFIG_DIR を書かない (= 書くとログインの置き場が変わる)
    if account == DEFAULT_ACCOUNT:
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
    else:
        os.environ["CLAUDE_CONFIG_DIR"] = str(account)
    drop_caller_environment()
    model, effort, child_args = load_tier_models().get(tier, MODEL), EFFORT, []
    if os.environ.get("AGENT_CHILD"):
        model, effort, child_args, child_env, notes = child_launch(message, load_child_profile())
        os.environ.update(child_env)
        for note in notes:
            say(note)
        # 起動の知らせは画面が Claude に替わると消えるので、 子の最初の発話の末尾にも足す (= 子が親へ報告できる)
        if notes and claude_args and not resume:
            claude_args[-1] += "\n\n[起動の知らせ] " + " / ".join(notes)
    # --add-dir と --disallowedTools は後ろの引数をいくつでも取るので、 --model より前に置いて発話を吸わせない
    command = [CLAUDE, *extra, *child_args, "--model", model, "--effort", effort, *claude_args]
    os.execvp(command[0], command)
    return 1


if __name__ == "__main__":
    sys.exit(main())
