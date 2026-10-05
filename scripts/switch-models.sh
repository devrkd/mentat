#!/usr/bin/env sh
# Switch the '# --- Models ---' block of .env to a named vendor preset.
# A real run rewrites ONLY that block (token/Slack lines are preserved) using
# an atomic temp-file + mv. Use --dry-run to preview the new block, --export to
# print 'export VAR=value' lines, and --verify to cross-check model ids against
# 'opencode models' (best effort; catalogs vary by provider/auth).
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"

MODEL_VARS='OPENCODE_MODEL OPENCODE_SMALL_MODEL ORCHESTRATOR_MODEL ORCHESTRATOR_VARIANT ARCHITECT_MODEL ARCHITECT_VARIANT DEVELOPER_MODEL DEVELOPER_VARIANT STAFF_MODEL STAFF_VARIANT'

usage() {
  cat <<'EOF'
Usage:
  scripts/switch-models.sh <vendor> [options]
  scripts/switch-models.sh custom VAR=value [VAR=value ...] [options]

Switches the '# --- Models ---' block of .env to a vendor preset.

Vendors:
  deepseek   DeepSeek models (current defaults)
  anthropic  Anthropic Claude models
  openai     OpenAI GPT models
  custom     Apply VAR=value overrides on top of the current .env values
             (valid vars: OPENCODE_MODEL, OPENCODE_SMALL_MODEL,
             ORCHESTRATOR_MODEL/VARIANT, ARCHITECT_MODEL/VARIANT,
             DEVELOPER_MODEL/VARIANT, STAFF_MODEL/VARIANT)

Options:
  --dry-run   Print the new Models block without writing .env
  --export    Print 'export VAR=value' lines instead of writing .env
  --verify    Check model ids against 'opencode models' (best effort)
  -h, --help  Show this help

Examples:
  scripts/switch-models.sh deepseek --dry-run
  scripts/switch-models.sh anthropic
  scripts/switch-models.sh custom OPENCODE_MODEL=openai/gpt-5 --dry-run
  scripts/switch-models.sh openai --export > models.env

Notes:
  - A real run rewrites ONLY the Models block; token/Slack lines are kept.
  - opencode does not auto-load .env. After switching:
      set -a; source .env; set +a     (then restart opencode)
  - Model ids and variant values are provider-specific. Verify with:
      opencode models
EOF
}

# Emit 'VAR=value' lines for the chosen preset.
# $1 = vendor; remaining args = VAR=value overrides (custom preset only).
emit_assignments() {
  vendor="$1"
  shift
  for var in $MODEL_VARS; do
    val=''
    if [ "$vendor" = custom ]; then
      val="$(override_value "$var" "$@" || true)"
      if [ -z "$val" ]; then
        val="$(grep "^${var}=" "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
      fi
    else
      case "$vendor:$var" in
        deepseek:OPENCODE_MODEL)       val='deepseek/deepseek-v4-pro' ;;
        deepseek:OPENCODE_SMALL_MODEL) val='deepseek/deepseek-flash' ;;
        deepseek:ORCHESTRATOR_MODEL)   val='deepseek/deepseek-flash' ;;
        deepseek:ORCHESTRATOR_VARIANT) val='low' ;;
        deepseek:ARCHITECT_MODEL)      val='deepseek/deepseek-v4-pro' ;;
        deepseek:ARCHITECT_VARIANT)    val='max' ;;
        deepseek:DEVELOPER_MODEL)      val='deepseek/deepseek-v4-pro' ;;
        deepseek:DEVELOPER_VARIANT)    val='max' ;;
        deepseek:STAFF_MODEL)          val='deepseek/deepseek-v4-pro' ;;
        deepseek:STAFF_VARIANT)        val='max' ;;
        anthropic:OPENCODE_MODEL)       val='anthropic/claude-sonnet-4-5' ;;
        anthropic:OPENCODE_SMALL_MODEL) val='anthropic/claude-haiku-4-5' ;;
        anthropic:ORCHESTRATOR_MODEL)   val='anthropic/claude-haiku-4-5' ;;
        anthropic:ORCHESTRATOR_VARIANT) val='low' ;;
        anthropic:ARCHITECT_MODEL)      val='anthropic/claude-sonnet-4-5' ;;
        anthropic:ARCHITECT_VARIANT)    val='max' ;;
        anthropic:DEVELOPER_MODEL)      val='anthropic/claude-sonnet-4-5' ;;
        anthropic:DEVELOPER_VARIANT)    val='max' ;;
        anthropic:STAFF_MODEL)          val='anthropic/claude-sonnet-4-5' ;;
        anthropic:STAFF_VARIANT)        val='max' ;;
        openai:OPENCODE_MODEL)       val='openai/gpt-5' ;;
        openai:OPENCODE_SMALL_MODEL) val='openai/gpt-4o-mini' ;;
        openai:ORCHESTRATOR_MODEL)   val='openai/gpt-4o-mini' ;;
        openai:ORCHESTRATOR_VARIANT) val='low' ;;
        openai:ARCHITECT_MODEL)      val='openai/gpt-5' ;;
        openai:ARCHITECT_VARIANT)    val='max' ;;
        openai:DEVELOPER_MODEL)      val='openai/gpt-5' ;;
        openai:DEVELOPER_VARIANT)    val='max' ;;
        openai:STAFF_MODEL)          val='openai/gpt-5' ;;
        openai:STAFF_VARIANT)        val='max' ;;
      esac
    fi
    if [ -n "$val" ]; then
      printf '%s=%s\n' "$var" "$val"
    fi
  done
}

