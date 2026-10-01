# Operations runbook

## Before launch

1. The deployer resolves `$poolManager` to the chain's PoolManager and mines a CREATE2 salt whose
   address carries `0x10CC` in its low 14 bits. The constructor rejects any other address.
2. The factory deploys `FareToken` (mints 1e27 to itself), deploys `MedallionHook`, and initializes
   the ETH/FARE447 pool (fee 3000, spacing 60) in the same transaction. The first native-ETH pool
   becomes `launchPool`; `afterInitialize` cannot revert for the manager.
3. `initialPrice` in `launch.json` is an assumption (10,000,000 FARE447 per ETH). Change it if the
   launch policy prefers another number; the hook does not depend on it.

## While in service

- `status()` says `IN SERVICE. Recouped X.XX of 1.64 ETH.` Watch `totalFees()`.
- Nothing needs doing. Fees accumulate as ERC-6909 claims on the PoolManager, id 0, owned by the hook.
- Trading cannot be paused, and no one can withdraw the claims.

## When the cap is reached

- `status()` says `RECOUPED, NOT RETIRED. ...`. `Recouped` was emitted once.
- **The owner of medallion #447** approves the hook on the medallion contract
  (`0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03`): `approve(hook, 447)` or
  `setApprovalForAll(hook, true)`.
- Anyone calls `retire()`. One transaction: medallion to `0x...dEaD`, 1.64 ETH to `CREATOR`,
  `MedallionRetired`, `CreatorPaid` and `LastFare` emitted.
- If `retire()` reverts `RetireRefused(...)`, the approval is missing or the owner changed. Nothing
  moved; fix the approval and retry. If it reverts `MedallionUnavailable`, the chain has no medallion
  contract (Sepolia) or it answered badly.
- Fees above the cap are already burnable before retirement; retirement is not a precondition for
  burns.

## Burning $IMD

- Anyone calls `burnIMD(true, 0)` to buy on POOL4 or `burnIMD(false, 0)` on the plain pool. Pass a
  higher `callerMinOut` to tighten the floor; it cannot be loosened below 96% of the reference quote.
- One burn per 5 blocks, at most 0.05 ETH (0.01 ETH in fallback). Under 0.002 ETH burnable the call
  reverts `NothingToBurn`.
- `PriceOffReference(spot, ref)` means the chosen pool prices $IMD more than 1.5% (3% for plain in
  normal mode) above the reference. Try the other pool or wait.
- `InsufficientOutput(out, minOut)` means the pool is too thin for the batch at the moment.
- If POOL4 stops answering (`pool4Reference()` returns `open = false`): only `burnIMD(false, …)`
  works, with the anchored reference. Call `pokeAnchor()` once per block to let the anchor follow the
  plain pool (≤ 200 ticks per block, within ±1000 of the last POOL4 reference). If POOL4 never
  answered since deployment, burns are impossible until it does.
- The caller is not paid. Gas is a donation.

## Sepolia and other chains

`retire()` reverts `MedallionUnavailable`; `burnIMD()` and `pokeAnchor()` revert `Pool4Unavailable`.
Fees still accrue and `status()` still works. Nothing on those chains can release the claims.

## Monitoring

- `FeeCollected(buy, fee, totalFees)` on every fee-bearing swap.
- `Recouped(totalFees, block)` once.
- `MedallionRetired(from)`, `CreatorPaid(creator, 1.64e18)`, `LastFare(447, hash, text)` on retirement.
- `IMDBurned(viaPool4, fallbackMode, ethIn, imdOut, refTick, spot)` per burn;
  `AnchorSeeded` / `AnchorStepped` as the reference moves.
- Invariant to alert on: `PoolManager.balanceOf(hook, 0) >= totalFees - creatorPaid - burnSpent`.

## Trust assumptions

- POOL4's `marketOpen()` and `refTick()` are the reference oracle in normal mode. Both were confirmed
  on mainnet (open, tick 60396) while this was built. The hook trusts them only inside a one-sided
  tolerance and a 96% output floor; it never trusts them for more than one 0.05 ETH batch per 5 blocks.
- The medallion contract is treated as an ERC-721. The hook reads its answers defensively and only
  acts on a clean `ownerOf` word.
- `CREATOR` is a fixed EOA chosen by the requester. If it is ever a contract that rejects ETH,
  `retire()` cannot complete; trading is unaffected.
