#!/usr/bin/env bash
# gates.sh — static launch-contract gates for the solver side of the stack.
#
# Everything here is static or per-image: it renders the Compose model, builds
# the solver and relay images, and drives the solver's and the monitor site's
# fail-fast negative controls INSIDE a container with `--no-deps`. It does NOT
# bring a stack up, so no gate starts a chain on a shared host. The kernel's own
# gates (chain images, kernel image, public-network controls) live in
# kernel/deploy/gates.sh.
#
#   ./gates.sh [output-dir]
#
# Needs deploy/.env (./bootstrap.sh) and, for build-relay, the reference relay
# clone at RELAY_REFERENCE_DIR. Transcripts are written per gate, plus a
# summary. Exit 0 only if every gate passed.
set -uo pipefail

cd "$(dirname "$0")"

OUT="${1:-${GATES_OUT:-/tmp/cow-solver-gates}}"
mkdir -p "${OUT}"


PASS=0
FAIL=0
SUMMARY="${OUT}/summary.txt"
: > "${SUMMARY}"

run_gate() {
  local name="$1"; shift
  local log="${OUT}/${name}.log"
  echo "== gate ${name} =="
  {
    echo "### gate: ${name}"
    echo "### command: $*"
    echo "### started: $(date -u +%FT%TZ)"
    echo
  } > "${log}"
  if "$@" >> "${log}" 2>&1; then
    echo "PASS ${name}" | tee -a "${SUMMARY}"
    PASS=$((PASS + 1))
    return 0
  fi
  echo "FAIL ${name}  (see ${log})" | tee -a "${SUMMARY}"
  FAIL=$((FAIL + 1))
  return 1
}

# A gate whose PASS condition is a NON-zero exit and an expected message.
# Used for the solver fail-fast controls: "it refused" is the success case, so
# an exit 0 here is a gate failure, not a pass.
run_negative_gate() {
  local name="$1"; local expect="$2"; shift 2
  local log="${OUT}/${name}.log"
  echo "== negative gate ${name} =="
  {
    echo "### negative gate: ${name}"
    echo "### command: $*"
    echo "### expects: non-zero exit AND stderr/stdout matching: ${expect}"
    echo "### started: $(date -u +%FT%TZ)"
    echo
  } > "${log}"
  # The command's OUTPUT is captured separately from this header: the header
  # above quotes the expected pattern verbatim, so grepping the whole log would
  # let a literal pattern match its own "### expects:" line and pass the gate
  # with the process having said nothing at all (found at 00007-P-C: every
  # literal-pattern negative gate had been passing that way since D1).
  local out="${log}.out"
  local status=0
  "$@" > "${out}" 2>&1 || status=$?
  cat "${out}" >> "${log}"
  {
    echo
    echo "### exit status: ${status}"
  } >> "${log}"
  if [ "${status}" -eq 0 ]; then
    echo "FAIL ${name}  (exited 0; a missing mandatory variable MUST fail)" | tee -a "${SUMMARY}"
    FAIL=$((FAIL + 1))
    rm -f "${out}"
    return 1
  fi
  if ! grep -qE "${expect}" "${out}"; then
    rm -f "${out}"
    echo "FAIL ${name}  (exit ${status} but no message matching /${expect}/)" | tee -a "${SUMMARY}"
    FAIL=$((FAIL + 1))
    return 1
  fi
  rm -f "${out}"
  echo "PASS ${name}  (exit ${status}, expected message present)" | tee -a "${SUMMARY}"
  PASS=$((PASS + 1))
  return 0
}

if [ ! -f .env ]; then
  echo "deploy/.env missing — run ./bootstrap.sh first" >&2
  exit 1
fi

echo "gates output: ${OUT}"
{
  echo "cow-solver static gates"
  echo "host    : $(uname -srm)"
  echo "docker  : $(docker --version)"
  echo "compose : $(docker compose version --short 2>/dev/null || docker compose version)"
  echo "date    : $(date -u +%FT%TZ)"
  echo "disk    : $(df -h . | tail -1)"
  echo
} | tee -a "${SUMMARY}"

# ── C1: the Compose model renders, with every profile ──────────────────────
# The rendered model carries generated secrets in clear, so the values are
# redacted on the way out; a render error still fails the gate (pipefail).
run_gate compose-config sh -c \
  'docker compose --profile solver --profile e2e config | sed -E "s/^([[:space:]]*[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|API_KEY)[A-Z0-9_]*:[[:space:]]*).*/\\1<redacted>/"'

# ── C2: no profile, no solver side ──────────────────────────────────────────
# A plain `docker compose up` must start the backend only: the reference relay
# is a ledger-8 build that cannot run against this ledger-9 stack.
run_gate compose-default-has-no-solver-services sh -c \
  'svcs="$(docker compose config --services)"; echo "$svcs"; \
   echo "$svcs" | grep -qx kernel && \
   ! echo "$svcs" | grep -Eqx "relay|solver|solver-frontend|solver-provision|scripts"'

