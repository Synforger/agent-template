#!/usr/bin/env python3
"""エージェントの起動: 最初の発話から階層を決め、 Claude Code を起動する。

入口は `.tooling/claude-launch.sh` (= エージェントを起動する alias が呼ぶ。 agent ごとに足す claude の旗はそこで渡す)。
本体はここで、 型 (= agent-template) が配る (= 派生では書き換えない)。

    claude-launch.sh                              最初の発話を端末の 1 行で受け取る
    claude-launch.sh --first-message-file FILE    最初の発話を file で受け取る (= PWA。 読んだら消す)
    claude-launch.sh --resume ID [--fork-session] 会話を、 その記録が置かれた口座で開き直す
    claude-launch.sh --child ...                  子のタブとして起動する (= 上のどれとも組める。 PWA の子のタブ用の agent)
    (後ろに続く引数は claude へそのまま渡す)

階層の決め方の真値は `projects/_README.md` § プロジェクト判定 (= ここはそれを実装する)。 決めた階層は
環境変数 `AGENT_TIER` で session に渡し、 階層の folder は `GUARD_WORK_FOLDER` で番人に渡す。 自動の入れ替えで起動し直された時 (= 最初の発話が
`<session-rollover phase="start">` の封筒) は、 前の会話が封筒に書いた階層 (= `tier=` の行) をそのまま採る。
子のタブ (= 親のタブが `tabs new` で立てたタブ) の最初の発話は `<child-start>` の塊を持ち、 その `tier=` の行
(= 親の階層) を採る。 子のタブは `--child` で起動され、 `AGENT_CHILD=1` を session に渡す (= 起動と締めの手順が
子のタブ用になる。 手順は skill `pwa-client:tabs` と `sub-agent § 子の側の決まり`)。 子はエージェントを pull しない (= 親が同じ clone で作業している)。 口座は `CLAUDE_CONFIG_DIR` (= PWA のアカウント)、 無ければ `~/.claude`。
再開は、 会話の記録が在る口座で開く (= `~/.claude*/projects/*/<ID>.jsonl`)。 起動の前にエージェントを pull する
(= session が最初に読む CLAUDE.md を、 別の PC が締めた分まで揃える)。 エージェントの folder は `AGENT_ROOT` で
session に渡す (= `AGENT_TIER` はこの folder からの階層で、 タブの中の道具 (= `tabs`) が自分のエージェントを探す口)。

model / effort / fastMode の既定もここが持つ。 /model・/fast・/effort は session の中で
変えると CLI が settings.json に残し、 次の起動が最後の選択のまま始まる (= 重い model や
fast の付けっぱなしに気づけない)。 model と effort は起動ごとの引数で渡し (= settings.json に
触れない)、 fastMode は引数が無いので起動の直前に settings.json へ書き戻す。 配布の
`sync-claude-settings.sh` は 3 つとも機械ごとの鍵として触らない。
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
#: 子のタブ (= `--child`) の model。 子は親が渡した持ち場を commit まで書く体で、 判断は親が持つ
CHILD_MODEL = "sonnet"
EFFORT = "high"
FAST_MODE = False

#: 呼び手の道具が自分のために立てた Python の環境の変数 (= client の backend が自分の環境で動き、 立てるタブへ
#: そのまま受け継がせる)。 残すと、 タブで別の repo の uv を打った時に、 その道具の動いている環境が作り直される
CALLER_ENV_VARS = ("UV_PROJECT_ENVIRONMENT", "UV_RUN_RECURSION_DEPTH")

HOME = Path.home()
#: エージェントの folder は、 この file の置き場だけで決める (= 受け継いだ `AGENT_ROOT` は別のエージェントの
#: session の物かもしれないので読まない。 決めた folder は `AGENT_ROOT` で session へ渡す)
AGENT = Path(__file__).resolve().parents[2]
CLAUDE = os.environ.get("AGENT_CLAUDE_BIN", "claude")
#: 起動の言葉の頭に付ける名前 (= エージェントの folder の名前)
NAME = AGENT.name


def drop_caller_environment() -> None:
    """呼び手の道具の Python の環境 (= 変数と PATH の中のその bin) を、 claude へ渡す環境から外す。"""
    for name in CALLER_ENV_VARS:
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
    """発話から階層を決める。 返り値 = (`AGENT_TIER` の値, 階層の folder)。"""
    said = fold(message)
    hits = [p for p in folders(AGENT / "projects") if found_at(p.name, said) >= 0]
    if not hits:
        return "normal", AGENT
    project = max(hits, key=lambda p: len(p.name))
    # 発話の残り = 親プロの名前より後ろ。
    rest = said[found_at(project.name, said) + len(fold(project.name)):]
    subs = [s for s in folders(project / "subprojects") if found_at(s.name, rest) >= 0]
    if subs:
        sub = max(subs, key=lambda s: len(s.name))
        return f"projects/{project.name}/subprojects/{sub.name}", sub
    return f"projects/{project.name}", project


# 自動の入れ替えで起動し直された時の最初の発話 (= PWA の backend が封筒に入れて渡す)。 中身は前の会話が
# 書いた物で、 `tier=` の行が前の会話の居た階層。
ROLLOVER = re.compile(r'<session-rollover phase="start">\n(.*?)\n</session-rollover>', re.S)
# 子のタブの最初の発話 (= 親のタブからの連絡の封筒) が本文の頭に持つ塊。 中身は `tabs new` が書き、 `tier=` の
# 行が子の階層 (= 親と同じ階層)。
CHILD_START = re.compile(r"<child-start>\n(.*?)\n</child-start>", re.S)
# `AGENT_TIER` の値の形 (= `_` と `.` で始まる名前は階層ではない)。
TIER = re.compile(r"projects/[^/\n._][^/\n]*(/subprojects/[^/\n._][^/\n]*)?")


def tier_folder(tier: str) -> Path | None:
    """`AGENT_TIER` の値 (= `normal` / `projects/<P>` / `projects/<P>/subprojects/<S>`) が指す階層の folder。
    その形でないか、 folder が無ければ None。"""
    if tier == "normal":
        return AGENT
    if not TIER.fullmatch(tier):
        return None
    folder = AGENT / tier
    return folder if folder.is_dir() else None


def handed_tier(message: str) -> str | None:
    """自動の入れ替えか子のタブの最初の発話が運んでいる階層 (= `tier=` の行。 行が無ければ空)。 その発話でなければ None。

    発話の部分一致には任せない: 封筒の 1 行目も本文も、 階層の名前と同じ語を含み得る。"""
    found = ROLLOVER.search(message) or CHILD_START.search(message)
    if not found:
        return None
    return next((line[5:].strip() for line in found.group(1).splitlines() if line.startswith("tier=")), "")


def tier_of(message: str) -> tuple[str, Path]:
    """会話の最初の発話から階層を決める。 返り値 = (`AGENT_TIER` の値, 階層の folder)。 自動の入れ替えの発話なら
    封筒が運ぶ階層、 でなければ発話の中の名前 (= `pick_tier`)。 起動も、 再開も、 タブの一覧もこれで決める。"""
    handed = handed_tier(message)
    folder = tier_folder(handed) if handed is not None else None
    if handed is not None and folder is not None:
        return handed, folder
    if handed is not None:
        say(f"引き継いだ階層が見つかりません (= {handed or '書かれていない'})。 発話から決め直します")
    return pick_tier(message)


def skill_dirs(folder: Path) -> list[str]:
    """階層の skill を session に読ませる `--add-dir` 引数 (= サブプロなら親プロの分も)。

    session はエージェントの根で始まるので、 階層の `.claude/skills/` は深い folder の扱いになり一覧に載らない。
    skill を持つ folder だけ、 追加の作業 folder として渡す。
    """
    chain = [folder.parent.parent, folder] if folder.parent.name == "subprojects" else [folder]
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
    """エージェントを pull する。 止まっても起動は続ける (= 1 行で言う)。"""
    import subprocess  # noqa: PLC0415
    pull = subprocess.run(["git", "-C", str(AGENT), "pull", "--rebase", "--autostash", "--quiet"],
                          capture_output=True, text=True)
    if pull.returncode != 0:
        say(f"{NAME} の pull が止まりました (= 起動は続けます): {(pull.stderr.strip().splitlines() or ['?'])[-1]}")


def account_dir() -> Path:
    return Path(os.path.realpath(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")))


DEFAULT_ACCOUNT = Path(os.path.realpath(HOME / ".claude"))


def record_account(session: str) -> Path | None:
    """再開する会話の記録が在る口座。 起動の口座 (= `account_dir()`) を先に見て、 無ければ他の口座を見る。"""
    found = [p for p in HOME.glob(f".claude*/projects/*/{session}.jsonl") if p.is_file()]
    accounts = [Path(os.path.realpath(p.parents[2])) for p in found]
    here = account_dir()
    return here if here in accounts else (accounts[0] if accounts else None)


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


def place_note(folder: Path) -> None:
    """タブのメモ (= PWA の 📋) を、 階層の folder の `pages/<タブの id>/memo.md` に普通の file として置く。

    PWA は `PWA_NOTE` にエージェントの folder の置き場を渡し (= 立てる時点では階層が分からない)、 claude が
    立った後はその `AGENT_TIER` の階層の folder の置き場を読み書きする。 ここで階層の側に file を置き、
    エージェントにはその path を渡す。 渡された置き場に先に file が在れば (= `tabs new` が子のメモを書いた時)、
    中身を連れて行く。 PWA の外の起動は何もしない。
    """
    sid, given = os.environ.get("PWA_SID"), os.environ.get("PWA_NOTE")
    if not sid or not given:
        return
    handed, kept = Path(given), folder / "pages" / sid / "memo.md"
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
        tier, folder = tier_of(first_message(account, resume))
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
    # --add-dir は後ろの引数をいくつでも取るので、 --model より前に置いて発話を吸わせない
    model = CHILD_MODEL if os.environ.get("AGENT_CHILD") else MODEL
    command = [CLAUDE, *extra, "--model", model, "--effort", EFFORT, *claude_args]
    os.execvp(command[0], command)
    return 1


if __name__ == "__main__":
    sys.exit(main())
