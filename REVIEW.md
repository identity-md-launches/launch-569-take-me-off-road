# Review of FARE447 + MedallionHook

Scope: `src/FareToken.sol`, `src/MedallionHook.sol`, `test/`, `launch.json`, against SPEC 1-10 and the
FORBIDDEN list of the brief, the `uniswap-v4-security` checklist and the ethskills security checklist.
This review was done by the implementing seat after the build; it is not an independent audit, and a
separate adversarial review is still required before funds depend on this code.

## What was re-run

```
forge build --offline      Compiler run successful (solc 0.8.26, cancun, optimizer 200, via_ir off)
forge test  --offline      89 passed, 0 failed, 0 skipped + 4 invariants (32 runs x 24 depth)
forge fmt   --check        clean
```

Bytecode walk (PUSH data skipped) over both runtimes: no 0xF2, 0xF4, 0xFF. Hook runtime 14,409
bytes, under the EIP-170 limit. Token constructor mints exactly 1e27 to `msg.sender`.

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

No open findings. Items 3, 4, 5 are design decisions that the tests pin.

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
- The medallion owner's approval of the hook is a manual step after the cap.
- Keepers for `burnIMD` / `pokeAnchor`; nobody is paid to call them.
