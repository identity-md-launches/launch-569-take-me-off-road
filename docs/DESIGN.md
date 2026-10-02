# MedallionHook design notes

## Delta accounting per swap shape

The launch pool is `(ETH = currency0, FARE447 = currency1)`. `zeroForOne` is a buy, `oneForZero` a
sell. ETH is the *specified* currency when `zeroForOne == (amountSpecified < 0)`.

| Shape | beforeSwap returns | pool swaps | afterSwap returns | swapper's delta |
| --- | --- | --- | --- | --- |
| Exact-in buy, `-A` ETH | specified `+f`, `f = 2% A` | `-(A - f)` ETH in | 0 (checks raw ETH delta `== -A + f`) | `-A` ETH, tokens out |
| Exact-out sell, `+A` ETH | specified `+f`, `f = 2% A` | `+(A + f)` ETH out | 0 (checks raw ETH delta `== A + f`) | `+A` ETH, tokens in |
| Exact-out buy, `+T` tokens | 0 | pool charges `G` ETH | unspecified `+f`, `f = 2% G` | `-(G + f)` ETH, `+T` tokens |
| Exact-in sell, `-T` tokens | 0 | pool pays `G` ETH | unspecified `+f`, `f = 2% G` | `+(G - f)` ETH, `-T` tokens |

In every shape the PoolManager credits the hook `+f` of ETH after `afterSwap` returns. Inside
`afterSwap` the hook calls `poolManager.mint(hook, 0, f)`, which debits it `f`. The hook's net delta
is zero and it now holds `f` of ERC-6909 claims on currency 0. Nothing is transferred during the swap,
so the manager needs no ETH balance and the recipient's ability to receive ETH is irrelevant.

A swap of fewer than 50 wei of ETH rounds to a zero fee and is passed through without a mint.

## Why PartialFill only in the beforeSwap shapes

When the fee is carved from the specified amount before the swap, the pool is asked for
`amountSpecified + f`. If a price limit stops it short, the swapper would still be charged the full
fee on an amount the pool never traded. The check `raw ETH delta == amountSpecified + fee` rejects
that. In the afterSwap shapes the fee is computed from what the pool actually did, so a short fill
simply pays 2% of the smaller amount.

## Ledger

```
totalFees          += fee on every launch-pool swap (and nothing else)
creatorEntitlement  = min(CREATOR_CAP, totalFees)
burnable            = totalFees - creatorEntitlement - burnSpent
claims(hook, 0)    >= totalFees - creatorPaid - burnSpent      (invariant)
creatorPaid         ∈ {0, CREATOR_CAP}
```

Claims transferred to the hook by third parties raise the left side of the invariant without touching
`totalFees`; they stay with the hook and are never counted as fees or as burnable. The hook has no
`receive`, so plain ETH cannot be pushed to it.

`Recouped(totalFees, block.number)` fires on the swap whose fee takes `totalFees` from below the cap to
at or above it, exactly once.

## retire()

```
NotRecouped       if totalFees < CAP
AlreadyRetired    if retired
owner = ownerOf(447)         staticcall; MedallionUnavailable on anything but a clean address word
if owner != DEAD:
    transferFrom(owner, DEAD, 447)   low-level call; RetireRefused(returndata) if it fails
    ownerOf(447) == DEAD             else RetireRefused(returndata)
    emit MedallionRetired(owner)
retired = true; creatorPaid = CAP
unlock -> burn(hook, 0, CAP); take(ETH, CREATOR, CAP)
emit CreatorPaid(CREATOR, CAP); emit LastFare(447, LAST_FARE_HASH, LAST_FARE)
```

The transient lock on slot 1 is held across the whole function, so a medallion contract that calls
back into `retire()` from `transferFrom` makes the outer call revert `RetireRefused(Reentrancy)`.

## burnIMD()

