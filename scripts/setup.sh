#!/usr/bin/env bash
# Idempotent setup script for macOS/Linux/WSL.
# Creates .env from .env.example and auto-generates PENPOT_SECRET_KEY
# and POSTGRES_PASSWORD. Won't overwrite an existing .env.
#
# Usage (from repo root):
#   ./scripts/setup.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$DIR/.env"
EXAMPLE_FILE="$DIR/.env.example"

if [[ -f "$ENV_FILE" ]]; then
  echo ".env already exists - not overwriting. Delete it first if you want to regenerate secrets." >&2
  exit 0
fi

if [[ ! -f "$EXAMPLE_FILE" ]]; then
  echo ".env.example not found at $EXAMPLE_FILE" >&2
  exit 1
fi

cp "$EXAMPLE_FILE" "$ENV_FILE"

SECRET_KEY=$(openssl rand -base64 64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
PG_PASSWORD=$(openssl rand -hex 16)

sed -i.bak \
  -e "s|^PENPOT_SECRET_KEY=.*|PENPOT_SECRET_KEY=${SECRET_KEY}|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASSWORD}|" \
  "$ENV_FILE"
rm -f "$ENV_FILE.bak"

echo "Created .env with a generated PENPOT_SECRET_KEY and POSTGRES_PASSWORD."
echo "Still fill in manually: PENPOT_PUBLIC_URI, RESEND_API_KEY, SMTP_FROM_EMAIL"
