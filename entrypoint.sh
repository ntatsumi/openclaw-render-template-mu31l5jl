#!/usr/bin/env bash
# Entrypoint: OpenClaw + AlphaClaw + GBrain (PGLite engine), OpenAI-only.
#
# Runs on every container start. Everything here is idempotent; the expensive
# first-boot work short-circuits on the config.json sentinel on the persistent
# disk. Brain INIT failure is fatal (better a red deploy than an agent running
# against a half-built brain). Brain-repo PULL failure on a later boot is a
# warning, not a crash — a GitHub blip should not take the agent offline.
#
# Deliberately NOT done here: `gbrain sync`. Sync embeds, which is slow and
# unbounded; blocking container start on it would trip Render's health check.
# Sync runs from cron / the agent instead. See README.

set -euo pipefail

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# 0. Load /data/.env.
#
# The base template keeps Setup-UI-managed variables in /data/.env and loads
# them in the server process — which starts AFTER this script. GBrain needs
# OPENAI_API_KEY *now*: `gbrain init` resolves the embedding provider and sizes
# the vector column at init time, and with no key it would initialize keyless
# (keyword-only) and require a later `gbrain init --force` to repair.
#
# Parsed line-by-line rather than `set -a; . /data/.env` so the file is treated
# as data, not shell. Real environment (Render dashboard) always wins.
# ---------------------------------------------------------------------------
if [ -f /data/.env ]; then
  log "Loading /data/.env (existing environment takes precedence)"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"      # ltrim
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    if [ -z "${!key:-}" ]; then
      val="${line#*=}"
      val="${val%\"}"; val="${val#\"}"
      val="${val%\'}"; val="${val#\'}"
      export "$key=$val"
    fi
  done < /data/.env
fi

# ---------------------------------------------------------------------------
# 1. Validate required environment.
#
# NOTE: there is deliberately NO require_env ANTHROPIC_API_KEY here (the
# reference template has one). GBrain >= v0.46.21.0 resolves the chat and
# expansion tiers from whichever provider key is present, via
# PROVIDER_TIER_DEFAULTS in src/core/model-config.ts. OPENAI_API_KEY alone is a
# supported posture: embeddings, multi-query expansion and LLM chunking all
# route to OpenAI.
# ---------------------------------------------------------------------------
require_env() {
  if [ -z "${!1:-}" ]; then
    log "ERROR: $1 is not set (checked process env and /data/.env)."
    exit 1
  fi
}

require_env OPENAI_API_KEY
require_env ALPHACLAW_ROOT_DIR
require_env GBRAIN_HOME

# Anthropic sorts BEFORE OpenAI in GBrain's key walk. If a key ever lands in
# /data/.env via the Setup UI, GBrain would silently start routing chat and
# expansion to Anthropic. Warn loudly rather than change behaviour silently.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  warn "ANTHROPIC_API_KEY is set. GBrain prefers Anthropic over OpenAI for the"
  warn "chat + expansion tiers. Unset it, or pin the tiers explicitly with"
  warn "'gbrain init --force --chat-model openai:<model> --expansion-model openai:<model>'."
fi

# ---------------------------------------------------------------------------
# 2. Resolve paths.
#
# IMPORTANT: skills live at $ALPHACLAW_ROOT_DIR/.openclaw/skills, NOT
# $ALPHACLAW_ROOT_DIR/skills. The GBrain reference template seeds the latter;
# on the base template that directory is never read, so a verbatim port yields
# a green deploy with an agent that cannot see a single GBrain skill.
# ---------------------------------------------------------------------------
OPENCLAW_HOME="${OPENCLAW_HOME:-$ALPHACLAW_ROOT_DIR/.openclaw}"
SKILLS_DIR="$OPENCLAW_HOME/skills"
BRAIN_REPO_DIR="${GBRAIN_BRAIN_REPO_DIR:-$ALPHACLAW_ROOT_DIR/brain}"

mkdir -p "$ALPHACLAW_ROOT_DIR" "$SKILLS_DIR"
# gbrain treats GBRAIN_HOME as a PARENT dir and appends '.gbrain' itself.
mkdir -p "$GBRAIN_HOME/.gbrain"

FIRST_BOOT=0
[ -f "$GBRAIN_HOME/.gbrain/config.json" ] || FIRST_BOOT=1

