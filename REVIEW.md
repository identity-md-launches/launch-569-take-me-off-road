# Review of FARE447 + MedallionHook

Scope: `src/FareToken.sol`, `src/MedallionHook.sol`, `test/`, `launch.json`, against SPEC 1-10 and the
FORBIDDEN list of the brief, the `uniswap-v4-security` checklist and the ethskills security checklist.
This review was done by the implementing seat after the build; it is not an independent audit, and a
separate adversarial review is still required before funds depend on this code.

## What was re-run

```
forge build --offline      Compiler run successful (solc 0.8.26, cancun, optimizer 200, via_ir off)
forge test  --offline      96 passed, 0 failed, 0 skipped + 4 invariants (32 runs x 24 depth)
forge fmt   --check        clean
```

Bytecode walk (PUSH data skipped) over both runtimes: no 0xF2, 0xF4, 0xFF. Hook runtime about 14.6
KB, under the EIP-170 limit. Token constructor mints exactly 1e27 to `msg.sender`.

The reviewer's proof for the fallback-band finding (`Proof_cbfaa27a5c9e.t.sol`, copied under
`test/scratch/`) failed on the starting tree with `PriceOffReference(-1229, -1000)` and passes on this
one.

`launch.json` fields checked against the shape the manifest check expects: `hook.contract` and
`token.contract` are contract names, `hook.permissions` is an array of the five flag names,
`pool.initialPrice` is a string, `constructorArgs` is `["$poolManager"]`, notes are under 4000
characters. This was the fault of the rejected attempt and is the first thing verified here.

## Findings

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | Info | `reference` is a reserved word in Solidity 0.8.26; the first draft used it as a parameter name and did not compile. | Renamed to `ref` / `refTick`. |
| 2 | Low | `burnIMD` hit "stack too deep" without via_ir. | Split into `_resolveReference`, `_batchFor`, `_executeBurn`, `_spotChecked`. Behaviour unchanged, each step tested. |
| 3 | Medium (design) | A hook that `take`s ETH to a recipient during a swap reverts on a manager with no ETH and halts trading when the recipient rejects ETH (the 2026-10-01 4% ETH-fee incident). | Fees are minted as ERC-6909 claims in every shape; `test_buyWorksOnAFreshManagerSeededWithTokensOnly` proves a buy on a manager holding zero ETH. `retire()` redeems the claims in its own unlock. |
| 4 | Medium (design) | In the beforeSwap shapes a price limit can leave the pool filling less than `amountSpecified + fee` while the swapper is charged the full fee. | `afterSwap` reverts `PartialFill` when the raw ETH delta differs; tested for both shapes. The afterSwap shapes charge 2% of the realised gross and tolerate limits (tested). |
| 5 | Medium (design) | The fallback reference could be moved within a block by calling `pokeAnchor()` right before `burnIMD()`. | The burn uses `blockAnchor`, the value from the start of the block; the step is once per block; tested (`test_fallbackBurnUsesTheStartOfBlockAnchor`, `test_anchorStepsAtMost200PerBlockTowardThePlainSpot`). |
| 6 | Low | `ownerOf` / `marketOpen` / `refTick` are read from addresses that may hold no code (Sepolia) or arbitrary code. | Low-level staticcalls with `length == 32` checks, a strict `== 1` on the bool, a `[MIN_TICK, MAX_TICK]` range on the tick, a `uint160` range on the address. Malformed answers tested with the `RawAnswer` mock. |
| 7 | Low | A medallion contract could re-enter `retire()` from `transferFrom`. | Transient lock on slot 1 held across `retire()`; `ReentrantMedallion` test shows the outer call reverts `RetireRefused(Reentrancy)` and nothing is paid. |
| 8 | Info | `SELL_FEE_BPS`, `BUY_FEE_BPS`, `CREATOR_SHARE_BPS` are equal or 100% and could be folded. | Kept as separate public constants because the brief names them. |
| 9 | Info | The POOL4 view names come from the brief. | Confirmed on mainnet during the build: `marketOpen()` returned `true`, `refTick()` returned `60396`, `lpFee()` 10000. If the live hook ever changes its ABI the hook degrades to fallback mode, which is the designed behaviour. |
| 10 | Info | `initialPrice` is not given by the brief. | Set to 1e7 FARE447 per ETH and flagged as an assumption in README, notes and OPERATIONS. |
| 11 | Low | After the cap but before retirement, fees above the cap are burnable. The brief's ledger defines `burnable` that way and the invariant keeps the cap fully backed. | Accepted; `test_burnsNeverTouchTheCreatorsReserve` shows 1.64 ETH of claims remain after burning everything burnable. |
| 12 | Info | The hook holds no ETH and no tokens at rest; donations of claims are possible and harmless. | `test_donatedClaimsDoNotCountAsFeesAndKeepTheInvariant`, invariant `hookNeverHoldsTokensOrEth`. |

