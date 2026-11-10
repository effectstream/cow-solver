#!/usr/bin/env bash
# entrypoint-common.sh — sourced by every solver-image entrypoint.
#
# The shared parts come from the kernel image's own helper, copied into this
# image from the kernel submodule as /usr/local/bin/kernel-entrypoint-common.sh:
# the readiness waits (wait-for.sh), `log`, `require_env`, REPO_ROOT, and the
# blank-means-unset rule for the kernel's optional knobs. This file applies the
# same rule to the solver's optional knobs.
set -euo pipefail

# shellcheck source=/usr/local/bin/kernel-entrypoint-common.sh
. /usr/local/bin/kernel-entrypoint-common.sh

# ── "" is not "unset", solver knobs ──────────────────────────────────────────
# Compose renders `FOO: ${FOO:-}` as FOO="" when .env leaves FOO blank, and the
# container then sees a variable that is present and empty. The solver's
# mandatory launch variables are deliberately absent from this list: an empty
# one must still reach `start.solver.ts` and be reported as missing, which is
# the deployment's fail-fast negative control.
#
# Four of these knobs reject "" outright rather than reading it as unset, so a
# blank .env entry would be a startup failure instead of a default:
#   * SOLVER_FEE_SIZING_TAKER_INPUTS — `parseBoundedIntegerEnv` reads "" as a
#     parse failure, a listed start:solver launch problem;
#   * SOLVER_DUST_MAX_PER_JOB / _PER_WINDOW / SOLVER_DUST_WINDOW_MS — read as a
#     group: `packages/solver/env.ts` requires all three set or all three unset,
#     and `parsePositiveBigint` rejects "", so three empty strings count as
#     "all set" and fail.
# The gate `solver-blank-strict-optionals` in deploy/gates.sh checks this list
# against compose.yml.
for _optional_env in \
  SOLVER_SUPPORTED_PAIRS \
  SOLVER_MIN_JOB_OUTPUT \
  SOLVER_FEE_SIZING_TAKER_INPUTS \
  SOLVER_DUST_MAX_PER_JOB \
  SOLVER_DUST_MAX_PER_WINDOW \
  SOLVER_DUST_WINDOW_MS
do
  if [ -z "${!_optional_env:-}" ]; then unset "${_optional_env}"; fi
done
unset _optional_env