# ── C3: the profiles add exactly the solver side ────────────────────────────
run_gate compose-profiles-add-solver-services sh -c \
  'svcs="$(docker compose --profile solver --profile e2e config --services)"; echo "$svcs"; \
   for s in relay solver solver-frontend solver-provision scripts kernel; do \
     echo "$svcs" | grep -qx "$s" || { echo "missing $s"; exit 1; }; done'

# ── B1: the images build ────────────────────────────────────────────────────
# One gate per image so a failure names the image. solver, solver-frontend,
# solver-provision and scripts share the solver image.
run_gate build-solver        docker compose --profile solver build solver
run_gate build-relay         docker compose --profile solver build relay

# ── G3: solver fail-fast negative controls, IN CONTAINER ────────────────────
# These drive the REPO's launch contract (`bun run start.solver.ts` ->
# packages/solver/src/launch.ts), not the deployment's entrypoint wrapper: the
# wrapper is bypassed with `--entrypoint` precisely so the gate cannot be
# satisfied by a shell check of our own. `--no-deps` keeps them from starting a
# chain.
SOLVER_RUN=(docker compose run --rm --no-deps --entrypoint bun)

# G3a — the relay WS URL is absent. Expect exit 1 AND a message that names
# every problem at once, not just the first.
run_negative_gate solver-missing-relay-ws \
  "SOLVER_RELAY_WS_URL is required" \
  "${SOLVER_RUN[@]}" -e SOLVER_RELAY_WS_URL= solver run start.solver.ts

# G3b — the journal path is absent. Compose renders it as "" rather than
# unset, and `loadSolverJournalEnv` words the two differently ("is required"
# for undefined, "must be a non-empty canonical path" for ""); the D1 pattern
# only knew the first and had been passing vacuously (see run_negative_gate).
run_negative_gate solver-missing-journal-path \
  "SOLVER_JOURNAL_PATH (is required|must be a non-empty canonical path)" \
  "${SOLVER_RUN[@]}" -e SOLVER_JOURNAL_PATH= solver run start.solver.ts

# G3c — nothing MANDATORY is configured. Proves the aggregation property: ONE
# run reports all seven mandatory boundaries, so an operator does not fix and
# restart seven times.
#
# `SOLVER_FEE_SIZING_TAKER_INPUTS=1` is pinned here deliberately. This gate
# bypasses the entrypoint (that is its whole point), so it does NOT get the
# empty-optional unset pass that `entrypoint-common.sh` performs — and since
# 00006-V1 `compose.yml` forwards that knob, whose parser treats "" as
# MALFORMED rather than as unset. Leaving it blank would add an eighth problem
# and turn a gate about the seven mandatory boundaries into a gate about how
# this machine's `.env` happens to be filled in. G3f below covers the blank case
# properly, with the entrypoint in the loop where it belongs.
run_negative_gate solver-missing-everything \
  "solver launch configuration is invalid \(7 problems\)" \
  "${SOLVER_RUN[@]}" \
    -e MIDNIGHT_NETWORK_ID= -e ZSWAP_API= -e SOLVER_RELAY_WS_URL= \
    -e SOLVER_RELAY_HTTP_URL= -e SOLVER_RELAY_AUTH_TOKEN= \
    -e SOLVER_JOURNAL_PATH= -e SOLVER_SEED= \
    -e SOLVER_FEE_SIZING_TAKER_INPUTS=1 \
    solver run start.solver.ts

# G3d — a short bearer is refused. Both sides of the wire enforce 32 chars; the
# candidate must refuse before it ever dials.
run_negative_gate solver-short-auth-token \
  "SOLVER_RELAY_AUTH_TOKEN must be at least 32 characters" \
  "${SOLVER_RUN[@]}" -e SOLVER_RELAY_AUTH_TOKEN=tooshort solver run start.solver.ts

# G3e — a relative journal path is refused (it must be a mounted volume).
run_negative_gate solver-relative-journal-path \
  "SOLVER_JOURNAL_PATH must be an absolute mounted-volume path" \
  "${SOLVER_RUN[@]}" -e SOLVER_JOURNAL_PATH=operations.sqlite solver run start.solver.ts