### Revision round (independent review, 2026-10-01)

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 13 | High | `MEDALLION_NFT` is the mainnet Nouns token; Noun #447 sits in the Nouns DAO treasury timelock, so `retire()` needs a DAO vote and the 1.64 ETH may never be released. Reproduced with `cast call` against mainnet (name "Nouns", symbol "NOUN", `ownerOf(447)` = `0xb1a3…ef71`, `delay()` 172800, CREATOR balance 0, `getApproved(447)` zero). | The constant is the brief's and stays. Disclosure corrected everywhere it was wrong: NatSpec on `CREATOR`, `MEDALLION_NFT`, `MEDALLION_ID` and the contract header; README Disclosure, Deployment parameters and Operational responsibilities; OPERATIONS "When the cap is reached" and Trust assumptions; `launch.json` notes. All now say retirement depends on a passed Nouns DAO proposal and may never happen, and that the 1.64 ETH has no other exit. |
| 14 | Medium | Fallback anchor clamped to a `lastRef` band that was never refreshed after a terminal POOL4 close: a lasting plain-pool move of > 1150 ticks stranded every post-cap fee; the mirror move left the floor far below market. Reproduced with the reviewer's proof. | `FALLBACK_RECENTER_BLOCKS = 100`: in fallback, once 100 blocks have passed since `lastRef` was written, the next anchor step re-centres `lastRef` on the anchor (`BandRecentered`, `lastRefBlock`). The band now follows a lasting move at ≤ 1000 ticks per 100 blocks; a re-seed from POOL4 resets the clock. Tests: `test_bandRecentersAfterRecenterBlocksAndBurnsFollowALastingMoveDown`, `…MoveUpAndTheFloorFollows`, `test_bandDoesNotRecenterBeforeRecenterBlocks`, `test_recenterBoundsTheDriftOfTheReference`, `test_reseedFromPool4ResetsTheRecenterClock`; the proof passes. |
| 15 | Low | In fallback mode the plain pool was read (and the anchor stepped) before `batch` / `NothingToBurn`, so a keeper with nothing burnable saw `PoolUnavailable`. Reproduced on the fixture. | `burnIMD` now decides the mode first, computes the batch, and only then seeds or steps the anchor and reads the spot, matching the SPEC 7 order. `_resolveReference` became `_reference(open, pool4Ref)`. Tests: `test_fallbackNothingToBurnComesBeforeThePlainPoolRead`, `test_pool4UnavailableComesBeforeNothingToBurn`. |
| 16 | Info | `launchPool` is the first native-ETH pool; the economics rely on the factory deploying and initializing atomically. | By SPEC 2, no code change. The dependency is now stated in README Deployment parameters as well as OPERATIONS step 2. |
| 17 | Info | A sole LP of the permissionless plain pool can sell IMD to the hook up to ~3.9% below POOL4's reference per 0.05 ETH batch inside the brief's tolerances. | Inside SPEC 3's constants, no code change. Documented as a bound in README Operational responsibilities and OPERATIONS Trust assumptions. |
| 18 | Low (test) | `MedallionInvariantTest` targeted the whole handler, so the fuzzer could call the handler's public `setUp()` mid-sequence, redeploy the hook, and fail `invariant_creatorPaidIsZeroOrCap` against a stale hook (seen once with seed `0xb32b…5e0`). Found while re-running the suite. | `targetSelector` now lists the five actions. |

No open findings. Items 3, 4, 5 are design decisions that the tests pin; item 13 is a disclosed
dependency on Nouns DAO governance that the requester must pursue.

## Checklist (uniswap-v4-security / ethskills)

- Every callback and `unlockCallback` checks `msg.sender == poolManager`: yes, tested.
- `beforeSwapReturnDelta` justified: fee carve-out in the specified currency; the hook can never return
  more than the fee (2% of the specified amount), so the NoOp pattern is impossible; `PartialFill`
  guards the remainder.
- Delta accounting sums to zero on every path: fee credited to the hook equals the claim minted in the
  same swap; the burn and payout unlocks burn exactly what they take.
- Reentrancy: transient lock on `retire`, `burnIMD`, `pokeAnchor`; callbacks make no external call
  except `poolManager.mint`.
- No unbounded loops, no `tx.origin`, no `transfer()` for ETH (the manager's `take` is used), no
  hardcoded gas, no stored secrets, no proxy.
- Oracle: the POOL4 reference is only a guard with a one-sided tolerance and a 96% output floor on a
  bounded batch; a manipulated reference cannot extract more than one batch of slippage every 5
  blocks.
- Token: standard decimals, no fee-on-transfer, exact-supply mint, no admin selectors (tested with the
  floor's selector list).
- Events on every state change: yes.
- Slither / Mythril were not run; they are not on this box.

## Open items for the launch

- Independent adversarial review before mainnet.
- Retirement needs a passed Nouns DAO proposal (approve the hook for Noun #447, or move it to DEAD).
  Nobody involved in this launch can do that alone; without it the 1.64 ETH stays locked.
- Keepers for `burnIMD` / `pokeAnchor`; nobody is paid to call them. In fallback mode they also keep
  the anchor following the plain pool.
