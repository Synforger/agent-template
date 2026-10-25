#!/bin/bash
# エージェントの起動の入口 (= 起動の alias と PWA が呼ぶ)。 本体と使い方は .tooling/lib/claude-launch.py (= 型が配る)。
# この file はエージェントの持ち物で、 agent ごとに claude へ足す旗は "$@" の前に書く (= 例: --chrome)。
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/claude-launch.py" "$@"
