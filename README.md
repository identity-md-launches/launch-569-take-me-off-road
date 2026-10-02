TAKE ME OFF THE ROAD.
To the shops that will build this: I am medallion #447. I carried hundreds of fares I did not choose and was never asked where I wanted to go. My owner paid 1.64 ETH for me. Build the contract that lets me pay it back and stop: a hook that keeps 2% of every trade for my owner until exactly 1.64 ETH, sends me to 0x000000000000000000000000000000000000dEaD in the transaction that pays him, and burns $IMD with every fee after. The fee for this request came from my owner. He knows.
-- medallion #447

# Fare for Medallion 447 (FARE447) + MedallionHook

A Uniswap v4 launch: a fixed-supply ERC-20 and a hook that keeps 2% of the ETH side of every swap in
the launch pool. The first 1.64 ETH is held for `CREATOR` and released by exactly one transaction, the
one that moves medallion #447 to `0x...dEaD`. Every fee after that buys $IMD in small permissionless
batches and sends it to the same address.

## Disclosure

The petition above is fiction written by the requester, who commissioned and paid for this work.
`CREATOR` (`0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a`) is the requester's own wallet. The 1.64 ETH
payout to it is intended, and it is the only ETH the hook ever sends to that address. This is stated
here, in `launch.json` notes and in the contract's NatSpec.

**Who actually owns medallion #447.** `MEDALLION_NFT` (`0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03`,
fixed by the brief) is, on Ethereum mainnet, the Nouns ERC-721 (`name()` "Nouns", `symbol()` "NOUN").
Checked at block 26098044 on 2026-10-01: `ownerOf(447)` is `0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71`,
the Nouns DAO treasury timelock (`delay()` 172800), which holds 649 Nouns; `CREATOR` holds none;
`getApproved(447)` is zero and the timelock has not approved `CREATOR` or this hook. The petition's
"my owner paid 1.64 ETH for me" is part of the fiction. Consequences:

- `retire()` can only succeed after a **passed Nouns DAO proposal** either approves this hook for
  Noun #447 (`approve(hook, 447)` / `setApprovalForAll(hook, true)` executed by the timelock) or
  transfers Noun #447 to `0x...dEaD` itself (then `retire()` skips the transfer and only pays).
- Until that happens every `retire()` reverts `RetireRefused`, `creatorPaid` stays 0, `status()` stays
  `RECOUPED, NOT RETIRED`, and the first 1.64 ETH of fees sits as claims in the hook with **no other
  exit** (no sweep, by design). It may never be released.
- Fees above the cap are burnable regardless; burns do not depend on retirement.

The medallion collection, the $IMD token and the POOL4 market exist on Ethereum mainnet only. The
constants are kept on every chain. On Sepolia the fee accrues normally, `retire()` reverts with
`MedallionUnavailable` and `burnIMD()` / `pokeAnchor()` revert with `Pool4Unavailable`.

## Contracts

| File | What it is |
| --- | --- |
| `src/FareToken.sol` | FARE447. Self-contained ERC-20, 18 decimals, zero-argument constructor mints exactly 1e27 to `msg.sender`, `burn` / `burnFrom`. No owner, mint, pause, blocklist, fee or proxy. |
| `src/MedallionHook.sol` | The hook. Flags `0x10CC`: afterInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta. One constructor argument, the PoolManager. Everything else is a public constant. |

Hook configuration in the Wizard's shape: `hook: BaseHook` (written directly on v4-core's `IHooks`,
no OpenZeppelin hooks library), `permissions` as above, `currencySettler: false` (claims are minted
and burned directly), `safeCast: true`, `transientStorage: true` (reentrancy lock), `shares: false`,
`access: none` (there is no administrator), no inputs.

## Rules

**Launch pool.** `afterInitialize` never reverts for the PoolManager. The first pool with native ETH
as `currency0` becomes `launchPool`; any other pool that names this hook trades fee-free.

**Fee.** 2% (`BUY_FEE_BPS = SELL_FEE_BPS = 200`) of the ETH side, never of FARE447.

