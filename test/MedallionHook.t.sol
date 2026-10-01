// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {MedallionHook} from "../src/MedallionHook.sol";
import {MedallionTestBase} from "./utils/MedallionTestBase.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Permissions, fee collection in all four swap shapes, the ledger, status() and the pinned
/// last fare.
contract MedallionHookTest is MedallionTestBase {
    using PoolIdLibrary for PoolKey;

    event Recouped(uint256 totalFees, uint256 blockNumber);
    event FeeCollected(bool indexed buy, uint256 fee, uint256 totalFees);
    event LaunchPoolSet(PoolId indexed poolId);

    // ------------------------------------------------------------------------------------------
    // Permissions, address and constructor
    // ------------------------------------------------------------------------------------------

    function test_permissionsAreExactlyTheFiveFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeInitialize);
        assertTrue(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookMiner.flagsOf(address(hook)), FLAGS);
        assertEq(FLAGS, 0x10CC);
    }

    function test_constructorRejectsAnAddressWithoutTheFlags() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.assume(HookMiner.flagsOf(predicted) != FLAGS);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MedallionHook(manager);
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(MedallionHook.ZeroPoolManager.selector);
        new MedallionHook(IPoolManager(address(0)));
    }

    function test_constructorSetsLastBurnBlockAndLeavesAnchorUnseeded() public view {
        assertEq(hook.lastBurnBlock(), block.number);
        assertFalse(hook.anchorSeeded());
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_publicConstants() public view {
        assertEq(hook.BUY_FEE_BPS(), 200);
        assertEq(hook.SELL_FEE_BPS(), 200);
        assertEq(hook.CREATOR_SHARE_BPS(), 10_000);
        assertEq(hook.CREATOR_CAP(), 1.64 ether);
        assertEq(hook.CREATOR(), 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a);
        assertEq(hook.MEDALLION_NFT(), 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03);
        assertEq(hook.MEDALLION_ID(), 447);
        assertEq(hook.DEAD(), 0x000000000000000000000000000000000000dEaD);
        assertEq(hook.IMD(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(hook.IMD_SINK(), hook.DEAD());
        assertEq(hook.POOL4_HOOK(), 0xc6C965Bd164c483e87d0B550671798e9A3602840);
        assertEq(hook.MAX_BURN_BATCH(), 0.05 ether);
        assertEq(hook.FALLBACK_BURN_BATCH(), 0.01 ether);
        assertEq(hook.MIN_BURN(), 0.002 ether);
        assertEq(hook.MIN_BLOCKS_BETWEEN_BURNS(), 5);
        assertEq(hook.MAX_REF_DEVIATION(), 150);
        assertEq(hook.MAX_PLAIN_DEVIATION(), 300);
        assertEq(hook.MAX_SLIPPAGE_BPS(), 400);
        assertEq(hook.ANCHOR_STEP(), 200);
        assertEq(hook.FALLBACK_BAND(), 1000);
    }

    function test_lastFareIsPinned() public view {
        string memory fare = hook.LAST_FARE();
        assertEq(bytes(fare).length, 1126);
        assertEq(keccak256(bytes(fare)), 0x0d095dc39a486d88dd13cac371e1aefd8e9c5f9315fdbeba70a10371604762f2);
        assertEq(hook.LAST_FARE_HASH(), 0x0d095dc39a486d88dd13cac371e1aefd8e9c5f9315fdbeba70a10371604762f2);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_noAdminSurface() public {
        string[10] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "setFee(uint256)",
            "setCreator(address)",
            "sweep(address)",
            "withdraw(uint256)",
            "setLaunchPool(bytes32)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Caller checks
    // ------------------------------------------------------------------------------------------

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(MedallionHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);

        vm.expectRevert(MedallionHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");

        vm.expectRevert(MedallionHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), BalanceDelta.wrap(0), ""
        );

        vm.expectRevert(MedallionHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), bytes("")));
    }

    function test_unlockCallbackRejectsUnknownActions() public {
        vm.prank(address(manager));
        vm.expectRevert(MedallionHook.UnknownAction.selector);
        hook.unlockCallback(abi.encode(uint8(9), bytes("")));
    }

    // ------------------------------------------------------------------------------------------
    // Launch pool selection
    // ------------------------------------------------------------------------------------------

    function test_firstNativePoolIsTheLaunchPool() public view {
        assertTrue(hook.launchPoolSet());
        assertEq(PoolId.unwrap(hook.launchPool()), PoolId.unwrap(poolId));
    }

    function test_tokenTokenPoolDoesNotBecomeLaunchPoolAndNeverReverts() public {
        MedallionHook fresh = deployHook(manager);
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        PoolKey memory tt = PoolKey(c0, c1, 3000, 60, IHooks(address(fresh)));
        manager.initialize(tt, SQRT_PRICE_1_1);
        assertFalse(fresh.launchPoolSet(), "a token/token pool must not be the launch pool");

        PoolKey memory eth = PoolKey(CurrencyLibrary.ADDRESS_ZERO, c1, 3000, 60, IHooks(address(fresh)));
        vm.expectEmit(true, false, false, true, address(fresh));
        emit LaunchPoolSet(eth.toId());
        manager.initialize(eth, SQRT_PRICE_1_1);
        assertTrue(fresh.launchPoolSet());
        assertEq(PoolId.unwrap(fresh.launchPool()), PoolId.unwrap(eth.toId()));

        // A second native pool does not displace the first and still initializes.
        PoolKey memory eth2 = PoolKey(CurrencyLibrary.ADDRESS_ZERO, c1, 10_000, 200, IHooks(address(fresh)));
        manager.initialize(eth2, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(fresh.launchPool()), PoolId.unwrap(eth.toId()));
    }

    // ------------------------------------------------------------------------------------------
    // Fees: the four swap shapes
    // ------------------------------------------------------------------------------------------

    function test_exactInBuyTakesTwoPercentOfEthInAsClaims() public {
        uint256 ethIn = 10 ether;
        uint256 before = address(this).balance;
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeCollected(true, 0.2 ether, 0.2 ether);
        BalanceDelta d = buyExactIn(ethIn);
        assertEq(d.amount0(), -int256(ethIn), "swapper pays exactly the amount specified");
        assertGt(d.amount1(), 0);
        assertEq(before - address(this).balance, ethIn);
        assertEq(hookClaims(), 0.2 ether);
        assertEq(hook.totalFees(), 0.2 ether);
    }

    function test_exactOutSellTakesTwoPercentOfEthOutAsClaims() public {
        uint256 ethOut = 5 ether;
        uint256 before = address(this).balance;
        BalanceDelta d = sellExactOut(ethOut);
        assertEq(d.amount0(), int256(ethOut), "swapper receives exactly the amount specified");
        assertLt(d.amount1(), 0);
        assertEq(address(this).balance - before, ethOut);
        assertEq(hookClaims(), 0.1 ether);
        assertEq(hook.totalFees(), 0.1 ether);
    }

    function test_exactOutBuyTakesTwoPercentOfGrossEthAsClaims() public {
        uint256 tokensOut = 10 ether;
        uint256 before = address(this).balance;
        BalanceDelta d = buyExactOut(tokensOut, 20 ether);
        assertEq(d.amount1(), int256(tokensOut));
        uint256 paid = uint256(uint128(-d.amount0()));
        assertEq(before - address(this).balance, paid, "the router refunds what the swap did not take");
        uint256 fee = hookClaims();
        uint256 gross = paid - fee;
        assertEq(fee, gross * 200 / 10_000, "fee is 2% of the pool's gross ETH delta");
        assertEq(hook.totalFees(), fee);
        assertGt(fee, 0);
    }

    function test_exactInSellTakesTwoPercentOfGrossEthAsClaims() public {
        uint256 tokensIn = 10 ether;
        uint256 before = address(this).balance;
        BalanceDelta d = sellExactIn(tokensIn);
        assertEq(d.amount1(), -int256(tokensIn));
        uint256 received = uint256(uint128(d.amount0()));
        assertEq(address(this).balance - before, received);
        uint256 fee = hookClaims();
        uint256 gross = received + fee;
        assertEq(fee, gross * 200 / 10_000, "fee is 2% of the pool's gross ETH delta");
        assertEq(hook.totalFees(), fee);
        assertGt(fee, 0);
    }

    function testFuzz_feeIsTwoPercentInEveryShape(uint256 amount, uint8 shape) public {
        shape = uint8(bound(shape, 0, 3));
        amount = bound(amount, 1e9, 50 ether);
        uint256 claimsBefore = hookClaims();
        uint256 feesBefore = hook.totalFees();
        BalanceDelta d;
        uint256 fee;
        if (shape == 0) {
            d = buyExactIn(amount);
            fee = amount * 200 / 10_000;
            assertEq(d.amount0(), -int256(amount));
        } else if (shape == 1) {
            d = sellExactOut(amount);
            fee = amount * 200 / 10_000;
            assertEq(d.amount0(), int256(amount));
        } else if (shape == 2) {
            d = buyExactOut(amount, amount * 2 + 1 ether);
            uint256 paid = uint256(uint128(-d.amount0()));
            fee = hookClaims() - claimsBefore;
            assertEq(fee, (paid - fee) * 200 / 10_000);
        } else {
            d = sellExactIn(amount);
            uint256 received = uint256(uint128(d.amount0()));
            fee = hookClaims() - claimsBefore;
            assertEq(fee, (received + fee) * 200 / 10_000);
        }
        assertEq(hookClaims() - claimsBefore, fee);
        assertEq(hook.totalFees() - feesBefore, fee);
        assertGe(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }

    function test_tinySwapBelowFeeGranularityIsFree() public {
        BalanceDelta d = buyExactIn(49);
        assertEq(d.amount0(), -49);
        assertEq(hookClaims(), 0);
        assertEq(hook.totalFees(), 0);
    }

    function test_feeIsNeverTakenInTokens() public {
        buyExactIn(1 ether);
        sellExactIn(1 ether);
        buyExactOut(1 ether, 2 ether);
        sellExactOut(0.5 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Partial fills in the beforeSwap shapes
    // ------------------------------------------------------------------------------------------

    function test_exactInBuyPartialFillReverts() public {
        // A price limit one tick below spot stops the pool long before 10 ETH is absorbed.
        uint160 limit = TickMath.getSqrtPriceAtTick(-1);
        vm.expectRevert(
            wrappedHookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(MedallionHook.PartialFill.selector))
        );
        swapOn(key, true, -10 ether, limit, 10 ether);
        assertEq(hookClaims(), 0);
        assertEq(hook.totalFees(), 0);
    }

    function test_exactOutSellPartialFillReverts() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(1);
        vm.expectRevert(
            wrappedHookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(MedallionHook.PartialFill.selector))
        );
        swapOn(key, false, 10 ether, limit, 0);
        assertEq(hookClaims(), 0);
    }

    function test_afterSwapShapesTolerateAPriceLimitAndStillChargeOnGross() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-1);
        BalanceDelta d = swapOn(key, true, 10 ether, limit, 10 ether);
        assertLt(d.amount1(), 10 ether, "the pool stopped at the limit");
        uint256 paid = uint256(uint128(-d.amount0()));
        uint256 fee = hookClaims();
        assertEq(fee, (paid - fee) * 200 / 10_000);
    }

    // ------------------------------------------------------------------------------------------
    // Other pools with this hook pay nothing
    // ------------------------------------------------------------------------------------------

    function test_otherPoolsWithTheHookAreFeeFree() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(this), 1_000_000 ether);
        other.approve(address(lpRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        PoolKey memory k2 =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(other)), 3000, 60, IHooks(address(hook)));
        manager.initialize(k2, SQRT_PRICE_1_1);
        addLiquidity(k2, FULL_LOWER_60, FULL_UPPER_60, 100 ether, 100 ether);

        BalanceDelta d = swapOn(k2, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertEq(hookClaims(), 0);
        assertEq(hook.totalFees(), 0);

        d = swapOn(k2, false, -1 ether, TickMath.MAX_SQRT_PRICE - 1, 0);
        assertEq(d.amount1(), -1 ether);
        assertEq(hookClaims(), 0);
        d = swapOn(k2, true, 1 ether, TickMath.MIN_SQRT_PRICE + 1, 2 ether);
        assertEq(d.amount1(), 1 ether);
        d = swapOn(k2, false, 1 ether, TickMath.MAX_SQRT_PRICE - 1, 0);
        assertEq(d.amount0(), 1 ether);
        assertEq(hookClaims(), 0);
        assertEq(hook.totalFees(), 0);
    }

    // ------------------------------------------------------------------------------------------
    // A fresh manager with token-only liquidity: claims need no ETH in the manager
    // ------------------------------------------------------------------------------------------

    function test_buyWorksOnAFreshManagerSeededWithTokensOnly() public {
        PoolManager pm = new PoolManager(address(this));
        PoolSwapTest sr = new PoolSwapTest(pm);
        PoolModifyLiquidityTest lr = new PoolModifyLiquidityTest(pm);
        token.approve(address(lr), type(uint256).max);
        token.approve(address(sr), type(uint256).max);
        MedallionHook h = deployHook(pm);
        PoolKey memory k =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 3000, 60, IHooks(address(h)));
        pm.initialize(k, SQRT_PRICE_1_1);
        // Entirely below spot: only FARE447 is deposited, the manager holds no ETH at all.
        lr.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: FULL_LOWER_60, tickUpper: -60, liquidityDelta: 1_000 ether, salt: 0}),
            ""
        );
        assertEq(address(pm).balance, 0);

        BalanceDelta d = sr.swap{value: 1 ether}(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(d.amount0(), -1 ether);
        assertEq(pm.balanceOf(address(h), 0), 0.02 ether);
        assertEq(h.totalFees(), 0.02 ether);
        assertEq(address(pm).balance, 1 ether);
    }

    // ------------------------------------------------------------------------------------------
    // Ledger
    // ------------------------------------------------------------------------------------------

    function test_burnableIsZeroUntilTheCapAndGrowsAfter() public {
        buyExactIn(40 ether); // 0.8 ETH
        assertEq(hook.creatorEntitlement(), 0.8 ether);
        assertEq(hook.burnable(), 0);
        buyExactIn(41 ether); // 1.62 ETH
        assertEq(hook.burnable(), 0);
        buyExactIn(1 ether); // 1.64 ETH exactly
        assertEq(hook.totalFees(), 1.64 ether);
        assertEq(hook.creatorEntitlement(), 1.64 ether);
        assertEq(hook.burnable(), 0);
        buyExactIn(3 ether); // 1.70 ETH
        assertEq(hook.creatorEntitlement(), 1.64 ether);
        assertEq(hook.burnable(), 0.06 ether);
        assertEq(hook.reservedClaims(), 1.7 ether);
        assertEq(hookClaims(), 1.7 ether);
    }

    function test_recoupedIsEmittedExactlyOnce() public {
        vm.recordLogs();
        buyExactIn(80 ether); // 1.60
        buyExactIn(2 ether); // 1.64 -> Recouped
        buyExactIn(2 ether); // 1.68, no second emission
        sellExactIn(1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == keccak256("Recouped(uint256,uint256)")) {
                (uint256 fees, uint256 blk) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(fees, 1.64 ether);
                assertEq(blk, block.number);
                count++;
            }
        }
        assertEq(count, 1, "Recouped must be emitted once");
    }

    function test_recoupedEmittedOnTheCrossingSwapWithTheOvershoot() public {
        buyExactIn(80 ether);
        vm.expectEmit(false, false, false, true, address(hook));
        emit Recouped(1.7 ether, block.number);
        buyExactIn(5 ether);
    }

    function test_donatedClaimsDoNotCountAsFeesAndKeepTheInvariant() public {
        buyExactIn(10 ether);
        // Take some ETH out of the pool as claims and hand them to the hook.
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -5 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        uint256 mine = manager.balanceOf(address(this), 0);
        assertGt(mine, 0);
        uint256 feesBefore = hook.totalFees();
        uint256 claimsBefore = hookClaims();
        manager.transfer(address(hook), 0, mine);
        assertEq(hook.totalFees(), feesBefore, "donations never add to totalFees");
        assertEq(hook.burnable(), 0);
        assertEq(hookClaims(), claimsBefore + mine);
        assertGe(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        // Raw ETH sent to the hook is refused: it has no receive function.
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_swapsOnlyEverAddToTotalFees() public {
        uint256 last;
        for (uint256 i = 0; i < 6; i++) {
            if (i % 2 == 0) buyExactIn(1 ether);
            else sellExactIn(1 ether);
            assertGt(hook.totalFees(), last);
            last = hook.totalFees();
        }
    }

    // ------------------------------------------------------------------------------------------
    // status()
    // ------------------------------------------------------------------------------------------

    function test_statusInService() public {
        assertEq(hook.status(), "IN SERVICE. Recouped 0.00 of 1.64 ETH.");
        buyExactIn(1 ether); // 0.02
        assertEq(hook.status(), "IN SERVICE. Recouped 0.02 of 1.64 ETH.");
        buyExactIn(0.999 ether); // + 0.01998 = 0.03998 -> truncated 0.03
        assertEq(hook.status(), "IN SERVICE. Recouped 0.03 of 1.64 ETH.");
        buyExactIn(60 ether); // + 1.2 = 1.23998
        assertEq(hook.status(), "IN SERVICE. Recouped 1.23 of 1.64 ETH.");
    }

    function test_statusRecoupedNotRetired() public {
        reachCap();
        assertEq(
            hook.status(),
            "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447."
        );
        buyExactIn(10 ether);
        assertEq(
            hook.status(),
            "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447."
        );
    }

    function testFuzz_statusFormatsTwoTruncatedDecimals(uint256 ethIn) public {
        ethIn = bound(ethIn, 50, 81 ether);
        buyExactIn(ethIn);
        uint256 fees = hook.totalFees();
        vm.assume(fees < 1.64 ether);
        assertEq(hook.status(), string.concat("IN SERVICE. Recouped ", formatEther(fees, 2), " of 1.64 ETH."));
    }

    // ------------------------------------------------------------------------------------------
    // quote()
    // ------------------------------------------------------------------------------------------

    function test_quoteIsAmountTimesPrice() public view {
        assertEq(hook.quote(1 ether, 0), 1 ether);
        // 1.0001^6932 ~= 2.0001
        assertApproxEqRel(hook.quote(1 ether, 6932), 2 ether, 1e15);
        assertApproxEqRel(hook.quote(1 ether, -6932), 0.5 ether, 1e15);
        assertEq(hook.quote(0, 12345), 0);
    }
}
