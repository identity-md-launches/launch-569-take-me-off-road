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
- **Medallion #447 is Noun #447, owned by the Nouns DAO treasury timelock**
  (`0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71`, checked 2026-10-01), not by `CREATOR`. Only a passed
  Nouns DAO proposal can let `retire()` through, by executing on the Nouns token
  (`0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03`) either `approve(hook, 447)` /
  `setApprovalForAll(hook, true)` or `transferFrom(timelock, 0x...dEaD, 447)`. The requester has to
  take that to Nouns governance; nobody involved in this launch can do it unilaterally.
- Anyone calls `retire()` once that has executed. One transaction: medallion to `0x...dEaD` (skipped
  if the DAO already sent it there), 1.64 ETH to `CREATOR`, `MedallionRetired`, `CreatorPaid` and
  `LastFare` emitted.
- If `retire()` reverts `RetireRefused(...)`, the approval is missing or the owner changed. Nothing
  moved; the 1.64 ETH of claims stays in the hook, which has no sweep, until a proposal passes, and
  possibly forever. If it reverts `MedallionUnavailable`, the chain has no medallion contract
  (Sepolia) or it answered badly.
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
- With nothing burnable the call reverts `NothingToBurn` before any pool is read, in both modes.
  `PoolUnavailable` means there was something to burn but the chosen pool is not initialized on this
  manager.
- If POOL4 stops answering (`pool4Reference()` returns `open = false`): only `burnIMD(false, …)`
  works, with the anchored reference. Call `pokeAnchor()` once per block to let the anchor follow the
  plain pool (≤ 200 ticks per block, within ±1000 of `lastRef`). `lastRef` is the last reference POOL4
  gave and does not move without POOL4. If the plain pool settles more than 1150 ticks below it,
  `burnIMD(false, …)` reverts `PriceOffReference(spot, lastRef - 1000)` and keeps doing so until POOL4
  answers again; poking does not help. The live POOL4 hook's `closeMarket()` is terminal, so this
  fallback may be permanent and the burns may stop for good, with the fees left as claims. If POOL4
  never answered since deployment, burns are impossible until it does.
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
- POOL4's owner (`0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7`) can close the market for good. That
  moves this hook into fallback mode permanently; burns continue on the plain pool at 0.01 ETH per
  batch with the anchored reference inside a fixed ±1000 band around the last POOL4 reference. In
  fallback the plain pool's LPs are the only price source, but they can move the reference by at most
  200 ticks per block and never beyond the band; each burn is 0.01 ETH per 5 blocks. The flip side is
  that a lasting move of the plain pool more than 1150 ticks below the last POOL4 reference stops the
  burns for as long as POOL4 stays closed, possibly forever.
- The plain ETH/IMD pool is permissionless. A sole LP can price it up to 300 ticks (normal mode) or
  150 ticks plus the anchor's drift (fallback) below the reference and still be used; combined with
  the 96% floor that is at most ~3.9% below POOL4's reference per 0.05 ETH batch in normal mode.
- The medallion contract is the Nouns token, treated as an ERC-721. The hook reads its answers
  defensively and only acts on a clean `ownerOf` word. Retirement depends on Nouns DAO governance.
- `CREATOR` is a fixed EOA chosen by the requester. If it is ever a contract that rejects ETH,
  `retire()` cannot complete; trading is unaffected.