# Print the override value for $1 if present in the remaining args; exit 1 if not.
override_value() {
  name="$1"
  shift
  for pair in "$@"; do
    case "$pair" in
      "${name}="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
  return 1
}

# Print the full Models block for a vendor preset.
# $1 = vendor; $2 = assignment lines.
make_block() {
  printf '%s\n' \
    '# --- Models ---' \
    "# Preset: $1" \
    '# opencode does NOT auto-load .env; load it first:  set -a; source .env; set +a' \
    '# Restart opencode after changing models.' \
    '# Verify ids with: opencode models' \
    "$2"
}

# Cross-check *_MODEL ids against 'opencode models' (best effort, non-fatal).
# $1 = assignment lines.
verify_model_ids() {
  if ! command -v opencode >/dev/null 2>&1; then
    echo "verify: 'opencode' not found on PATH; run 'opencode models' manually to check ids" >&2
    return 0
  fi
  catalog="$(opencode models 2>/dev/null || true)"
  if [ -z "$catalog" ]; then
    echo "verify: 'opencode models' returned nothing; skipped (catalog may need auth)" >&2
    return 0
  fi
  printf '%s\n' "$1" | while IFS= read -r line; do
    var="${line%%=*}"
    id="${line#*=}"
    case "$var" in
      *_MODEL)
        if printf '%s\n' "$catalog" | grep -qxF "$id"; then
          echo "verify: ok      $id"
        else
          echo "verify: MISSING $id (not listed by 'opencode models'; catalog varies by provider/auth)" >&2
        fi
        ;;
    esac
  done
}

# Locate the Models block in .env. Sets START (header line) and NEXT
# (line of the following section header, empty when the block runs to EOF).
# Exits non-zero with a clear error when .env or the block is missing.
find_block() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env not found at $ENV_FILE" >&2
    echo "Create it first, e.g.: cp .env.example .env" >&2
    exit 1
  fi
  START="$(grep -n '^# --- Models' "$ENV_FILE" | head -n 1 | cut -d: -f1)"
  if [ -z "$START" ]; then
    echo "Error: no '# --- Models ---' block found in $ENV_FILE" >&2
    echo "Add a Models section to .env (see .env.example) before switching." >&2
    exit 1
  fi
  NEXT="$(awk -v s="$START" 'NR > s && /^# --- / { print NR; exit }' "$ENV_FILE")"
}

VENDOR=''
OVERRIDES=''
DRY_RUN=0
EXPORT_MODE=0
VERIFY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --export) EXPORT_MODE=1 ;;
    --verify) VERIFY=1 ;;
    deepseek|anthropic|openai|custom) VENDOR="$1" ;;
    *=*) OVERRIDES="$OVERRIDES $1" ;;
    *) echo "Error: unknown argument '$1' (see --help)" >&2; exit 1 ;;
  esac
  shift
done

if [ -z "$VENDOR" ]; then
  echo 'Error: vendor is required: deepseek | anthropic | openai | custom' >&2
  usage >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ] && [ "$EXPORT_MODE" -eq 1 ]; then
  echo 'Error: --dry-run and --export are mutually exclusive' >&2
  exit 1
fi

if [ "$VENDOR" = custom ] && [ -z "$OVERRIDES" ]; then
  echo "Error: the 'custom' preset requires at least one VAR=value override" >&2
  usage >&2
  exit 1
fi

if [ "$VENDOR" != custom ] && [ -n "$OVERRIDES" ]; then
  echo "Error: VAR=value overrides are only valid with the 'custom' preset" >&2
  exit 1
fi

for pair in $OVERRIDES; do
  key="${pair%%=*}"
  case " $MODEL_VARS " in
    *" $key "*) ;;
    *) echo "Error: unknown model variable '$key' (valid: $MODEL_VARS)" >&2; exit 1 ;;
  esac
done

WRITE_MODE=0
if [ "$DRY_RUN" -eq 0 ] && [ "$EXPORT_MODE" -eq 0 ]; then
  WRITE_MODE=1
fi

if [ "$VENDOR" = custom ] || [ "$WRITE_MODE" -eq 1 ]; then
  find_block
fi

ASSIGNMENTS="$(emit_assignments "$VENDOR" $OVERRIDES)"

if [ "$VERIFY" -eq 1 ]; then
  verify_model_ids "$ASSIGNMENTS"
fi

if [ "$EXPORT_MODE" -eq 1 ]; then
  printf '%s\n' "$ASSIGNMENTS" | sed 's/^/export /'
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  make_block "$VENDOR" "$ASSIGNMENTS"
  echo ''
  echo "dry-run: no changes written to $ENV_FILE"
  exit 0
fi

# Real run: rebuild .env atomically from prefix + new block + suffix.
MODE=''
if command -v stat >/dev/null 2>&1; then
  MODE="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
fi

TMP="$ENV_FILE.switch.$$"
trap 'rm -f "$TMP"' EXIT HUP INT TERM

: > "$TMP"
if [ "$START" -gt 1 ]; then
  sed -n "1,$((START - 1))p" "$ENV_FILE" > "$TMP"
fi
make_block "$VENDOR" "$ASSIGNMENTS" >> "$TMP"
printf '\n' >> "$TMP"
if [ -n "$NEXT" ]; then
  sed -n "${NEXT},\$p" "$ENV_FILE" >> "$TMP"
fi

mv "$TMP" "$ENV_FILE"
trap - EXIT HUP INT TERM
if [ -n "$MODE" ]; then
  chmod "$MODE" "$ENV_FILE"
fi

echo "Updated $ENV_FILE with preset '$VENDOR'."
echo 'restart opencode to apply'
