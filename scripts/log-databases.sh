#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

mapfile -t SERVICES < <(docker compose ps --services --filter "status=running" 2>/dev/null)

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "No running containers found. Start them first with: docker compose up -d"
  exit 1
fi

echo "Available containers:"
for i in "${!SERVICES[@]}"; do
  echo "  [$((i+1))] ${SERVICES[$i]}"
done
echo ""

while true; do
  read -rp "Choose a container [1-${#SERVICES[@]}]: " CHOICE
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#SERVICES[@]} )); then
    SERVICE="${SERVICES[$((CHOICE-1))]}"
    break
  fi
  echo "Invalid choice, try again."
done

echo ""
echo "==> Streaming logs for '$SERVICE' — press Ctrl+C to stop"
echo ""
docker compose logs --follow --tail=50 "$SERVICE"