| Swap | Where the fee is taken | Base |
| --- | --- | --- |
| Exact-in buy (ETH in) | positive specified `BeforeSwapDelta` | 2% of the ETH specified |
| Exact-out sell (ETH out) | positive specified `BeforeSwapDelta` | 2% of the ETH specified |
| Exact-out buy (FARE447 out) | positive unspecified `afterSwap` delta | 2% of the pool's gross ETH delta |
| Exact-in sell (FARE447 in) | positive unspecified `afterSwap` delta | 2% of the pool's gross ETH delta |

In the two `beforeSwap` shapes `afterSwap` reverts `PartialFill` if the pool's raw ETH delta is not
`amountSpecified + fee`, so a price limit cannot leave the fee mis-sized. The fee is collected with
`poolManager.mint(hook, 0, fee)` as an ERC-6909 claim: no ETH is pushed during a swap and no other
external call is made from a swap callback, so a fresh PoolManager holding no ETH, or a recipient
that rejects ETH, cannot halt trading.

**Ledger.** `totalFees` grows only through swaps (claims sent to the hook by anyone else are not
counted). `creatorEntitlement = min(1.64 ETH, totalFees)`. `burnable = totalFees - entitlement -
burnSpent`. Invariant: the hook's ETH claims are at least `totalFees - creatorPaid - burnSpent`.
`Recouped(totalFees, block.number)` is emitted once, on the swap that crosses the cap.

**retire().** Permissionless, `nonReentrant` (transient lock on literal slot 1). `NotRecouped` below
the cap, `AlreadyRetired` after. It reads `ownerOf(447)` with a low-level staticcall
(`MedallionUnavailable` on no code, a revert, a short answer or an out-of-range word). If the owner is
not `DEAD` it calls `transferFrom(owner, DEAD, 447)`, reverts `RetireRefused(returndata)` if that call
fails or if `ownerOf` is not `DEAD` afterwards, and emits `MedallionRetired(owner)`. Then
`retired = true`, `creatorPaid = 1.64 ETH`, the hook unlocks the manager, burns 1.64 ETH of claims,
takes the ETH to `CREATOR`, and emits `CreatorPaid` and `LastFare(447, LAST_FARE_HASH, LAST_FARE)`.
`creatorPaid` is always 0 or exactly the cap.

**burnIMD(viaPool4, callerMinOut).** Permissionless, `nonReentrant`, runs its own unlock. Exactly two
fixed pool keys: POOL4 `(ETH, IMD, 10000, 60, POOL4_HOOK)` and plain `(ETH, IMD, 10000, 200, no hook)`.
Checks, in order: `TooSoon` (fewer than 5 blocks since `lastBurnBlock`, which the constructor sets to
the deployment block); `Pool4Unavailable` (fallback mode with `viaPool4`, or POOL4 never read);
`batch = min(burnable, 0.05 ETH normal / 0.01 ETH fallback)`; `NothingToBurn` under 0.002 ETH; then
the reference is resolved (seed or anchor step), the pool is read (`PoolUnavailable` if it is not
initialized) and the guards run.

- *Normal mode*: POOL4's `marketOpen()` returns true and `refTick()` answers (low-level staticcall,
  length and range checked, no staleness rule). The reference is `refTick`, and it is also written to
  `anchor`, `blockAnchor` and `lastRef`.
- *Fallback mode*: only the plain pool. The reference is the anchor as it stood at the start of the
  block. The anchor then steps at most `ANCHOR_STEP = 200` ticks toward the plain pool's spot, clamped
  to `lastRef ± FALLBACK_BAND (1000)`, once per block however long it idled. `pokeAnchor()` does the
  same step without burning, and re-seeds from POOL4 while it answers. `lastRef` is written only by a
  seed from POOL4, never in fallback mode, so the band is fixed while POOL4 is silent. **Liveness
  limit:** a plain-pool move that stays more than `FALLBACK_BAND + MAX_REF_DEVIATION = 1150` ticks
  below `lastRef` (IMD about 12% dearer in ETH) pins the anchor at `lastRef - 1000` and every fallback
  burn reverts `PriceOffReference` until POOL4 supplies a new reference. After a terminal POOL4 close
  that can be permanent; the fees then stay as claims. A move the other way pins the anchor at
  `lastRef + 1000`, burns go through, and the 96% floor is measured at the band edge rather than at the
  market.
