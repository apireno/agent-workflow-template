#!/usr/bin/env bash
# openrouter-chat.sh — stdin prompt -> stdout completion via the OpenRouter chat API.
#
# The CLI-shaped executor behind the `kimi` review engine. Same contract as the gemini
# CLI (`cat prompt | openrouter-chat.sh > out`), so every engine dispatch site treats it
# identically. The model is env-selectable so a vendor change is a one-word swap, not new
# plumbing (CEO 2026-06-19: the engine is a CHOICE — companies keep changing their minds).
#
# BRIGHT-LINE NOTE: this is NOT the Anthropic API. It is metered spend on the OpenRouter
# account (pennies per review for kimi-k2.6: ~$0.55/M in, $3.20/M out), which is explicitly
# fair game (feedback_cto_autonomy_avoid_api_charges). A usage line prints to stderr per
# call so spend stays visible.
#
# env:
#   OPENROUTER_API_KEY     required
#   OPENROUTER_MODEL       default: moonshotai/kimi-k2.6  (any OpenRouter slug works —
#                          deepseek/deepseek-chat-v3.1, qwen/..., etc.)
#   OPENROUTER_MAX_TOKENS  default: 16000
#   OPENROUTER_TIMEOUT     seconds, default: 600
#
# stdout: the completion text only. stderr: diagnostics + usage line. Non-zero exit on
# HTTP error, API error object, or empty completion (so retry wrappers see the failure).

set -uo pipefail
: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY not set — required for the kimi engine}"

exec python3 -c '
import json, os, sys, urllib.request, urllib.error

prompt = sys.stdin.read()
if not prompt.strip():
    sys.stderr.write("openrouter-chat: empty prompt on stdin\n")
    sys.exit(1)

model = os.environ.get("OPENROUTER_MODEL", "moonshotai/kimi-k2.6")
body = {
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": int(os.environ.get("OPENROUTER_MAX_TOKENS", "16000")),
}
req = urllib.request.Request(
    "https://openrouter.ai/api/v1/chat/completions",
    data=json.dumps(body).encode(),
    headers={
        "Authorization": "Bearer " + os.environ["OPENROUTER_API_KEY"],
        "Content-Type": "application/json",
    },
)
try:
    with urllib.request.urlopen(req, timeout=int(os.environ.get("OPENROUTER_TIMEOUT", "600"))) as r:
        resp = json.load(r)
except urllib.error.HTTPError as e:
    sys.stderr.write("openrouter-chat: HTTP %s\n%s\n" % (e.code, e.read().decode(errors="replace")[:2000]))
    sys.exit(1)
except Exception as e:
    sys.stderr.write("openrouter-chat: %s\n" % e)
    sys.exit(1)

if "error" in resp:
    sys.stderr.write("openrouter-chat: API error: %s\n" % json.dumps(resp["error"])[:2000])
    sys.exit(1)

choice = (resp.get("choices") or [{}])[0]
content = (choice.get("message") or {}).get("content") or ""
if not content.strip():
    sys.stderr.write("openrouter-chat: empty completion: %s\n" % json.dumps(resp)[:2000])
    sys.exit(1)

sys.stdout.write(content)
u = resp.get("usage") or {}
sys.stderr.write(
    "openrouter-chat: model=%s prompt_tokens=%s completion_tokens=%s\n"
    % (resp.get("model", model), u.get("prompt_tokens"), u.get("completion_tokens"))
)
'
