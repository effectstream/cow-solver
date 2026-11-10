# deploy/images/solver/Dockerfile — one image, single-process entrypoints.
#
# Build context: the repository ROOT, with the kernel submodule checked out
# (`git submodule update --init`). The image carries this Bun workspace, which
# includes the kernel packages the solver imports from kernel/packages/, and
# ships one entrypoint per solver-side component:
#
#   entrypoint-solver.sh            exec bun run start.solver.ts
#   entrypoint-solver-frontend.sh   exec bun run start.solver-frontend.ts (:8080)
#   entrypoint-solver-provision.sh  one-shot: verify the solver wallet's
#                                   prefunded NIGHT/DUST and write a receipt
#   entrypoint-scripts.sh           the relay-driven e2e driver (profile e2e)
#
# Every entrypoint `exec`s one process, so the container's PID 1 is the real
# workload and Compose signals reach it. The backend services (chain, kernel,
# batcher) run from the kernel's own images; see deploy/compose.yml.
#
# Bun 1.3.11 matches the kernel image and the CI pin: Bun 1.3.3 cannot load the
# effectstream 0.300.x runtime.
FROM oven/bun:1.3.11 AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Workspace manifests first so a source-only edit does not re-run `bun install`.
# Every workspace member listed in the root package.json must be present or
# `--frozen-lockfile` refuses the install.
COPY package.json bun.lock ./
COPY packages/solver/package.json                  packages/solver/
COPY packages/solver-core/package.json             packages/solver-core/
COPY packages/solver-frontend/package.json         packages/solver-frontend/
COPY packages/tests/package.json                   packages/tests/
COPY kernel/packages/api-contracts/package.json    kernel/packages/api-contracts/
COPY kernel/packages/database/package.json         kernel/packages/database/
COPY kernel/packages/kernel-client/package.json    kernel/packages/kernel-client/
COPY kernel/packages/node/package.json             kernel/packages/node/
COPY kernel/packages/offer-guard/package.json      kernel/packages/offer-guard/
COPY kernel/packages/validator/package.json        kernel/packages/validator/

RUN bun install --frozen-lockfile

# The rest of the source; Dockerfile.dockerignore next to this file keeps
# node_modules and git metadata out of the context.
COPY . .

# Entrypoints last: editing one must not invalidate the install. The readiness
# waits and the shared helper come from the kernel submodule.
COPY kernel/deploy/images/kernel/wait-for.sh               /usr/local/bin/wait-for.sh
COPY kernel/deploy/images/kernel/entrypoint-common.sh      /usr/local/bin/kernel-entrypoint-common.sh
COPY deploy/images/solver/entrypoint-common.sh             /usr/local/bin/entrypoint-common.sh
COPY deploy/images/solver/entrypoint-solver.sh             /usr/local/bin/entrypoint-solver.sh
COPY deploy/images/solver/entrypoint-solver-frontend.sh    /usr/local/bin/entrypoint-solver-frontend.sh
COPY deploy/images/solver/entrypoint-solver-provision.sh   /usr/local/bin/entrypoint-solver-provision.sh
COPY deploy/images/solver/entrypoint-scripts.sh            /usr/local/bin/entrypoint-scripts.sh
RUN chmod +x /usr/local/bin/*.sh

# No default CMD: every service names its entrypoint explicitly, so a service
# that forgot to is a startup error rather than a surprise solver.
CMD ["/bin/sh", "-c", "echo 'this image has no default command — set one of /usr/local/bin/entrypoint-*.sh' >&2; exit 64"]
