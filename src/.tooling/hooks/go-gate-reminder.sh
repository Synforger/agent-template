#!/bin/bash
# go-gate-reminder.sh - inject a one-line GO-gate reminder on every user prompt.
# Fired by Claude Code UserPromptSubmit hook. LLM-free, fail-open.
# Rationale: a read-only-until-explicit-GO rule loses to work momentum; a
# per-utterance mechanical reminder re-arms the check at every turn.
# Kept deliberately short (~15 tokens): the full rule lives in the always-load
# rules (rules/always.md § forbidden in the derivation) — this line only
# re-arms it. Wire via settings.json (see setup-hooks.sh output).
echo "[go-gate] standalone explicit GO only; mixed utterance = consult; no momentum."
exit 0
