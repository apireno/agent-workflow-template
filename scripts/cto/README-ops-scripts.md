# CTO ops scripts — the analyzer-friendly rule

Permission prompts are a function of command SHAPE: inline quoting, heredocs, pipes, and command
substitution cannot be statically analyzed and prompt every time. The rule (hard, learned the
expensive way):

1. **Any shell shape needed twice becomes a committed script here, called with plain arguments.**
2. **Script + allowlist entry = ONE unit.** The same commit that adds a script adds
   `"Bash(bash <abs-path>/<script>:*)"` to `.claude/settings.json permissions.allow` (see
   `settings.cto.json.template`). A script without its allowlist entry prompts like raw bash.
3. **Generic scripts live in THIS template** and propagate to CTO homes; project-specific wrappers
   (e.g. a queue-inspection CLI wrapper) live in the project's CTO home, following the same
   two-part rule, and their PATTERN gets noted back here.

Inventory: qa-send (keystroke injection via message file) · wait-for-artifact ·
watch-file-or-prompt (file-landed OR window permission-prompt; "now" arg self-captures the mtime
baseline) · supervise-worker (liveness + queue-gated restart file) · window-peek (on-screen window
contents + `list` inventory) · close-window-id (orphan-safe id-direct close; handoff id-overwrite
leaves orphans) · app-stack (health|up|down|reset|wait|log for the project app stack — configure via
STACK_APP_ROOT / STACK_APP_PORT / STACK_DB_PORT / STACK_BRINGUP_SCRIPT / STACK_RESET_SCRIPT).
