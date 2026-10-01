// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {MedallionTestBase} from "./utils/MedallionTestBase.sol";
import {MockMedallion, RawAnswer} from "./mocks/MockMedallion.sol";

/// @notice burnIMD() and pokeAnchor(): batches, the two pools, normal and fallback mode, the
/// one-sided guard, the slippage floor, the anchor band and the start-of-block anchor.
contract MedallionBurnTest is MedallionTestBase {
    event IMDBurned(
        bool indexed viaPool4, bool indexed fallbackMode, uint256 ethIn, uint256 imdOut, int24 refTick, int24 spot
    );
    event AnchorSeeded(int24 tick, uint256 blockNumber);
    event AnchorStepped(int24 from, int24 to, int24 target, uint256 blockNumber);
    event BandRecentered(int24 from, int24 to, uint256 blockNumber);

    uint256 internal constant IMD_LIQUIDITY = 500 ether;

    /// @dev Cap reached plus 0.2 ETH burnable, both IMD pools live at tick 0 with POOL4 open at ref 0,
    /// and enough blocks passed for a burn.
    function readyToBurn() internal {
        reachCap();
        buyExactIn(10 ether); // burnable 0.2 ETH
        setUpIMD(0, IMD_LIQUIDITY);
        vm.roll(block.number + 5);
    }

    // ------------------------------------------------------------------------------------------
    // Order of checks
    // ------------------------------------------------------------------------------------------

    function test_tooSoonComesFirst() public {
        // Deployment block counts as the last burn: nothing is checked before the spacing.
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
        vm.roll(block.number + 4);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(false, 0);
    }

    function test_sepoliaLikeChainHasNoPool4AndNoFallback() public {
        reachCap();
        buyExactIn(10 ether);
        vm.roll(block.number + 5);
        assertEq(hook.POOL4_HOOK().code.length, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(false, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.pokeAnchor();
    }

    /// @dev SPEC 7 order: NothingToBurn is decided before the plain pool is read or the anchor stepped.
    function test_fallbackNothingToBurnComesBeforeThePlainPoolRead() public {
        etchIMD();
        etchPool4(true, 0);
        hook.pokeAnchor(); // seeded while POOL4 answers
        pool4Mock.setMarketOpen(false);
        // The plain pool is never initialized on this manager and nothing is burnable.
        vm.roll(block.number + 10);
        assertEq(hook.burnable(), 0);
        int24 anchorBefore = hook.anchor();
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.anchor(), anchorBefore, "nothing stepped");

        // With something burnable the missing plain pool is the next thing reported.
        reachCap();
        buyExactIn(10 ether);
        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        hook.burnIMD(false, 0);
    }

    /// @dev Pool4Unavailable is decided before the batch, as the spec orders.
    function test_pool4UnavailableComesBeforeNothingToBurn() public {
        etchIMD();
        etchPool4(false, 0);
        vm.roll(block.number + 10);
        assertEq(hook.burnable(), 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(false, 0);
    }

    function test_nothingToBurnBeforeTheCapAndBelowMinBurn() public {
        setUpIMD(0, IMD_LIQUIDITY);
        buyExactIn(10 ether); // 0.2 ETH of fees, all of it the creator's
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(true, 0);

        buyExactIn(72 ether); // 1.64 exactly
        buyExactIn(0.05 ether); // burnable 0.001 < MIN_BURN
        assertEq(hook.burnable(), 0.001 ether);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(true, 0);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Normal mode
    // ------------------------------------------------------------------------------------------

    function test_normalBurnViaPool4() public {
        readyToBurn();
        uint256 claimsBefore = hookClaims();
        uint256 deadBefore = imdBalance(hook.DEAD());
        uint256 quoteAtRef = hook.quote(0.05 ether, 0);

        vm.expectEmit(false, false, false, true, address(hook));
        emit AnchorSeeded(0, block.number);
        uint256 out = hook.burnIMD(true, 0);

        assertGt(out, 0);
        assertGe(out, quoteAtRef * 96 / 100, "at least 96% of the quote at the reference");
        assertLt(out, quoteAtRef, "the pool's 1% fee and impact are paid by the burn");
        assertEq(imdBalance(hook.DEAD()) - deadBefore, out, "every token goes to the sink");
        assertEq(imdBalance(address(hook)), 0);
        assertEq(
            imdBalance(address(this)) + imdBalance(hook.DEAD()) + imdBalance(address(manager)), 1_000_000_000 ether
        );
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(hook.imdBurned(), out);
        assertEq(hook.burnable(), 0.15 ether);
        assertEq(hookClaims(), claimsBefore - 0.05 ether);
        assertEq(hook.lastBurnBlock(), block.number);
        assertTrue(hook.anchorSeeded());
        assertEq(hook.anchor(), 0);
        assertEq(hook.blockAnchor(), 0);
        assertEq(hook.lastRef(), 0);
        assertEq(hook.anchorBlock(), block.number);
    }

    function test_normalBurnViaPlainPool() public {
        readyToBurn();
        uint256 deadBefore = imdBalance(hook.DEAD());
        vm.expectEmit(true, true, false, false, address(hook));
        emit IMDBurned(false, false, 0.05 ether, 0, 0, 0);
        uint256 out = hook.burnIMD(false, 0);
        assertEq(imdBalance(hook.DEAD()) - deadBefore, out);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertGe(out, hook.quote(0.05 ether, 0) * 96 / 100);
    }

    function test_normalBurnSpendsTheWholeRemainderWhenBelowTheBatch() public {
        reachCap();
        buyExactIn(1.5 ether); // burnable 0.03 ETH
        setUpIMD(0, IMD_LIQUIDITY);
        vm.roll(block.number + 5);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.03 ether);
        assertEq(hook.burnable(), 0);
    }

    function test_burnsAreSpacedByFiveBlocks() public {
        readyToBurn();
        hook.burnIMD(true, 0);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
        vm.roll(block.number + 4);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
        vm.roll(block.number + 1);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.1 ether);
    }

    function test_callerCannotChooseTheBatchOnlyRaiseTheFloor() public {
        readyToBurn();
        uint256 quoteAtRef = hook.quote(0.05 ether, 0);
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(MedallionHook.burnIMD, (true, quoteAtRef + 1)));
        assertFalse(ok, "a floor above what the pool can give is refused");
        assertEq(bytes4(ret), MedallionHook.InsufficientOutput.selector);
        assertEq(hook.burnSpent(), 0);
        // A floor the pool can meet is honoured, and the batch is still the contract's 0.05 ETH.
        uint256 out = hook.burnIMD(true, quoteAtRef * 97 / 100);
        assertGe(out, quoteAtRef * 97 / 100);
        assertEq(hook.burnSpent(), 0.05 ether);
    }

    function test_callerGetsNothing() public {
        readyToBurn();
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        hook.burnIMD(true, 0);
        assertEq(keeper.balance, 0);
        assertEq(imdBalance(keeper), 0);
        assertEq(manager.balanceOf(keeper, 0), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Guards
    // ------------------------------------------------------------------------------------------

    function test_priceOffReferenceViaPool4IsOneSided() public {
        readyToBurn();
        // Spot is 0. A reference 151 ticks above it says IMD is 1.5% too expensive here.
        pool4Mock.setRefTick(151);
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.PriceOffReference.selector, int24(0), int24(151)));
        hook.burnIMD(true, 0);
        // Exactly at the tolerance is accepted.
        pool4Mock.setRefTick(150);
        hook.burnIMD(true, 0);
        // A reference far below spot (IMD cheaper here than POOL4 says) is never refused.
        vm.roll(block.number + 5);
        pool4Mock.setRefTick(-5000);
        hook.burnIMD(true, 0);
    }

    function test_priceOffReferenceOnThePlainPoolUses300InNormalMode() public {
        readyToBurn();
        pool4Mock.setRefTick(301);
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.PriceOffReference.selector, int24(0), int24(301)));
        hook.burnIMD(false, 0);
        pool4Mock.setRefTick(300);
        hook.burnIMD(false, 0);
    }

    function test_slippageFloorRefusesAThinPool() public {
        reachCap();
        buyExactIn(10 ether);
        setUpIMD(0, 1 ether); // 0.05 ETH into 1 ETH of liquidity: ~5% impact on top of the 1% fee
        vm.roll(block.number + 5);
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(MedallionHook.burnIMD, (true, 0)));
        assertFalse(ok, "the burn must be refused");
        assertEq(bytes4(ret), MedallionHook.InsufficientOutput.selector);
        assertEq(hook.burnSpent(), 0, "a refused burn spends nothing");
    }

    function test_partialFillRevertsWhenLiquidityRunsOut() public {
        reachCap();
        buyExactIn(10 ether);
        etchIMD();
        etchPool4(true, 0);
        plainKey = hook.plainKey();
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        // Liquidity only just below spot: the pool runs dry before 0.05 ETH is absorbed.
        addLiquidity(plainKey, -200, 0, 1 ether, 0);
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0);
    }

    function test_uninitializedPlainPoolIsRefused() public {
        reachCap();
        buyExactIn(10 ether);
        etchIMD();
        etchPool4(true, 0);
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        hook.burnIMD(false, 0);
    }

    // ------------------------------------------------------------------------------------------
    // POOL4 reads
    // ------------------------------------------------------------------------------------------

    function test_pool4ReferenceRejectsMalformedAnswers() public {
        RawAnswer raw = new RawAnswer();
        vm.etch(hook.POOL4_HOOK(), address(raw).code);
        RawAnswer at = RawAnswer(payable(hook.POOL4_HOOK()));
        bytes4 marketOpen = bytes4(keccak256("marketOpen()"));
        bytes4 refTick = bytes4(keccak256("refTick()"));

        (bool open,) = hook.pool4Reference();
        assertFalse(open, "empty answers");

        at.setAnswer(marketOpen, abi.encode(uint256(2)));
        at.setAnswer(refTick, abi.encode(int256(100)));
        (open,) = hook.pool4Reference();
        assertFalse(open, "a flag that is not exactly 1");

        at.setAnswer(marketOpen, hex"01");
        (open,) = hook.pool4Reference();
        assertFalse(open, "a short bool");

        at.setAnswer(marketOpen, abi.encode(true));
        at.setAnswer(refTick, abi.encode(int256(887273)));
        (open,) = hook.pool4Reference();
        assertFalse(open, "a tick above MAX_TICK");

        at.setAnswer(refTick, abi.encode(int256(-887273)));
        (open,) = hook.pool4Reference();
        assertFalse(open, "a tick below MIN_TICK");

        at.setAnswer(refTick, abi.encode(int256(100), uint256(1)));
        (open,) = hook.pool4Reference();
        assertFalse(open, "a long answer");

        at.setRevert(refTick);
        (open,) = hook.pool4Reference();
        assertFalse(open, "a reverting view");

        at.setAnswer(refTick, abi.encode(int256(-60396)));
        int24 ref;
        (open, ref) = hook.pool4Reference();
        assertTrue(open);
        assertEq(ref, -60396);
    }

    function test_constructorSeedsTheAnchorWhenPool4Answers() public {
        etchPool4(true, 60396);
        MedallionHook fresh = deployHook(manager);
        assertTrue(fresh.anchorSeeded());
        assertEq(fresh.anchor(), 60396);
        assertEq(fresh.blockAnchor(), 60396);
        assertEq(fresh.lastRef(), 60396);
        assertEq(fresh.lastRefBlock(), block.number);
        assertEq(fresh.anchorBlock(), block.number);

        pool4Mock.setMarketOpen(false);
        MedallionHook closed = deployHook(manager);
        assertFalse(closed.anchorSeeded());
    }

    // ------------------------------------------------------------------------------------------
    // Fallback mode
    // ------------------------------------------------------------------------------------------

    function test_fallbackRefusesPool4AndNeedsASeed() public {
        reachCap();
        buyExactIn(10 ether);
        setUpIMD(0, IMD_LIQUIDITY);
        pool4Mock.setMarketOpen(false);
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(false, 0); // never read
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.pokeAnchor();

        pool4Mock.setMarketOpen(true);
        hook.pokeAnchor(); // seeds
        pool4Mock.setMarketOpen(false);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0); // POOL4 itself is unavailable
        hook.burnIMD(false, 0); // the plain pool works
        assertEq(hook.burnSpent(), 0.01 ether, "fallback batch is 0.01 ETH");
    }

    function test_fallbackBatchIsCappedAtOneHundredth() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        vm.recordLogs();
        uint256 out = hook.burnIMD(false, 0);
        BurnLog memory log_ = lastBurnLog();
        assertFalse(log_.viaPool4);
        assertTrue(log_.fallbackMode);
        assertEq(log_.ethIn, 0.01 ether);
        assertEq(log_.imdOut, out);
        assertEq(log_.refTick, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_anchorStepsAtMost200PerBlockTowardThePlainSpot() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        // Push the plain pool's tick up by selling IMD into it.
        pushPlainSpot(true, 15 ether);
        int24 spot = currentTick(plainKey);
        assertGt(spot, 400, "spot moved up a lot");
        assertLt(spot, 1000, "but stays inside the band");

        vm.roll(block.number + 1);
        vm.expectEmit(false, false, false, true, address(hook));
        emit AnchorStepped(0, 200, spot, block.number);
        hook.pokeAnchor();
        assertEq(hook.anchor(), 200);
        assertEq(hook.blockAnchor(), 0);

        // Same block: no second step, whatever is called.
        hook.pokeAnchor();
        assertEq(hook.anchor(), 200);

        // A long idle time is still one step.
        vm.roll(block.number + 100);
        hook.pokeAnchor();
        assertEq(hook.anchor(), 400);
        assertEq(hook.blockAnchor(), 200);
    }

    function test_anchorIsClampedToLastRefPlusMinusTheBand() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(true, 120 ether);
        int24 spot = currentTick(plainKey);
        assertGt(spot, 1200, "spot is outside the band");

        for (uint256 i = 0; i < 8; i++) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
        }
        assertEq(hook.anchor(), 1000, "never beyond lastRef + FALLBACK_BAND");
        assertEq(hook.blockAnchor(), 1000);

        // Back down past the other edge of the band.
        pushPlainSpot(false, 260 ether);
        spot = currentTick(plainKey);
        assertLt(spot, -1200);
        for (uint256 i = 0; i < 12; i++) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
        }
        assertEq(hook.anchor(), -1000, "never below lastRef - FALLBACK_BAND");
    }

    // ------------------------------------------------------------------------------------------
    // Fallback band re-centring
    // ------------------------------------------------------------------------------------------

    /// @dev A lasting plain-pool move of more than FALLBACK_BAND + MAX_REF_DEVIATION below lastRef
    /// must not strand the burns for good: after FALLBACK_RECENTER_BLOCKS the band re-centres on the
    /// anchor and the anchor keeps following the pool.
    function test_bandRecentersAfterRecenterBlocksAndBurnsFollowALastingMoveDown() public {
        readyToBurn();
        hook.pokeAnchor(); // lastRef = anchor = 0
        uint256 seedBlock = block.number;
        pool4Mock.setMarketOpen(false); // terminal on the live hook
        pushPlainSpot(false, 32 ether); // IMD ~12% dearer and it stays there
        int24 spot = currentTick(plainKey);
        assertLt(spot, -1150);
        assertGt(spot, -2000);

        // Up to the re-centre block the anchor is pinned at lastRef - 1000 and burns are refused.
        for (uint256 i = 1; i < 100; i++) {
            vm.roll(seedBlock + i);
            hook.pokeAnchor();
        }
        assertEq(hook.anchor(), -1000, "pinned at the band edge");
        assertEq(hook.lastRef(), 0, "no re-centre yet");
        assertEq(hook.lastRefBlock(), seedBlock);
        vm.roll(seedBlock + 99 + 1);
        // This block re-centres and steps: the burn in it still uses the start-of-block anchor (-1000).
        vm.expectEmit(false, false, false, true, address(hook));
        emit BandRecentered(0, -1000, block.number);
        vm.expectEmit(false, false, false, true, address(hook));
        emit AnchorStepped(-1000, -1200, spot, block.number);
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.PriceOffReference.selector, spot, int24(-1000)));
        hook.burnIMD(false, 0);
        assertEq(hook.lastRef(), 0, "a revert undoes the re-centre");

        hook.pokeAnchor();
        assertEq(hook.lastRef(), -1000, "band re-centred on the anchor");
        assertEq(hook.lastRefBlock(), block.number);
        assertEq(hook.anchor(), -1200, "and the anchor stepped past the old edge");
        assertEq(hook.blockAnchor(), -1000);

        vm.roll(block.number + 1);
        hook.pokeAnchor();
        assertEq(hook.anchor(), spot, "the anchor reached the pool");

        vm.roll(block.number + 10);
        vm.recordLogs();
        uint256 out = hook.burnIMD(false, 0);
        BurnLog memory log_ = lastBurnLog();
        assertTrue(log_.fallbackMode);
        assertEq(log_.refTick, spot);
        assertGt(out, 0);
        assertGe(out, hook.quote(0.01 ether, spot) * 96 / 100);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    /// @dev Mirror case: a lasting move up pins the anchor at lastRef + 1000 and leaves the floor far
    /// below the market. After the re-centre the anchor follows and the floor tightens.
    function test_bandRecentersAfterALastingMoveUpAndTheFloorFollows() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(true, 120 ether);
        int24 spot = currentTick(plainKey);
        assertGt(spot, 1200);

        for (uint256 i = 0; i < 10; i++) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
        }
        assertEq(hook.anchor(), 1000, "pinned at the upper edge");
        uint256 looseFloor = hook.quote(0.01 ether, 1000) * 96 / 100;

        vm.roll(hook.lastRefBlock() + hook.FALLBACK_RECENTER_BLOCKS());
        hook.pokeAnchor();
        assertEq(hook.lastRef(), 1000);
        assertGt(hook.anchor(), 1000, "follows the pool again");
        while (hook.anchor() != spot) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
        }
        vm.roll(block.number + 1);
        hook.pokeAnchor(); // blockAnchor = spot
        assertEq(hook.blockAnchor(), spot);
        uint256 tightFloor = hook.quote(0.01 ether, spot) * 96 / 100;
        assertGt(tightFloor, looseFloor, "the output floor tracks the market");

        vm.roll(block.number + 5);
        uint256 out = hook.burnIMD(false, 0);
        assertGe(out, tightFloor);
    }

    function test_bandDoesNotRecenterBeforeRecenterBlocks() public {
        readyToBurn();
        hook.pokeAnchor();
        uint256 seedBlock = block.number;
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(false, 32 ether);
        vm.roll(seedBlock + hook.FALLBACK_RECENTER_BLOCKS() - 1);
        hook.pokeAnchor();
        assertEq(hook.lastRef(), 0);
        assertEq(hook.lastRefBlock(), seedBlock);
        vm.roll(seedBlock + hook.FALLBACK_RECENTER_BLOCKS());
        hook.pokeAnchor();
        assertEq(hook.lastRefBlock(), block.number, "re-centred exactly at the boundary");
    }

    /// @dev The band can drift at most FALLBACK_BAND per FALLBACK_RECENTER_BLOCKS: an attacker who
    /// holds the plain pool at a false price cannot move the reference faster than that.
    function test_recenterBoundsTheDriftOfTheReference() public {
        readyToBurn();
        hook.pokeAnchor();
        uint256 seedBlock = block.number;
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(false, 2000 ether); // very far below
        int24 spot = currentTick(plainKey);
        assertLt(spot, -5000);
        uint256 n = hook.FALLBACK_RECENTER_BLOCKS();
        // Every block for 2n blocks: the anchor can be at most -1000 (first band) - 1000 (one
        // re-centre) - 1000 (second re-centre at 2n) = -3000 after the step in block 2n.
        for (uint256 i = 1; i <= 2 * n; i++) {
            vm.roll(seedBlock + i);
            hook.pokeAnchor();
        }
        assertEq(hook.lastRef(), -2000);
        assertEq(hook.anchor(), -2200, "one step past the re-centred edge in the re-centre block");
        assertGe(hook.anchor(), -3000);
    }

    function test_reseedFromPool4ResetsTheRecenterClock() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(false, 32 ether);
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
        }
        assertEq(hook.anchor(), -1000);
        vm.roll(hook.lastRefBlock() + hook.FALLBACK_RECENTER_BLOCKS());
        hook.pokeAnchor();
        assertEq(hook.lastRef(), -1000);
        pool4Mock.setMarketOpen(true);
        pool4Mock.setRefTick(50);
        vm.roll(block.number + 1);
        hook.pokeAnchor();
        assertEq(hook.lastRef(), 50);
        assertEq(hook.lastRefBlock(), block.number);
        assertEq(hook.anchor(), 50);
    }

    function test_fallbackBurnUsesTheStartOfBlockAnchor() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(true, 15 ether);
        vm.roll(block.number + 1);
        // Stepping first in this block must not move the reference used by a burn in the same block.
        hook.pokeAnchor();
        assertEq(hook.anchor(), 200);
        assertEq(hook.blockAnchor(), 0);
        int24 spot = currentTick(plainKey);
        vm.recordLogs();
        hook.burnIMD(false, 0);
        BurnLog memory log_ = lastBurnLog();
        assertTrue(log_.fallbackMode);
        assertEq(log_.refTick, 0, "reference is the anchor as it stood when the block started");
        assertEq(log_.spot, spot);
        assertEq(hook.anchor(), 200, "the burn did not step the anchor a second time");
    }

    function test_fallbackBurnStepsTheAnchorItselfWhenFirstInTheBlock() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(true, 15 ether);
        vm.roll(block.number + 1);
        hook.burnIMD(false, 0);
        assertEq(hook.anchor(), 200, "the burn stepped the anchor");
        assertEq(hook.blockAnchor(), 0, "but used the start-of-block value");
    }

    function test_fallbackGuardHoldsUntilTheAnchorCatchesDown() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(false, 15 ether);
        int24 spot = currentTick(plainKey);
        assertLt(spot, -400);
        assertGt(spot, -800);

        // Reference 0, spot < -150: refused, and the refusal still steps the anchor? No: a revert
        // undoes the step, so the anchor only moves through pokeAnchor or a successful burn.
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.PriceOffReference.selector, spot, int24(0)));
        hook.burnIMD(false, 0);
        assertEq(hook.anchor(), 0);

        // Walk the anchor down 200 per block until the start-of-block anchor is within 150 of spot.
        uint256 guard;
        while (true) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
            int24 ref = hook.blockAnchor();
            if (spot >= ref - 150) break;
            guard++;
            assertLt(guard, 10);
        }
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_pokeAnchorReseedsFromPool4WhenItAnswers() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(true, 15 ether);
        vm.roll(block.number + 1);
        hook.pokeAnchor();
        assertEq(hook.anchor(), 200);

        pool4Mock.setMarketOpen(true);
        pool4Mock.setRefTick(777);
        vm.expectEmit(false, false, false, true, address(hook));
        emit AnchorSeeded(777, block.number);
        hook.pokeAnchor();
        assertEq(hook.anchor(), 777);
        assertEq(hook.blockAnchor(), 777);
        assertEq(hook.lastRef(), 777);
    }

    function test_normalBurnReseedsEverything() public {
        readyToBurn();
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        pushPlainSpot(true, 15 ether);
        vm.roll(block.number + 1);
        hook.pokeAnchor();
        assertEq(hook.anchor(), 200);
        pool4Mock.setMarketOpen(true);
        pool4Mock.setRefTick(100);
        hook.burnIMD(true, 0);
        assertEq(hook.anchor(), 100);
        assertEq(hook.blockAnchor(), 100);
        assertEq(hook.lastRef(), 100);
    }

    // ------------------------------------------------------------------------------------------
    // After retirement
    // ------------------------------------------------------------------------------------------

    function test_statusCountsBurnedIMDAfterRetirement() public {
        readyToBurn();
        MockMedallion impl = new MockMedallion();
        vm.etch(hook.MEDALLION_NFT(), address(impl).code);
        MockMedallion(hook.MEDALLION_NFT()).mint(hook.DEAD(), 447);
        hook.retire();
        uint256 out = hook.burnIMD(true, 0);
        assertEq(
            hook.status(),
            string.concat(
                "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: ",
                formatEther(out, 1),
                "."
            )
        );
        assertEq(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }

    function test_burnsNeverTouchTheCreatorsReserve() public {
        readyToBurn();
        for (uint256 i = 0; i < 4; i++) {
            hook.burnIMD(true, 0);
            vm.roll(block.number + 5);
        }
        assertEq(hook.burnSpent(), 0.2 ether);
        assertEq(hook.burnable(), 0);
        assertEq(hookClaims(), 1.64 ether, "the cap is still fully backed");
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(true, 0);
    }

    function testFuzz_batchIsMinOfBurnableAndCap(uint256 extraEth) public {
        extraEth = bound(extraEth, 0.1 ether, 5 ether);
        reachCap();
        buyExactIn(extraEth);
        uint256 burnable = hook.burnable();
        setUpIMD(0, IMD_LIQUIDITY);
        vm.roll(block.number + 5);
        hook.burnIMD(true, 0);
        uint256 expected = burnable < 0.05 ether ? burnable : 0.05 ether;
        assertEq(hook.burnSpent(), expected);
        assertEq(hook.burnable(), burnable - expected);
        assertGe(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }
}
