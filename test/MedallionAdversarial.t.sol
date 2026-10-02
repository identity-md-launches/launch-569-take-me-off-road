// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {MedallionHook} from "../src/MedallionHook.sol";
import {MedallionTestBase} from "./utils/MedallionTestBase.sol";
import {MockMedallion, RawAnswer} from "./mocks/MockMedallion.sol";
import {
    Reverting,
    ReentrantPool4Hook,
    EthRejectingCreator,
    ReenteringCreator,
    CallbackMedallion,
    UnlockProbe
} from "./mocks/Collaborators.sol";

/// @notice The inputs the implementation did not choose: collaborators that misbehave (the POOL4 hook,
/// the medallion, the creator's address), pools with nothing in them, price limits that stop the
/// pool early, references at the tick extremes, and callers who are not who the code assumed.
/// @dev Every test here is a failure path or an edge; the happy paths live in the other suites.
/// forge-config: default.fuzz.runs = 512
contract MedallionAdversarialTest is MedallionTestBase {
    using PoolIdLibrary for PoolKey;

    uint8 internal constant ACTION_PAY_CREATOR = 1;
    uint8 internal constant ACTION_BURN = 2;

    // ------------------------------------------------------------------------------------------
    // Empty pools: the fee must never be charged for a trade that did not happen
    // ------------------------------------------------------------------------------------------

    /// @dev A fresh hook with a launch pool that holds no liquidity at all.
    function emptyLaunch() internal returns (MedallionHook fresh, PoolKey memory k) {
        fresh = deployHook(manager);
        k = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 3000, 60, IHooks(address(fresh)));
        manager.initialize(k, SQRT_PRICE_1_1);
        assertTrue(fresh.launchPoolSet());
    }

    function test_exactInBuyOnAnEmptyPoolRevertsPartialFillInsteadOfKeepingTheFee() public {
        (MedallionHook fresh, PoolKey memory k) = emptyLaunch();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(MedallionHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapOn(k, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1, 1 ether);
        assertEq(manager.balanceOf(address(fresh), 0), 0);
        assertEq(fresh.totalFees(), 0);
    }

    function test_exactOutSellOnAnEmptyPoolRevertsPartialFill() public {
        (MedallionHook fresh, PoolKey memory k) = emptyLaunch();
        (bool ok, bytes memory ret) = address(swapRouter).call(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    k,
                    SwapParams(false, 1 ether, TickMath.MAX_SQRT_PRICE - 1),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                )
            )
        );
        assertFalse(ok);
        assertTrue(containsSelector(ret, MedallionHook.PartialFill.selector), "PartialFill expected");
        assertEq(fresh.totalFees(), 0);
    }

    function test_afterSwapShapesOnAnEmptyPoolChargeNothingAndMoveNothing() public {
        (MedallionHook fresh, PoolKey memory k) = emptyLaunch();
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));
        BalanceDelta d = swapOn(k, true, 1 ether, TickMath.MIN_SQRT_PRICE + 1, 2 ether);
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        d = swapOn(k, false, -1 ether, TickMath.MAX_SQRT_PRICE - 1, 0);
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        assertEq(address(this).balance, ethBefore, "no ETH left the swapper");
        assertEq(token.balanceOf(address(this)), tokBefore, "no tokens left the swapper");
        assertEq(fresh.totalFees(), 0);
        assertEq(manager.balanceOf(address(fresh), 0), 0);
    }

    function test_exactOutSellBeyondThePoolsEthRevertsPartialFill() public {
        // A launch pool whose only liquidity sits in [60, 600]: about 3 ETH is all a seller can get.
        MedallionHook fresh = deployHook(manager);
        PoolKey memory k =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 3000, 60, IHooks(address(fresh)));
        manager.initialize(k, SQRT_PRICE_1_1);
        uint256 managerEthBefore = address(manager).balance;
        addLiquidity(k, 60, 600, 100 ether, 5 ether);
        assertLt(address(manager).balance - managerEthBefore, 5 ether, "the range holds only a few ETH");

        (bool ok, bytes memory ret) = address(swapRouter).call(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    k,
                    SwapParams(false, 10 ether, TickMath.MAX_SQRT_PRICE - 1),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                )
            )
        );
        assertFalse(ok, "the pool ran dry before 10 ETH + fee were delivered");
        assertTrue(containsSelector(ret, MedallionHook.PartialFill.selector));
        assertEq(fresh.totalFees(), 0);
        assertEq(manager.balanceOf(address(fresh), 0), 0);

        // What the pool can deliver is delivered exactly, with the fee on top of it.
        BalanceDelta d = swapOn(k, false, 1 ether, TickMath.MAX_SQRT_PRICE - 1, 0);
        assertEq(d.amount0(), 1 ether);
        assertEq(fresh.totalFees(), 0.02 ether);
    }

    // ------------------------------------------------------------------------------------------
    // Price limits, fuzzed: the beforeSwap shapes fill exactly or revert, never in between
    // ------------------------------------------------------------------------------------------

    function testFuzz_ethSpecifiedShapesFillExactlyOrRevertPartialFill(uint256 amount, int24 limitTick, bool buy)
        public
    {
        amount = bound(amount, 1e9, 100 ether);
        // A buy pushes the price down, a sell pushes it up: the limit must be on that side of spot (0).
        limitTick = buy ? int24(bound(limitTick, -600_000, -1)) : int24(bound(limitTick, 1, 600_000));
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        uint256 fee = amount * 200 / 10_000;

        (bool ok, bytes memory ret) = address(swapRouter).call{value: buy ? amount : 0}(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    key,
                    SwapParams(buy, buy ? -int256(amount) : int256(amount), limit),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                )
            )
        );
        if (ok) {
            BalanceDelta d = BalanceDelta.wrap(abi.decode(ret, (int256)));
            assertEq(d.amount0(), buy ? -int256(amount) : int256(amount), "filled exactly the amount specified");
            assertEq(hook.totalFees(), fee, "and charged exactly 2% of it");
            assertEq(hookClaims(), fee);
        } else {
            assertEq(
                ret,
                wrappedHookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(MedallionHook.PartialFill.selector)),
                "the only acceptable failure is PartialFill"
            );
            assertEq(hook.totalFees(), 0, "a refused swap charges nothing");
            assertEq(hookClaims(), 0);
        }
    }

    function testFuzz_afterSwapShapesChargeTwoPercentOfWhatWasActuallyFilled(uint256 amount, int24 limitTick, bool buy)
        public
    {
        amount = bound(amount, 1e9, 100 ether);
        limitTick = buy ? int24(bound(limitTick, -600_000, -1)) : int24(bound(limitTick, 1, 600_000));
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);

        BalanceDelta d = buy
            ? swapOn(key, true, int256(amount), limit, amount * 2 + 1 ether)
            : swapOn(key, false, -int256(amount), limit, 0);
        uint256 fee = hookClaims();
        if (buy) {
            uint256 paid = uint256(uint128(-d.amount0()));
            assertEq(fee, (paid - fee) * 200 / 10_000);
            assertLe(uint256(uint128(d.amount1())), amount);
        } else {
            uint256 received = uint256(uint128(d.amount0()));
            assertEq(fee, (received + fee) * 200 / 10_000);
            assertLe(uint256(uint128(-d.amount1())), amount);
        }
        assertEq(hook.totalFees(), fee);
    }

    // ------------------------------------------------------------------------------------------
    // Swap callbacks reach nothing but the PoolManager
    // ------------------------------------------------------------------------------------------

    function test_swapCallbacksTouchNoOtherContract() public {
        // If a swap callback called the medallion, POOL4, IMD or CREATOR, the trade would revert.
        Reverting impl = new Reverting();
        vm.etch(hook.MEDALLION_NFT(), address(impl).code);
        vm.etch(hook.POOL4_HOOK(), address(impl).code);
        vm.etch(hook.IMD(), address(impl).code);
        vm.etch(hook.CREATOR(), address(impl).code);

        buyExactIn(1 ether);
        sellExactOut(0.5 ether);
        buyExactOut(1 ether, 2 ether);
        sellExactIn(1 ether);
        assertGt(hook.totalFees(), 0);
        assertEq(hook.status(), string.concat("IN SERVICE. Recouped ", formatEther(hook.totalFees(), 2), " of 1.64 ETH."));
        assertEq(hook.CREATOR().balance, 0);
    }

    // ------------------------------------------------------------------------------------------
    // The creator's address misbehaves
    // ------------------------------------------------------------------------------------------

    function etchMedallionAtDead() internal {
        MockMedallion impl = new MockMedallion();
        vm.etch(hook.MEDALLION_NFT(), address(impl).code);
        MockMedallion(hook.MEDALLION_NFT()).mint(hook.DEAD(), 447);
    }

    function test_creatorThatRejectsEthBlocksRetireButNothingElse() public {
        reachCap();
        etchMedallionAtDead();
        vm.etch(hook.CREATOR(), address(new EthRejectingCreator()).code);
        uint256 claimsBefore = hookClaims();

        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(MedallionHook.retire, ()));
        assertFalse(ok, "retire cannot complete");
        assertTrue(containsSelector(ret, bytes4(keccak256("NativeTransferFailed()"))), "the manager's transfer failed");
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(hookClaims(), claimsBefore, "the claims are still there");
        assertEq(hook.CREATOR().balance, 0);

        // Trading is unaffected.
        buyExactIn(1 ether);
        assertEq(hook.totalFees(), 1.66 ether);
    }

    function test_creatorReenteringRetireIsRefused() public {
        reachCap();
        etchMedallionAtDead();
        vm.etch(hook.CREATOR(), address(new ReenteringCreator()).code);
        ReenteringCreator(payable(hook.CREATOR())).setHook(address(hook));

        (bool ok,) = address(hook).call(abi.encodeCall(MedallionHook.retire, ()));
        assertFalse(ok, "the inner retire hits the lock, the ETH transfer fails, the outer retire reverts");
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.CREATOR().balance, 0);
        assertEq(hookClaims(), 1.64 ether);
    }

    // ------------------------------------------------------------------------------------------
    // The medallion misbehaves during its own transfer
    // ------------------------------------------------------------------------------------------

    address internal nftOwner = makeAddr("nftOwner");

    function etchCallbackMedallion() internal returns (CallbackMedallion nft) {
        vm.etch(hook.MEDALLION_NFT(), address(new CallbackMedallion()).code);
        nft = CallbackMedallion(payable(hook.MEDALLION_NFT()));
        nft.mint(nftOwner, 447);
    }

    function test_medallionTransferCannotReenterBurnIMD() public {
        reachCap();
        buyExactIn(10 ether);
        setUpIMD(0, 500 ether);
        vm.roll(block.number + 5);
        CallbackMedallion nft = etchCallbackMedallion();
        nft.setCall(address(hook), abi.encodeCall(MedallionHook.burnIMD, (true, 0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                MedallionHook.RetireRefused.selector, abi.encodeWithSelector(MedallionHook.Reentrancy.selector)
            )
        );
        hook.retire();
        assertEq(hook.burnSpent(), 0);
        assertFalse(hook.retired());
    }

    function test_medallionTransferCannotReenterPokeAnchor() public {
        reachCap();
        setUpIMD(0, 500 ether);
        CallbackMedallion nft = etchCallbackMedallion();
        nft.setCall(address(hook), abi.encodeCall(MedallionHook.pokeAnchor, ()));
        vm.expectRevert(
            abi.encodeWithSelector(
                MedallionHook.RetireRefused.selector, abi.encodeWithSelector(MedallionHook.Reentrancy.selector)
            )
        );
        hook.retire();
        assertFalse(hook.anchorSeeded(), "the poke never ran");
    }

    function test_aSwapDuringTheMedallionTransferDoesNotDisturbRetire() public {
        reachCap();
        CallbackMedallion nft = etchCallbackMedallion();
        nft.setSwap(swapRouter, key);
        vm.deal(address(nft), 1 ether);

        hook.retire();
        assertTrue(hook.retired());
        assertEq(nft.ownerOf(447), hook.DEAD());
        assertEq(hook.CREATOR().balance, 1.64 ether, "exactly the cap, whatever happened in between");
        assertEq(hook.totalFees(), 1.66 ether, "the swap in flight still paid its fee");
        assertEq(hook.burnable(), 0.02 ether);
        assertEq(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }

    // ------------------------------------------------------------------------------------------
    // Odd answers from the medallion
    // ------------------------------------------------------------------------------------------

    function test_retireNotRecoupedComesBeforeAnyMedallionRead() public {
        buyExactIn(81.9999 ether); // 1.639998 ETH: two millionths short
        assertEq(hook.totalFees(), 1.639998 ether);
        assertEq(hook.MEDALLION_NFT().code.length, 0);
        vm.expectRevert(MedallionHook.NotRecouped.selector);
        hook.retire();
        assertEq(hook.status(), "IN SERVICE. Recouped 1.63 of 1.64 ETH.");
    }

    function test_retireIsRefusedWhenOwnerOfAnswersTheZeroAddress() public {
        reachCap();
        vm.etch(hook.MEDALLION_NFT(), address(new RawAnswer()).code);
        RawAnswer at = RawAnswer(payable(hook.MEDALLION_NFT()));
        at.setAnswer(bytes4(0x6352211e), abi.encode(address(0)));
        // transferFrom "succeeds" with no data, and ownerOf still says zero.
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.RetireRefused.selector, bytes("")));
        hook.retire();
        assertFalse(hook.retired());
    }

    function test_retireIsRefusedWhenTransferFromReturnsFalse() public {
        reachCap();
        vm.etch(hook.MEDALLION_NFT(), address(new RawAnswer()).code);
        RawAnswer at = RawAnswer(payable(hook.MEDALLION_NFT()));
        at.setAnswer(bytes4(0x6352211e), abi.encode(nftOwner));
        at.setAnswer(bytes4(0x23b872dd), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.RetireRefused.selector, abi.encode(false)));
        hook.retire();
        assertFalse(hook.retired());
        assertEq(hook.CREATOR().balance, 0);
    }

    function test_donatedClaimsNeitherRecoupNorBecomeBurnable() public {
        // Someone hands the hook 2 ETH of claims while only one 0.04 ETH fee has been earned.
        swapRouter.swap{value: 0}(
            key,
            SwapParams({zeroForOne: false, amountSpecified: 2 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.totalFees(), 0.04 ether, "the exact-out sell that produced the claims paid its own fee");
        manager.transfer(address(hook), 0, 2 ether);
        assertEq(hookClaims(), 2.04 ether);
        etchMedallionAtDead();
        vm.expectRevert(MedallionHook.NotRecouped.selector);
        hook.retire();
        assertEq(hook.burnable(), 0);
        assertEq(hook.creatorEntitlement(), 0.04 ether);
        assertEq(hook.status(), "IN SERVICE. Recouped 0.04 of 1.64 ETH.");
    }

    // ------------------------------------------------------------------------------------------
    // The POOL4 hook misbehaves during the burn swap
    // ------------------------------------------------------------------------------------------

    function etchReentrantPool4() internal returns (ReentrantPool4Hook p4) {
        reachCap();
        buyExactIn(10 ether);
        etchIMD();
        vm.etch(hook.POOL4_HOOK(), address(new ReentrantPool4Hook()).code);
        p4 = ReentrantPool4Hook(hook.POOL4_HOOK());
        p4.setMarketOpen(true);
        p4.setRefTick(0);
        pool4Key = hook.pool4Key();
        plainKey = hook.plainKey();
        manager.initialize(pool4Key, SQRT_PRICE_1_1);
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        addLiquidity(pool4Key, FULL_LOWER_60, FULL_UPPER_60, 500 ether, 500 ether);
        addLiquidity(plainKey, FULL_LOWER_200, FULL_UPPER_200, 500 ether, 500 ether);
        vm.roll(block.number + 5);
    }

    function assertBurnViaPool4Refused(bytes4 reason) internal {
        uint256 spentBefore = hook.burnSpent();
        uint256 lastBlockBefore = hook.lastBurnBlock();
        uint256 claimsBefore = hookClaims();
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(MedallionHook.burnIMD, (true, 0)));
        assertFalse(ok, "the POOL4 burn must fail");
        assertTrue(containsSelector(ret, reason), "unexpected reason");
        assertEq(hook.burnSpent(), spentBefore, "nothing spent");
        assertEq(hook.lastBurnBlock(), lastBlockBefore, "the spacing clock did not move");
        assertEq(hookClaims(), claimsBefore);
    }

    function test_pool4HookReenteringPokeAnchorIsRefusedAndThePlainPoolStillWorks() public {
        ReentrantPool4Hook p4 = etchReentrantPool4();
        p4.setReentry(address(hook), abi.encodeCall(MedallionHook.pokeAnchor, ()));
        assertBurnViaPool4Refused(MedallionHook.Reentrancy.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
    }

    function test_pool4HookReenteringBurnIMDIsRefused() public {
        ReentrantPool4Hook p4 = etchReentrantPool4();
        p4.setReentry(address(hook), abi.encodeCall(MedallionHook.burnIMD, (false, 0)));
        assertBurnViaPool4Refused(MedallionHook.Reentrancy.selector);
    }

    function test_pool4HookReenteringRetireIsRefused() public {
        ReentrantPool4Hook p4 = etchReentrantPool4();
        etchMedallionAtDead();
        p4.setReentry(address(hook), abi.encodeCall(MedallionHook.retire, ()));
        assertBurnViaPool4Refused(MedallionHook.Reentrancy.selector);
        assertFalse(hook.retired());
        assertEq(hook.CREATOR().balance, 0);
    }

    function test_pool4HookThatRevertsOnSwapsLeavesThePlainPoolRoute() public {
        ReentrantPool4Hook p4 = etchReentrantPool4();
        p4.setPlainRevert(true);
        assertBurnViaPool4Refused(CustomRevert.WrappedError.selector);
        uint256 out = hook.burnIMD(false, 0);
        assertGt(out, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
    }

    // ------------------------------------------------------------------------------------------
    // The unlock callback cannot be driven from outside the hook's own unlocks
    // ------------------------------------------------------------------------------------------

    function test_unlockCallbackFromTheManagerOutsideAnUnlockPaysNothing() public {
        reachCap();
        bytes memory payPayload = abi.encode(ACTION_PAY_CREATOR, bytes(""));
        bytes memory burnPayload = abi.encode(ACTION_BURN, abi.encode(hook.plainKey(), uint256(0.05 ether), uint256(0)));

        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.ManagerLocked.selector));
        hook.unlockCallback(payPayload);
        assertEq(hook.CREATOR().balance, 0);
        assertEq(hookClaims(), 1.64 ether);

        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.ManagerLocked.selector));
        hook.unlockCallback(burnPayload);
        assertEq(hook.burnSpent(), 0);
    }

    function test_aStrangersUnlockWithTheHooksPayloadLandsOnTheStranger() public {
        reachCap();
        UnlockProbe probe = new UnlockProbe(manager);
        bytes memory payload = abi.encode(ACTION_PAY_CREATOR, bytes(""));
        probe.probe(payload);
        assertEq(probe.callbacks(), 1, "the manager calls back msg.sender, never the hook");
        assertEq(probe.lastData(), payload);
        assertEq(hook.CREATOR().balance, 0);
        assertEq(hookClaims(), 1.64 ether);
        assertFalse(hook.retired());
    }

    // ------------------------------------------------------------------------------------------
    // References at the tick extremes
    // ------------------------------------------------------------------------------------------

    function test_pool4ReferenceAtMaxTickRefusesTheBurnWithoutAPanic() public {
        reachCap();
        buyExactIn(10 ether);
        setUpIMD(TickMath.MAX_TICK, 500 ether);
        vm.roll(block.number + 5);
        // Both pools sit at tick 0, far below a reference at MAX_TICK: the one-sided guard refuses.
        // The quote at MAX_TICK itself is computed without overflow on the way there.
        assertGt(hook.quote(0.05 ether, TickMath.MAX_TICK), hook.quote(0.05 ether, 0));
        vm.expectRevert(
            abi.encodeWithSelector(MedallionHook.PriceOffReference.selector, int24(0), TickMath.MAX_TICK)
        );
        hook.burnIMD(true, 0);
        vm.expectRevert(
            abi.encodeWithSelector(MedallionHook.PriceOffReference.selector, int24(0), TickMath.MAX_TICK)
        );
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0);
    }

    /// @dev A reference at MIN_TICK makes the quote, and so the contract's own floor, zero: the
    /// one-sided guard cannot refuse any spot and only callerMinOut protects the batch. The burn still
    /// keeps the ledger and sends everything it gets to the sink.
    function test_pool4ReferenceAtMinTickLeavesOnlyTheCallersFloor() public {
        reachCap();
        buyExactIn(10 ether);
        setUpIMD(TickMath.MIN_TICK, 500 ether);
        vm.roll(block.number + 5);
        assertEq(hook.quote(0.05 ether, TickMath.MIN_TICK), 0);
        uint256 fair = hook.quote(0.05 ether, 0);

        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(MedallionHook.burnIMD, (true, fair)));
        assertFalse(ok, "a caller floor above the pool's output is honoured");
        assertEq(bytes4(ret), MedallionHook.InsufficientOutput.selector);

        vm.recordLogs();
        uint256 out = hook.burnIMD(true, 0);
        BurnLog memory log_ = lastBurnLog();
        assertEq(log_.refTick, TickMath.MIN_TICK);
        assertGt(out, 0);
        assertEq(imdBalance(hook.DEAD()), out);
        assertEq(hook.anchor(), TickMath.MIN_TICK);
        assertEq(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }

    function test_fallbackAnchorSeededAtMinTickStepsUpAndStaysInRange() public {
        reachCap();
        buyExactIn(10 ether);
        setUpIMD(TickMath.MIN_TICK, 500 ether);
        hook.pokeAnchor();
        pool4Mock.setMarketOpen(false);
        for (uint256 i = 0; i < 6; i++) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
            assertGe(hook.anchor(), TickMath.MIN_TICK);
            assertLe(hook.anchor(), TickMath.MAX_TICK);
            hook.quote(0.01 ether, hook.anchor()); // never reverts on an in-range anchor
        }
        assertEq(hook.anchor(), TickMath.MIN_TICK + 1000, "clamped to lastRef + FALLBACK_BAND");
    }

    // ------------------------------------------------------------------------------------------
    // After retirement, every shape feeds the burn budget and nothing more reaches the creator
    // ------------------------------------------------------------------------------------------

    function test_everyShapeAfterRetirementIsBurnableAndTheCreatorGetsNoMore() public {
        reachCap();
        etchMedallionAtDead();
        hook.retire();
        uint256 feesBefore = hook.totalFees();
        buyExactIn(1 ether);
        sellExactOut(1 ether);
        buyExactOut(1 ether, 2 ether);
        sellExactIn(1 ether);
        uint256 earned = hook.totalFees() - feesBefore;
        assertGt(earned, 0.04 ether);
        assertEq(hook.burnable(), earned);
        assertEq(hook.creatorEntitlement(), 1.64 ether);
        assertEq(hook.CREATOR().balance, 1.64 ether);
        assertEq(hookClaims(), earned);
    }

    function test_statusRetiredFormatsOneTruncatedDecimalOfALargeBurn() public {
        reachCap();
        buyExactIn(10 ether);
        etchMedallionAtDead();
        hook.retire();
        // IMD pools at 1,000,000 IMD per ETH so one batch buys tens of thousands of IMD.
        etchIMD();
        etchPool4(true, 138162); // ~1.0001^138162 = 1e6
        pool4Key = hook.pool4Key();
        plainKey = hook.plainKey();
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(138162);
        manager.initialize(pool4Key, sqrtP);
        // Liquidity 50,000: about 50 ETH and 5e25 IMD in range, so a 0.05 ETH batch barely moves it.
        addLiquidity(pool4Key, FULL_LOWER_60, FULL_UPPER_60, 50_000 ether, 60 ether);
        vm.roll(block.number + 5);
        uint256 out = hook.burnIMD(true, 0);
        assertGt(out, 10_000 ether, "a large number with digits before the point");
        assertEq(
            hook.status(),
            string.concat(
                "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: ",
                formatEther(out, 1),
                "."
            )
        );
        assertEq(manager.balanceOf(address(hook), uint256(uint160(hook.IMD()))), 0, "no IMD claims linger");
    }

    // ------------------------------------------------------------------------------------------
    // quote(): the pure core, fuzzed
    // ------------------------------------------------------------------------------------------

    function testFuzz_quoteIsMonotonicInTheTickAndLinearInTheAmount(uint256 a, uint256 b, int24 t1, int24 t2) public view {
        a = bound(a, 0, 1 ether);
        b = bound(b, 0, 1 ether);
        t1 = int24(bound(t1, TickMath.MIN_TICK, TickMath.MAX_TICK));
        t2 = int24(bound(t2, TickMath.MIN_TICK, TickMath.MAX_TICK));
        if (t1 > t2) (t1, t2) = (t2, t1);
        assertLe(hook.quote(a, t1), hook.quote(a, t2), "more IMD per ETH at a higher tick");
        uint256 sum = hook.quote(a, t1) + hook.quote(b, t1);
        uint256 whole = hook.quote(a + b, t1);
        // Two floor divisions per quote; the first one's rounding is scaled by sqrtPrice / 2^96.
        uint256 tolerance = 2 * (uint256(TickMath.getSqrtPriceAtTick(t1)) / 2 ** 96 + 1);
        assertLe(sum, whole + tolerance);
        assertLe(whole, sum + tolerance);
        assertEq(hook.quote(a, 0), a);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    /// @dev Whether a 4-byte selector appears anywhere in revert data (wrapped errors nest reasons).
    function containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }
}
