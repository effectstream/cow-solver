#!/usr/bin/env bash
# down.sh — FULL teardown of this directory's stack (backend + solver side),
# and a proof that it was full.
#
# `docker compose down` alone leaves the volumes, and every volume here is
# chain-keyed: the kernel's ledger mirror, the indexer's database, the
# batcher's parked inputs, the solver's operation journal, the relay's wallet
# cache and the provisioning receipt all describe one genesis. Keeping any of
# them across a chain reset gives a stack that starts cleanly and is wrong, so
# volumes go with the containers as one set.
#
#   ./down.sh                 containers + networks + volumes
#   ./down.sh --images        also remove the images this project built
#
# EVERY profile has to be named on the `down` lines below — this file's
# (`solver`, `e2e`) and the kernel's (`poster`, `prices`). Compose only removes
# what the selected profiles select, so a profiled service left out survives.
set -euo pipefail

cd "$(dirname "$0")"

REMOVE_IMAGES=0
for arg in "$@"; do
  case "${arg}" in
    --images) REMOVE_IMAGES=1 ;;
    --keep-images) REMOVE_IMAGES=0 ;;
    *) echo "unknown flag: ${arg}" >&2; exit 2 ;;
  esac
done

PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
PROJECT="${PROJECT:-cow_solver}"
PROFILES=(--profile solver --profile e2e --profile poster --profile prices)

echo "== tearing down project ${PROJECT} =="
docker compose "${PROFILES[@]}" down --volumes --remove-orphans --timeout 30 || true

if [ "${REMOVE_IMAGES}" -eq 1 ]; then
  echo "== removing images built by this project =="
  docker compose "${PROFILES[@]}" down --rmi local --volumes --remove-orphans || true
fi

echo
echo "== teardown proof =="
echo "-- containers (expect none) --"
docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}\t{{.Status}}'
echo "-- volumes (expect none) --"
docker volume ls --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Name}}'
echo "-- networks (expect none) --"
docker network ls --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Name}}'
echo "-- end --"