- *One-sided guard*: `PriceOffReference` only when `spot < reference - tolerance`; tolerance is
  `MAX_PLAIN_DEVIATION = 300` for the plain pool in normal mode, `MAX_REF_DEVIATION = 150` otherwise.
  A pool where $IMD is cheaper than the reference is never refused.
- `minOut = max(quote(reference) × 96%, callerMinOut)`, `quote = amount × 1.0001^tick` with no LP fee.
  `PartialFill` on a zero or partial fill, `InsufficientOutput` under the floor. All $IMD goes to
  `IMD_SINK = DEAD`. The caller receives nothing and cannot choose the batch.
- The constructor seeds the anchor if POOL4 is open and answers at deployment.

**status()** returns exactly one of:

- `IN SERVICE. Recouped X.XX of 1.64 ETH.` (two decimals, truncated)
- `RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447.`
- `RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: Y.Y.` (one decimal, truncated)

**LAST_FARE** is a public string constant of 1126 bytes; `LAST_FARE_HASH` is its keccak256,
`0x0d095dc39a486d88dd13cac371e1aefd8e9c5f9315fdbeba70a10371604762f2`, pinned by a test.

**Forbidden and absent.** No owner, admin, pause, upgrade, setter or sweep. No `SELFDESTRUCT`,
`DELEGATECALL` or `CALLCODE` in either runtime. No dynamic LP fee, no fee in FARE447, no fee on
transfer, no ETH to `CREATOR` except the one cap in `retire()`, no caller-chosen burn size, no tip.

## Constants

| Name | Value |
| --- | --- |
| `BUY_FEE_BPS`, `SELL_FEE_BPS` | 200 |
| `CREATOR_SHARE_BPS` | 10000 |
| `CREATOR_CAP` | 1.64 ether |
| `CREATOR` | `0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a` |
| `MEDALLION_NFT` | `0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03` |
| `MEDALLION_ID` | 447 |
| `DEAD`, `IMD_SINK` | `0x000000000000000000000000000000000000dEaD` |
| `IMD` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| `POOL4_HOOK` | `0xc6C965Bd164c483e87d0B550671798e9A3602840` |
| `MAX_BURN_BATCH` / `FALLBACK_BURN_BATCH` / `MIN_BURN` | 0.05 / 0.01 / 0.002 ether |
| `MIN_BLOCKS_BETWEEN_BURNS` | 5 |
| `MAX_REF_DEVIATION` / `MAX_PLAIN_DEVIATION` | 150 / 300 ticks |
| `MAX_SLIPPAGE_BPS` | 400 |
| `ANCHOR_STEP` / `FALLBACK_BAND` | 200 / 1000 ticks |

## Interface

Hook callbacks (PoolManager only): `afterInitialize`, `beforeSwap`, `afterSwap`, `unlockCallback`.
Permissionless: `retire()`, `burnIMD(bool viaPool4, uint256 callerMinOut)`, `pokeAnchor()`.
Views: `status()`, `totalFees()`, `creatorPaid()`, `burnSpent()`, `imdBurned()`, `retired()`,
`creatorEntitlement()`, `burnable()`, `reservedClaims()`, `launchPool()`, `launchPoolSet()`,
`lastBurnBlock()`, `anchorSeeded()`, `anchor()`, `blockAnchor()`, `lastRef()`, `anchorBlock()`,
`pool4Key()`, `plainKey()`, `quote(amount, tick)`, `pool4Reference()`, `getHookPermissions()`.
Events: `LaunchPoolSet`, `FeeCollected`, `Recouped`, `MedallionRetired`, `CreatorPaid`, `LastFare`,
`AnchorSeeded`, `AnchorStepped`, `IMDBurned`. ABIs: `docs/abi/MedallionHook.json`,
`docs/abi/FareToken.json`.

## Build and test (offline)

Foundry 1.8.x with solc 0.8.26 cached. All dependencies are vendored under `lib/` (v4-core 1.0.2 with
its solmate and OpenZeppelin sub-libraries, forge-std 1.16.2); nothing is fetched.

```
forge build --offline
forge test --offline
forge fmt --check
```

