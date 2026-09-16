# OpenClaw + AlphaClaw + GBrain (PGLite engine) — arthur-ai fork
#
# Derived from render-examples/openclaw-render-template (the BASE template this
# service already runs), with the GBrain pieces from render-examples/openclaw-gbrain
# ported in. Deliberate deltas from that reference are marked [DELTA] below.

FROM node:22.22.3-slim

# Base-template deps, unchanged, plus ca-certificates + unzip for the bun installer.
# python3/make/g++ stay: AlphaClaw's dep tree contains native modules.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl procps python3 make g++ cron tini ca-certificates unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ---------------------------------------------------------------------------
# AlphaClaw (identical to the base template — this layer is what you already run)
# ---------------------------------------------------------------------------
COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

ENV ALPHACLAW_ROOT_DIR=/data
# GBRAIN_HOME is a PARENT dir; gbrain appends '.gbrain' itself, so this
# resolves to /data/.gbrain on the persistent disk. Baked in rather than left
# to render.yaml so the entrypoint's require_env can never fail on a fresh
# service or an unsynced blueprint. Override via a Render env var if needed.
ENV GBRAIN_HOME=/data
RUN mkdir -p /data

# ---------------------------------------------------------------------------
# bun — GBrain ships as a Bun package (bin: src/cli.ts, run from TS source).
# GBrain v0.50.5.0 declares engines.bun ">=1.3.11"; 1.3.13 satisfies it.
# Pinned so the build is reproducible.
# ---------------------------------------------------------------------------
ENV BUN_INSTALL=/usr/local/bun
ENV PATH="$BUN_INSTALL/bin:/app/node_modules/.bin:$PATH"
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.13" \
    && bun --version

# ---------------------------------------------------------------------------
# GBrain
#
# Not on npm (the npm package named `gbrain` is an unrelated GPU ML library).
# Installed from GitHub, pinned by commit SHA. Bump GBRAIN_REF to upgrade.
#
# 668b9bac = v0.50.5.0 (2026-09-16).
#
# [DELTA] The reference template pins 5008b287 (v0.42.59.0, 2026-07-13). Do NOT
# use that pin here. Key-aware provider routing landed in v0.46.21.0 (649ffe5f,
# 2026-08-18, "fact extraction without Anthropic"): it added PROVIDER_TIER_DEFAULTS
# in src/core/model-config.ts, which walks ANTHROPIC_API_KEY then OPENAI_API_KEY
# and is the ONLY reason an OpenAI-only install resolves a chat/expansion model.
# At the reference's pin those tiers hard-default to anthropic:claude-* and this
# image would fail closed with no Anthropic key. v0.42.59.0 also predates the
# v0.50.5.0 critical+high security advisory wave.
#
# [DELTA] The reference sets `ENV npm_config_ignore_scripts=true`. Omitted here,
# for two reasons:
#   1. It is unnecessary — scripts/postinstall.ts is written to never fail an
#      install (every path calls process.exit(0); with no brain yet it just
#      prints a hint).
#   2. As a persistent ENV it leaks into runtime, where openclaw.json sets
#      skills.install.nodeManager=npm — the agent's own skill installs would
#      silently skip lifecycle scripts. It would also suppress the postinstall
#      of @electric-sql/pglite, which GBrain lists in trustedDependencies
#      precisely so that it runs.
# ---------------------------------------------------------------------------
ARG GBRAIN_REF=668b9bac302705f3bca0ae4792a49fab0a79a74e
RUN bun add -g "github:garrytan/gbrain#${GBRAIN_REF}" \
    && gbrain --version

# ---------------------------------------------------------------------------
# Stage the GBrain skill pack (85 entries at the repo root under skills/).
# The persistent disk is not mounted at build time, so we stage into the image
# and the entrypoint copies to the disk on first boot.
# ---------------------------------------------------------------------------
RUN mkdir -p /app/skills-seed \
    && GBRAIN_SKILLS_DIR="$BUN_INSTALL/install/global/node_modules/gbrain/skills" \
    && if [ ! -d "$GBRAIN_SKILLS_DIR" ]; then \
         GBRAIN_SKILLS_DIR="$(find "$BUN_INSTALL" -type d -path '*/gbrain/skills' 2>/dev/null | head -n1)"; \
       fi \
    && if [ -n "$GBRAIN_SKILLS_DIR" ] && [ -d "$GBRAIN_SKILLS_DIR" ]; then \
         echo "Seeding skills from $GBRAIN_SKILLS_DIR"; \
         cp -r "$GBRAIN_SKILLS_DIR/." /app/skills-seed/; \
       else \
         echo "ERROR: could not locate gbrain skills/ under $BUN_INSTALL" >&2; \
         exit 1; \
       fi

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# [DELTA] Port 3000, not the reference's 10000 — this service already runs on
# 3000 and the base template's Express/gateway proxy is wired to it.
EXPOSE 3000

# [DELTA] tini is kept as PID 1 (the base template has it; the GBrain reference
# drops it). The watchdog + cron fork children; without a reaper they zombie.
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
CMD ["alphaclaw", "start"]