# ---------------------------------------------------------------------------
# 3. Brain repo — git is the system of record.
#
# GBrain's contract is markdown-source-of-truth: the derived tables (facts,
# takes, links, timeline) are rebuilt from markdown, and CI enforces it
# (scripts/check-system-of-record.sh). The repo also gives the brain a backup
# the Render disk cannot: /data/.gbrain is NOT inside /data/.openclaw, so the
# existing workspace-repo backup never sees the PGLite file.
#
# The repo is cloned to /data/brain — outside /data/.openclaw on purpose, so it
# is not swept into the arthur-atlas workspace backup as a nested repo.
# ---------------------------------------------------------------------------
if [ -n "${GBRAIN_BRAIN_REPO:-}" ]; then
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    # Credential store, mode 600, outside the repo — so the token is never
    # written into $BRAIN_REPO_DIR/.git/config and never appears in argv/ps.
    umask 077
    printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > /root/.git-credentials
    git config --global credential.helper store
    umask 022
  fi
  git config --global --add safe.directory "$BRAIN_REPO_DIR" || true

  if [ ! -d "$BRAIN_REPO_DIR/.git" ]; then
    log "Cloning brain repo $GBRAIN_BRAIN_REPO -> $BRAIN_REPO_DIR"
    # Fatal: a first boot that silently proceeds without the brain repo would
    # initialize an empty brain and look healthy.
    git clone "https://github.com/${GBRAIN_BRAIN_REPO}.git" "$BRAIN_REPO_DIR"
  else
    log "Brain repo present; pulling latest."
    git -C "$BRAIN_REPO_DIR" pull --ff-only || warn "git pull failed; continuing with the on-disk copy."
  fi
else
  log "GBRAIN_BRAIN_REPO not set; brain repo sync disabled."
fi

# ---------------------------------------------------------------------------
# 4. Initialize the GBrain brain (idempotent).
#
# PGLite = Postgres compiled to WASM, in-process, with pgvector and pg_trgm
# bundled — no external database, no CREATE EXTENSION step. Config and the
# brain file both live under $GBRAIN_HOME/.gbrain on the disk.
#
# Gated on config.json: re-running init against an existing brain is a known
# footgun (it can flip a configured engine back to pglite — see the warning at
# the top of gbrain's src/commands/init.ts).
# ---------------------------------------------------------------------------
if [ "$FIRST_BOOT" -eq 1 ]; then
  log "First boot: running gbrain init (PGLite engine)..."
  gbrain init --pglite --non-interactive
else
  log "gbrain config found; skipping init."
fi

# Record where the brain repo lives so bare `gbrain sync` resolves it.
if [ -n "${GBRAIN_BRAIN_REPO:-}" ] && [ -d "$BRAIN_REPO_DIR/.git" ]; then
  gbrain config set sync.repo_path "$BRAIN_REPO_DIR" \
    || warn "could not persist sync.repo_path; pass --repo $BRAIN_REPO_DIR to gbrain sync."
fi

# ---------------------------------------------------------------------------
# 5. Seed the GBrain skill pack.
#
# `cp -rn` never overwrites, so local edits to a seeded skill survive every
# redeploy. The flip side: an upgraded skill will NOT replace an existing file.
# After bumping GBRAIN_REF, refresh deliberately (see README).
# `/.` rather than `/*` so dot-prefixed entries are included.
# ---------------------------------------------------------------------------
if [ -d /app/skills-seed ]; then
  log "Seeding GBrain skills into $SKILLS_DIR..."
  cp -rn /app/skills-seed/. "$SKILLS_DIR/" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 6. Keep the seeded pack out of the workspace backup repo.
#
# /data/.openclaw IS the git repo that auto-backs-up to arthur-ai/arthur-atlas.
# Without this, first boot commits 85 vendored skill directories, and every
# GBRAIN_REF bump churns them — burying your own edits in the diff. They are
# fully reproducible from the pinned ref, so they are excluded locally via
# .git/info/exclude (untracked, so this never fights the committed .gitignore).
# ---------------------------------------------------------------------------
if [ -d "$OPENCLAW_HOME/.git" ] && [ -d /app/skills-seed ]; then
  EXCLUDE_FILE="$OPENCLAW_HOME/.git/info/exclude"
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  touch "$EXCLUDE_FILE"
  for entry in /app/skills-seed/*; do
    [ -e "$entry" ] || continue
    rel="skills/$(basename "$entry")"
    grep -qxF "$rel" "$EXCLUDE_FILE" || echo "$rel" >> "$EXCLUDE_FILE"
  done
  log "GBrain skills excluded from the workspace backup repo."
fi

# ---------------------------------------------------------------------------
# 7. Hand off to AlphaClaw.
# ---------------------------------------------------------------------------
log "Starting AlphaClaw..."
exec "$@"
