#!/usr/bin/env bash
# 番人の置き場 (= 設定・禁止語の一覧・印・監査の記録) を、 この機械に配備した番人の部品に訊く。
# エージェントの shell の道具が source して `guard_place <名前>` を呼ぶ (= 名前は番人の scanners/guard_places.py の物)。
#
# 置き場の真値は番人の部品で、 器の根があれば根の下、 無ければ HOME の 6 か所になる。
# 番人が入っていない HOME (= 試験の作り物の HOME・入れる前の機械) では部品を読めないので、
# 番人が根の無い時に使う置き場をそのまま返す。

guard_place() {
    local places="$HOME/.git-hooks/scanners/guard_places.py"
    if [ -f "${places}" ]; then
        python3 "${places}" "$1"
        return
    fi
    case "$1" in
        master-words) printf '%s\n' "${ANON_TRUTH_PATH:-$HOME/.config/anon-words/master.txt}" ;;
        words)        printf '%s\n' "$(dirname "${ANON_TRUTH_PATH:-$HOME/.config/anon-words/master.txt}")" ;;
        marks)        printf '%s\n' "${AREA_GUARD_STATE:-$HOME/.cache/area-guard}" ;;
        audit-logs)   printf '%s\n' "$HOME/.local/state/guard-dispatcher" ;;
        *)            printf '%s\n' "${GUARD_CONFIG_DIR:-$HOME/.config/guard}/$1" ;;
    esac
}
