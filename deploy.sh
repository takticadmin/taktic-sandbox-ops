#!/usr/bin/env bash
# Taktic sandbox · mise à jour automatique depuis takticadmin/taktic-platform-sandbox (main).
# Lancé toutes les 5 min par taktic-deploy.timer, sous l'utilisateur taktic.
# Ne fait rien si la branche main n'a pas bougé.
set -euo pipefail
SRC="/opt/taktic-sandbox/platform"
LOG="/opt/taktic-sandbox/deploy.log"
cd "$SRC"

git fetch -q origin main
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
[ "$LOCAL" = "$REMOTE" ] && exit 0

{
  echo "=== $(date -Is) déploiement $LOCAL -> $REMOTE"
  CHANGED="$(git diff --name-only "$LOCAL" "$REMOTE")"
  git reset -q --hard "$REMOTE"

  if echo "$CHANGED" | grep -qE '^(pyproject\.toml|uv\.lock)$'; then
    ~/.local/bin/uv sync --no-dev -q
  fi
  if echo "$CHANGED" | grep -q '^server/migrations/'; then
    .venv/bin/kt db migrate
  fi
  if echo "$CHANGED" | grep -qE '^(package(-lock)?\.json|app/package\.json)$'; then
    npm ci --no-audit --no-fund -s
  fi
  if echo "$CHANGED" | grep -qE '^(app/|package)'; then
    npm run build -s
  fi
  if echo "$CHANGED" | grep -qE '^(server/|pyproject\.toml|uv\.lock)'; then
    sudo /usr/bin/systemctl restart taktic-api
  fi
  echo "=== OK"
} >>"$LOG" 2>&1 || { echo "=== ECHEC, voir ci-dessus" >>"$LOG"; exit 1; }