```
TooSoon            if block.number < lastBurnBlock + 5
open, ref = POOL4.marketOpen(), POOL4.refTick()      (staticcalls, length == 32, flag == 1, tick in range)
Pool4Unavailable   if !open and (viaPool4 or !anchorSeeded)
batch = min(burnable, open ? 0.05 : 0.01 ETH); NothingToBurn if batch < 0.002 ETH
normal   (open):   seed anchor = blockAnchor = lastRef = ref; reference = ref
fallback (!open):  stepAnchor(); reference = blockAnchor
key   = viaPool4 ? POOL4 : plain
spot  = slot0(key).tick;  PoolUnavailable if the pool is not initialized
tol   = (!viaPool4 && open) ? 300 : 150
PriceOffReference if spot < reference - tol
minOut = max(quote(batch, reference) * 96%, callerMinOut)
burnSpent += batch; lastBurnBlock = block.number
unlock -> swap(key, zeroForOne, -batch, MIN_SQRT_PRICE + 1)
          PartialFill if amount0 != -batch or amount1 <= 0
          InsufficientOutput if out < minOut
          burn(hook, 0, batch); take(IMD, DEAD, out)
imdBurned += out; emit IMDBurned
```

### The anchor

`anchor` is the fallback reference. `blockAnchor` is the value `anchor` had when the block in which it
last moved began. `anchorBlock` is that block. `lastRef` is the centre of the band: the last reference
POOL4 supplied. It is written only by `seedAnchor()`; fallback mode never touches it.

`stepAnchor()` runs at most once per block:

```
if anchorBlock == block.number: return
plainSpot   = slot0(plain).tick                      (PoolUnavailable if not initialized)
target      = clamp(plainSpot, lastRef - 1000, lastRef + 1000)
blockAnchor = anchor
anchor     += clamp(target - anchor, -200, +200)
anchorBlock = block.number
```

Because the burn reads `blockAnchor` after stepping, a `pokeAnchor()` in the same block cannot move
the reference a burn uses; the reference can only change between blocks, by at most 200 ticks per
block, and never leaves `lastRef ± 1000`. An attacker who pushes the plain pool down must wait for the
anchor to walk down 200 ticks per block before a burn at the depressed price passes the guard, and
each such burn is at most 0.01 ETH every 5 blocks.

### Why the band is fixed, and what that costs

SPEC 7 fixes the band at `lastRef ± FALLBACK_BAND` with `lastRef` the last POOL4 reference. A previous
revision re-centred `lastRef` on the anchor every 100 blocks so that burns could follow a lasting
plain-pool move after a terminal POOL4 close; an independent review showed that this let
permissionless `pokeAnchor()` calls walk both the guard reference and the 96% floor out of the
specified band with no new POOL4 observation, so it was removed. `lastRef` is now written only by a
seed from POOL4 (constructor, normal-mode burn, `pokeAnchor()` while POOL4 answers).

The price of the fixed band is liveness. The live POOL4 hook has an owner-only, terminal
`closeMarket()`. After such a close the hook is in fallback mode for life, and a plain-pool move that
stays more than 1150 ticks below `lastRef` (IMD ~12% dearer in ETH) pins the anchor at
`lastRef - 1000` and makes every burn revert `PriceOffReference` until POOL4 answers again, which
after a terminal close is never. The post-cap fees then remain as claims on the PoolManager; nothing
can release them. A move the other way pins the anchor at `lastRef + 1000`; burns go through and the
96% floor is measured at the band edge, so the floor is looser than the market but still bounded by
the last POOL4 price. Both limits are tested (`test_fallbackBandIsFixedUntilPool4AnswersAgain`,
`test_fallbackBandIsFixedOnALastingMoveUp`) and disclosed in the README, OPERATIONS and the launch
notes. Changing this needs a change to the specification, not to the code.

### Why the guard is one-sided

The hook buys $IMD with ETH. A spot tick *below* the reference means fewer $IMD per ETH than the
reference says, so the hook would overpay: refused. A spot tick *above* the reference means more $IMD
per ETH: accepted, and the 96% floor at the reference quote is then easily met.

## status() formatting

`_formatEther(value, places)` truncates: `whole = value / 1e18`, `frac = (value % 1e18) / 10^(18 -
places)`, zero-padded to `places` digits.

## Compiler and bytecode

solc 0.8.26, evm `cancun`, optimizer 200 runs, `via_ir = false`, `bytecode_hash = "none"`,
`cbor_metadata = false`. The hook runtime is about 14.6 KB. Neither runtime contains `SELFDESTRUCT`
(0xff), `DELEGATECALL` (0xf4) or `CALLCODE` (0xf2) outside PUSH data; a test walks the bytecode the
way the admission floor does.
