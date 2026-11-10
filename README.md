# COW solver for Offer Files

A third-party solver for the Midnight Intents relay. It mirrors the
[Offer Files](https://github.com/effectstream/zswap-offerfiles-kernel) offer
book, publishes whole-offer price ladders to the relay, and settles the swap
jobs the relay dispatches to it from its own wallet. It also ships a read-only
monitor site.

> **Real funds: NO-GO.** Do not run this solver with real funds. See
> [Real funds](#real-funds-no-go).

## Where this code came from

The solver lived in
[`effectstream/zswap-offerfiles-kernel`](https://github.com/effectstream/zswap-offerfiles-kernel)
and moved here with its git history. The kernel keeps only the backend.

- **H1** = kernel `ee82ff429906752aea20a830b9b4b21c9e30e4b9` (`ledger-v9`, the
  last head with the solver in it). This repository's history is the kernel's
  history at H1 filtered down to the solver's paths with `git filter-repo`:
  authors, dates and messages are unchanged, and `git log --follow` on a moved
  file shows the same commits as in the kernel. `main` starts at `416c4fa`
  (the filtered `869669b`; H1 itself only changed the kernel's `TODO.md`).
- **H2** = kernel `c7e1127451b79ae894138f6d259d4a5643ed21f5` (`ledger-v9`, the
  first head without the solver). The `kernel/` submodule is pinned here.

| Path | What it is |
|---|---|
| `packages/solver` | The solver: book mirror, ladder publication, relay client, swap-job executor, operation journal, status listener |
| `packages/solver-core` | Solver-side contracts: relay wire contract and fixtures, ladder derivation, fee sizing, admission policy, status contract |
| `packages/solver-frontend` | The read-only monitor site ([README](packages/solver-frontend/README.md)) |
| `packages/tests/grand-e2e` | The solver's e2e harnesses and their unit-tested helpers |
| `start.solver.ts`, `start.solver-frontend.ts` | The two process entrypoints |
| `deploy/` | Solver image, Compose services, launch gates, operator scripts |
| `kernel/` | The backend, as a git submodule (see below) |
| `docs/protocol-scope.md` | The solver's superseded scoping draft, kept as history |

## The kernel submodule

The solver imports these kernel packages through the submodule, as Bun
workspace members (`package.json` → `workspaces`):

| Package | Used for |
|---|---|
| `@zswap-da/kernel-client` | The kernel REST / update-stream / exact-files client, offer merging and balance checks, wallet helpers |
| `@zswap-da/api-contracts` | The versioned wire contracts of the kernel API |
| `@zswap-da/validator` | Offer validation, used for settlement verification |
| `@zswap-da/offer-guard` | Offer hashing, public-network rules and log redaction |
| `@zswap-da/node`, `@zswap-da/database` | Tests only: the book-mirror test runs the kernel node's real API on PGlite, and the release-hardening harness uses both |

Clone with the submodule:

```bash
git clone --recurse-submodules git@github.com:effectstream/cow-solver.git
# or, in an existing clone:
git submodule update --init
```

### Updating the submodule

```bash
git -C kernel fetch origin
git -C kernel checkout <kernel commit>
bun install                       # updates bun.lock if a kernel package's dependencies changed
bun run typecheck && bun run test:unit
git add kernel bun.lock
git commit -m "build: kernel submodule at <short sha>"
```

A contract change in the kernel fails the solver typecheck or the contract
tests here; it does not pass silently. CI checks out the pinned commit, so
moving the pin is always a reviewed commit.

The submodule is the interim mechanism. The plan is to publish the backend
packages to npm and depend on versions instead: see "Publish the backend
packages to npm", step 6, in the kernel's
[`TODO.md`](https://github.com/effectstream/zswap-offerfiles-kernel/blob/c7e1127451b79ae894138f6d259d4a5643ed21f5/TODO.md#publish-the-backend-packages-to-npm).

## Build and test

Bun **1.3.11** (the kernel's pin; Bun 1.3.3 cannot load the effectstream 0.300.x
runtime). `@effectstream/*` is 0.300.3, as in the kernel; `bun.lock` resolves
every shared package to a version the kernel's lockfile pins.

```bash
bun install --frozen-lockfile
bun run typecheck        # strict solver typecheck, 0 diagnostics required
bun run test:unit        # solver, solver-core, solver-frontend, grand-e2e helpers, deploy-script library
```

The grand-e2e image-scan tests need a Docker daemon. CI
(`.github/workflows/ci.yml`) runs the same two gates.

## What runs today, and what does not

**Runs:** the unit tests (including the book mirror against the kernel node's
real API), the typecheck, the monitor site against fixture data
(`packages/solver-frontend/README.md`) and the solver's launch-contract gates
(`deploy/gates.sh`).

**Does not run yet: the relay → solver → settle path on ledger 9.** The
reference relay is `shieldedtech/midnight-intents-swaps`, subtree
`phase1-native-swaps` (built by `deploy/images/relay/`), a **ledger-8** build
(`@midnight-ntwrk/ledger-v8` 8.1.0, wallet SDK 1.1.0). The kernel and this
solver run on Midnight 2.x / ledger 9, so the relay cannot settle against this
stack until it is ported. The Compose relay therefore sits behind an opt-in
profile, and the moved grand-e2e runners (`solver-offerfiles-e2e.ts`,
`solver-release-hardening-e2e.ts`, `relay-fixture-e2e.ts`) are not run: they
need that relay and a running kernel stack, and they still assume the kernel's
single-repository layout. The relay port, the relay e2e, running these runners,
the real-funds re-audit and a deployment are tracked in the kernel's
[`TODO.md` → COW solver follow-ups](https://github.com/effectstream/zswap-offerfiles-kernel/blob/c7e1127451b79ae894138f6d259d4a5643ed21f5/TODO.md#cow-solver-follow-ups-effectstreamcow-solver).

## Running the solver

The solver is a component of its own. It attaches to an already-running kernel
API and to a Midnight Intents relay.

```bash
bun run start:solver          # the one documented deployment entrypoint (start.solver.ts)
```

`start:solver` resolves and validates its whole configuration **before** it
opens a wallet, a socket or the journal. A missing or malformed value exits
non-zero listing **every** problem at once:

| Variable | Why it is mandatory |
|---|---|
| `MIDNIGHT_NETWORK_ID` | The SDK silently defaults to `undeployed`; a deployment must declare its network. An unknown value is refused. |
| `ZSWAP_API` | The kernel's Offer Files REST / stream base. Otherwise it defaults to `http://127.0.0.1:9999`, a developer default. |
| `SOLVER_RELAY_WS_URL` | The outbound Midnight Intents solver socket (`ws://` / `wss://`, no embedded credentials). |
| `SOLVER_RELAY_HTTP_URL` | The relay's public HTTP base for durable `GET /jobs/:jobId` recovery. Never derived from the websocket URL. |
| `SOLVER_RELAY_AUTH_TOKEN` | The shared relay bearer, at least 32 characters (the relay refuses shorter). |
| `SOLVER_JOURNAL_PATH` | Absolute path on a persistent per-instance volume. `:memory:` is refused. |
| `SOLVER_SEED` | An unset seed would select the repository's public dev seed, which is accepted only on `MIDNIGHT_NETWORK_ID=undeployed`. |

The relay URLs, the token and the journal are required in dry-run too.
`SOLVER_ENABLED=false` exits 0 without demanding any of it.

**Mainnet is dry-run by default.** On `mainnet`, `SOLVER_DRY_RUN` defaults to
`true`. Live settlement additionally requires the exact
`SOLVER_MAINNET_LIVE_TRADING_ACK=true` together with `SOLVER_DRY_RUN=false`;
`start.solver.ts` and `packages/solver/solver.mainnet.ts` enforce the same
boundary. Startup prints the resolved topology with no secret in it.

The optional read-only status listener (`SOLVER_STATUS_PORT`,
`SOLVER_STATUS_HOST`, `SOLVER_STATUS_AUTH_TOKEN`, a bearer of at least 32
characters) and the monitor site (`bun run start:solver-frontend`) are described
in [`packages/solver-frontend/README.md`](packages/solver-frontend/README.md).
Never publish the status port to a public interface.

### Solver fees: `deploy/scripts/provision-solver-fees.ts`

The solver needs no swap-token inventory, only NIGHT/DUST to pay the fees of the
settlements it submits. Fund the solver wallet (`SOLVER_SEED`) with unshielded
NIGHT through the network's supported funding path, then register it for DUST
from a checkout of this repository:

```bash
MIDNIGHT_NETWORK_ID=preprod MIDNIGHT_BLOCKFROST_PROJECT_ID=<token> \
SOLVER_SEED=<the solver wallet's 64-hex seed> \
SOLVER_PROVISION_RECEIPT=/path/to/provision-receipt.json \
bun run deploy/scripts/provision-solver-fees.ts
```

It syncs the wallet, refuses a wallet without NIGHT, registers the NIGHT for
DUST (or confirms an existing registration that already yields DUST) and writes
a receipt of the measured balances. It never funds, transfers, mints or prices
anything, and it redacts the Blockfrost token from every printed line. In the
Compose stack the `solver-provision` one-shot runs it before the solver starts
(`SOLVER_PROVISION_ENABLED=true`).

The kernel keeps its own copy of this script for its batcher wallet; the
duplicate is a cleanup item in the kernel's `TODO.md`.

## Compose stack

`deploy/compose.yml` includes the kernel's Compose file
(`kernel/deploy/compose.yml`: chain, Celestia, PGlite, kernel, batcher) and adds
the solver side behind opt-in profiles:

| Profile | Services |
|---|---|
| (none) | the kernel's backend only — **no relay** |
| `solver` | `solver-provision`, `relay`, `solver`, `solver-frontend` |
| `e2e` | `scripts`, the relay-driven e2e driver (with `solver`) |

```bash
cd deploy
./bootstrap.sh                       # writes .env from both examples, with fresh secrets
docker compose up -d                 # backend only
docker compose --profile solver up -d
./gates.sh /tmp/cow-solver-gates     # static launch-contract gates (no stack is started)
./down.sh                            # every profile, with volumes
```

The relay image builds from a local clone of the reference relay
(`RELAY_REFERENCE_DIR` in `deploy/.env.example`). Until the relay is ported to
ledger 9, the `solver` profile cannot settle on this stack (see above).

## Real funds: NO-GO

The owner's conditional GO of 2026-08-21 for real funds covered only the audited
solver commit `381022d`. The solver has changed since, including its port to
ledger 9, so **real funds are NO-GO** until the solver is re-audited and the
owner makes a new decision. The mainnet dry-run default and
`SOLVER_MAINNET_LIVE_TRADING_ACK` stay as described above.