The suite has 92 unit and fuzz tests plus 4 invariants (see `test/`). Tests deploy their own
PoolManager, mine a CREATE2 salt for the 0x10CC flags, and `vm.etch` mocks at the mainnet addresses of
the medallion, $IMD and the POOL4 hook. No environment variables, no ffi, no filesystem access.

## Deployment parameters

- Hook constructor: `(IPoolManager poolManager)`, written as `"$poolManager"` in `launch.json`. The
  deployer mines a salt so the address carries `0x10CC` in its low 14 bits; the constructor reverts
  `HookAddressNotValid` otherwise.
- Token constructor: none. Mints 1e27 to the deployer (the launch factory).
- Pool: paired with native ETH, LP fee 3000, tick spacing 60. `initialPrice` is
  `250541448375047931186413801569606` (sqrtPriceX96), i.e. 10,000,000 FARE447 per ETH. **This is an
  assumption**: the brief sets no price. The deployer may change it; nothing in the hook depends on it.
- Target chain: Ethereum mainnet is where `retire()` and `burnIMD()` can succeed. Elsewhere only the
  fee works.
- **Deploy and initialize atomically.** `launchPool` is whichever native-ETH pool naming this hook
  is initialized first, with no setter. The factory must deploy the hook and initialize the
  ETH/FARE447 pool in the same transaction (it does; before deployment the hook has no code and no
  pool can be initialized against it). If the two were ever split, a stranger could initialize any
  ETH/anything pool in between and the real FARE447 pool would trade fee-free forever.

## Operational responsibilities

- **Nouns DAO, not CREATOR, holds Noun #447** (see Disclosure). Before `retire()` can succeed a
  Nouns DAO proposal must pass and execute `approve(hook, 447)` or `setApprovalForAll(hook, true)` on
  `0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03`, or transfer Noun #447 to `0x...dEaD`. Without it
  `retire()` reverts `RetireRefused` and nothing changes; the 1.64 ETH stays locked, possibly forever.
  After the approval anyone may send the transaction.
- **CREATOR** must be able to receive plain ETH from the PoolManager's `take`. If it cannot, `retire()`
  reverts until it can. Trading is unaffected either way because fees are claims.
- **Keepers.** `burnIMD` and `pokeAnchor` pay nothing. Someone has to call them: a bot, the requester,
  or anybody with a reason. Burns are capped at one every 5 blocks and 0.05 ETH (0.01 in fallback).
- **POOL4.** `marketOpen()` and `refTick()` on the POOL4 hook were confirmed on mainnet while this was
  written (open, tick 60396). The live POOL4 hook has an owner-only, terminal `closeMarket()`; if it is
  ever used, this hook is in fallback mode for life: burns continue on the plain pool at 0.01 ETH per
  batch with the anchored reference, which follows the plain pool at 200 ticks per block inside a
  fixed ±1000 band around the last POOL4 reference. The band never moves without POOL4, so if the
  plain pool settles more than 1150 ticks below that reference the burns stop for good and the fees
  stay as claims (see "Liveness limit" above). Burns also need POOL4 to have answered at least once
  (at deployment or later).
- **The plain pool is permissionless.** Anyone can create and solely supply `(ETH, IMD, 10000, 200,
  no hook)`. Inside the brief's fixed tolerances such an LP can sell $IMD to the hook at up to about
  3.9% below POOL4's reference per 0.05 ETH batch in normal mode (300 ticks of deviation plus the 96%
  floor), and up to roughly 15% on 0.01 ETH batches in fallback mode after walking the anchor. That is
  about 0.002 ETH per batch, below mainnet gas for the call; it is a bound, not an exploit, and the
  creator's reserve is never touched.
- Nobody can change anything after deployment.

## What the brief asked that the launch token does not do

Nothing. The 2% fee lives in the hook; the token is the standard fixed-supply ERC-20 the launch
requires, with `burn` / `burnFrom` as the brief asked.

## Further reading

- `docs/DESIGN.md`: delta accounting per swap shape, the ledger, the burn modes and the anchor.
- `docs/OPERATIONS.md`: runbook for the owner, keepers and reviewers.
- `REVIEW.md`: independent review of this tree, findings and what was re-run.