# G3f — the empty-optional unset list actually covers the strict knobs (00006).
#
# Compose cannot express "leave this variable out": `FOO: ${FOO:-}` renders as
# FOO="". Most of this codebase's optional knobs read "" as a value, which is
# why `entrypoint-common.sh` unsets them — but four of them are STRICTER still,
# because their parsers reject "" outright:
# SOLVER_FEE_SIZING_TAKER_INPUTS (a bounded integer) and the
# SOLVER_DUST_MAX_PER_JOB / _PER_WINDOW / SOLVER_DUST_WINDOW_MS group (positive
# bigints, all-or-nothing). For those, a missing entry in the unset list is not
# a soft mis-default: it is a hard startup failure on a stack whose `.env` left
# them blank.
#
# So this gate keeps the entrypoint IN the loop (the only gate that does) and
# asserts the count: with all four blank AND the seven mandatory boundaries
# blank, the launch report must still be exactly the seven mandatory problems.
# An eighth means the unset list and `compose.yml` have drifted apart.
run_negative_gate solver-blank-strict-optionals \
  "solver launch configuration is invalid \(7 problems\)" \
  docker compose run --rm --no-deps --entrypoint bash \
    -e MIDNIGHT_NETWORK_ID= -e ZSWAP_API= -e SOLVER_RELAY_WS_URL= \
    -e SOLVER_RELAY_HTTP_URL= -e SOLVER_RELAY_AUTH_TOKEN= \
    -e SOLVER_JOURNAL_PATH= -e SOLVER_SEED= \
    -e SOLVER_FEE_SIZING_TAKER_INPUTS= \
    -e SOLVER_DUST_MAX_PER_JOB= -e SOLVER_DUST_MAX_PER_WINDOW= \
    -e SOLVER_DUST_WINDOW_MS= \
    -e SOLVER_SUPPORTED_PAIRS= -e SOLVER_MIN_JOB_OUTPUT= \
    solver -c '. /usr/local/bin/entrypoint-common.sh; cd "${REPO_ROOT}"; exec bun run start.solver.ts'

# G3g — removed manual pricing fails before the solver can touch a wallet,
# journal, backend or relay. It is not blank-normalized into a fallback.
run_negative_gate solver-retired-ladder-config \
  "SOLVER_LADDER_CONFIG was removed" \
  "${SOLVER_RUN[@]}" -e SOLVER_LADDER_CONFIG=/tmp/retired-ladders.json \
    solver run start.solver.ts

# G3h — (00007) a status listener can never come up open: with the port set
# (compose.yml sets it) a short bearer is one of the LISTED launch problems.
run_negative_gate solver-short-status-token \
  "SOLVER_STATUS_AUTH_TOKEN must be at least 32 characters" \
  "${SOLVER_RUN[@]}" -e SOLVER_STATUS_AUTH_TOKEN=tooshort10 \
    -e SOLVER_FEE_SIZING_TAKER_INPUTS=1 solver run start.solver.ts

# G3i — (00007) the monitor site's own fail-fast: the solver status URL is
# mandatory, and the site must refuse to start rather than render a page that
# can never show the solver. Bypasses the entrypoint like the solver gates.
run_negative_gate solver-frontend-missing-status-url \
  "SOLVER_FRONTEND_SOLVER_STATUS_URL (is required|must be a non-empty URL)" \
  docker compose run --rm --no-deps --entrypoint bun \
    -e SOLVER_FRONTEND_SOLVER_STATUS_URL= solver-frontend run start.solver-frontend.ts

# G3j — (00007) the site's aggregation property: with every mandatory boundary
# blank, ONE run reports all three (status URL, status token, kernel API).
run_negative_gate solver-frontend-missing-everything \
  "solver-frontend configuration is invalid \(3 problems\)" \
  docker compose run --rm --no-deps --entrypoint bun \
    -e SOLVER_FRONTEND_SOLVER_STATUS_URL= -e SOLVER_FRONTEND_SOLVER_STATUS_TOKEN= \
    -e SOLVER_FRONTEND_ZSWAP_API= -e SOLVER_FRONTEND_RELAY_HTTP_URL= \
    solver-frontend run start.solver-frontend.ts

# ── G4: the disabled solver is a clean exit 0, not a crash ──────────────────
run_gate solver-disabled-exits-zero \
  "${SOLVER_RUN[@]}" -e SOLVER_ENABLED=false solver run start.solver.ts

# ── G7: (00007) the monitor site's static assets are in the image ───────────
# `public/` is plain files, not a package export, so nothing at install time
# would notice if the build context ignored them; the site would 404 its own
# page at runtime.
run_gate solver-frontend-assets \
  docker compose run --rm --no-deps --entrypoint sh solver-frontend -c \
    'd=/app/packages/solver-frontend/public; set -e; for f in index.html styles.css app.js derive.js help.js; do test -f "$d/$f" || { echo "missing $d/$f"; exit 1; }; done; test -f /app/start.solver-frontend.ts; echo "solver-frontend assets present"'

{
  echo
  echo "passed: ${PASS}"
  echo "failed: ${FAIL}"
  echo "finished: $(date -u +%FT%TZ)"
} | tee -a "${SUMMARY}"

[ "${FAIL}" -eq 0 ]
