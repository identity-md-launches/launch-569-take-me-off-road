// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {MedallionHook} from "../src/MedallionHook.sol";
import {FareToken} from "../src/FareToken.sol";
import {MedallionTestBase} from "./utils/MedallionTestBase.sol";
import {MockMedallion} from "./mocks/MockMedallion.sol";

/// @notice Drives the hook with several actors and keeps a ghost ledger computed from the
/// PoolManager's own Swap events, never from the hook: expected fees, burn batches, burn spacing and
/// the monotone counters. The handler never reverts; every refused action is caught and checked to
/// have changed nothing.
contract LedgerHandler is MedallionTestBase {
    using PoolIdLibrary for PoolKey;

    address[3] public traders;
    address[2] public keepers;
    address public nftOwner;
    MockMedallion public nft;

    // Ghost ledger
    uint256 public ghostFees;
    uint256 public ghostBurnSpent;
    uint256 public ghostImdOut;
    uint256 public ghostBurns;
    uint256 public ghostFallbackBurns;
    uint256 public ghostLastBurnBlock;
    uint256 public ghostRetires;
    uint256 public ghostSwaps;
    uint256 public ghostRefusedSwaps;
    uint256 public ghostRefusedBurns;
    bool public ghostRetired;
    uint256 public maxTotalFeesSeen;
    uint256 public maxBurnSpentSeen;
    uint256 public maxImdBurnedSeen;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function setUp() public override {
        super.setUp();
        setUpIMD(0, 500 ether);
        traders = [makeAddr("trader0"), makeAddr("trader1"), makeAddr("trader2")];
        keepers = [makeAddr("keeper0"), makeAddr("keeper1")];
        nftOwner = makeAddr("nftOwner");
        for (uint256 i = 0; i < traders.length; i++) {
            token.transfer(traders[i], 10_000_000 ether);
            vm.prank(traders[i]);
            token.approve(address(swapRouter), type(uint256).max);
        }
        MockMedallion impl = new MockMedallion();
        vm.etch(hook.MEDALLION_NFT(), address(impl).code);
        nft = MockMedallion(hook.MEDALLION_NFT());
        nft.mint(nftOwner, 447);
        vm.prank(nftOwner);
        nft.setApprovalForAll(address(hook), true);
        ghostLastBurnBlock = block.number;
    }

    // ------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------

    function swap(uint8 who, uint8 shape, uint256 amount) external {
        address trader = traders[bound(who, 0, traders.length - 1)];
        shape = uint8(bound(shape, 0, 3));
        amount = bound(amount, 1e12, 20 ether);
        bool zeroForOne = shape == 0 || shape == 2;
        int256 specified = (shape == 0 || shape == 3) ? -int256(amount) : int256(amount);
        uint256 ethToSend = shape == 0 ? amount : (shape == 2 ? amount * 10 + 1 ether : 0);
        vm.deal(trader, ethToSend);

        uint256 feesBefore = hook.totalFees();
        uint256 claimsBefore = hookClaims();
        vm.recordLogs();
        vm.prank(trader);
        try swapRouter.swap{value: ethToSend}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: specified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (BalanceDelta d) {
            uint256 gross = poolGrossEth();
            uint256 fee = (shape == 0 || shape == 1) ? amount * 200 / 10_000 : gross * 200 / 10_000;
            ghostFees += fee;
            ghostSwaps++;
            if (shape == 0) assertEq(d.amount0(), -int256(amount), "exact-in buy pays exactly the amount");
            if (shape == 1) assertEq(d.amount0(), int256(amount), "exact-out sell receives exactly the amount");
            if (shape == 2) assertEq(uint256(uint128(-d.amount0())), gross + fee, "exact-out buy pays gross + fee");
            if (shape == 3) assertEq(uint256(uint128(d.amount0())), gross - fee, "exact-in sell receives gross - fee");
            assertEq(hook.totalFees() - feesBefore, fee, "the hook charged what the ledger expects");
            assertEq(hookClaims() - claimsBefore, fee, "and minted exactly that as claims");
        } catch {
            ghostRefusedSwaps++;
            assertEq(hook.totalFees(), feesBefore, "a refused swap charges nothing");
            assertEq(hookClaims(), claimsBefore);
        }
        _snapshot();
    }

    /// @dev Records the high-water marks every action must respect.
    function _snapshot() internal {
        uint256 fees = hook.totalFees();
        uint256 spent = hook.burnSpent();
        uint256 burned = hook.imdBurned();
        assertGe(fees, maxTotalFeesSeen, "totalFees went down");
        assertGe(spent, maxBurnSpentSeen, "burnSpent went down");
        assertGe(burned, maxImdBurnedSeen, "imdBurned went down");
        maxTotalFeesSeen = fees;
        maxBurnSpentSeen = spent;
        maxImdBurnedSeen = burned;
        if (ghostRetired) assertTrue(hook.retired(), "retirement reopened");
        if (hook.retired()) ghostRetired = true;
    }

    function retire(uint8 who) external {
        address keeper = keepers[bound(who, 0, keepers.length - 1)];
        bool eligible = hook.totalFees() >= hook.CREATOR_CAP() && !hook.retired();
        uint256 creatorBefore = hook.CREATOR().balance;
        vm.prank(keeper);
        try hook.retire() {
            assertTrue(eligible, "retire succeeded when it should not have");
            ghostRetires++;
            ghostRetired = true;
            assertEq(hook.CREATOR().balance - creatorBefore, hook.CREATOR_CAP());
            assertEq(nft.ownerOf(447), hook.DEAD());
            assertEq(keeper.balance, 0, "the caller gets nothing");
        } catch (bytes memory reason) {
            assertFalse(eligible, "retire refused while eligible");
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == MedallionHook.NotRecouped.selector || sel == MedallionHook.AlreadyRetired.selector,
                "unexpected retire refusal"
            );
            assertEq(hook.CREATOR().balance, creatorBefore);
        }
        _snapshot();
    }

    function burn(uint8 who, bool viaPool4, uint8 blocks) external {
        vm.roll(block.number + bound(blocks, 0, 8));
        address keeper = keepers[bound(who, 0, keepers.length - 1)];
        (bool open,) = hook.pool4Reference();
        uint256 burnableBefore = hook.burnable();
        uint256 spentBefore = hook.burnSpent();
        uint256 imdBefore = hook.imdBurned();
        uint256 deadBefore = imdBalance(hook.DEAD());
        uint256 claimsBefore = hookClaims();
        uint256 anchorBlockBefore = hook.anchorBlock();

        vm.prank(keeper);
        try hook.burnIMD(viaPool4, 0) returns (uint256 out) {
            uint256 batch = hook.burnSpent() - spentBefore;
            uint256 cap = open ? hook.MAX_BURN_BATCH() : hook.FALLBACK_BURN_BATCH();
            assertEq(batch, burnableBefore < cap ? burnableBefore : cap, "batch is min(burnable, cap)");
            assertGe(batch, hook.MIN_BURN());
            assertGe(block.number, ghostLastBurnBlock + hook.MIN_BLOCKS_BETWEEN_BURNS(), "burn spacing");
            assertEq(hook.imdBurned() - imdBefore, out);
            assertEq(imdBalance(hook.DEAD()) - deadBefore, out, "every token reaches the sink");
            assertEq(claimsBefore - hookClaims(), batch, "exactly the batch of claims was spent");
            assertEq(keeper.balance, 0);
            assertEq(imdBalance(keeper), 0);
            if (!open) assertFalse(viaPool4, "fallback mode never uses POOL4");
            ghostBurnSpent += batch;
            ghostImdOut += out;
            ghostBurns++;
            if (!open) ghostFallbackBurns++;
            ghostLastBurnBlock = block.number;
        } catch {
            ghostRefusedBurns++;
            assertEq(hook.burnSpent(), spentBefore, "a refused burn spends nothing");
            assertEq(hook.imdBurned(), imdBefore);
            assertEq(hookClaims(), claimsBefore);
            assertEq(hook.anchorBlock(), anchorBlockBefore, "a refused burn does not move the anchor");
        }
        _snapshot();
    }

    function poke(uint8 blocks) external {
        vm.roll(block.number + bound(blocks, 0, 3));
        int24 anchorBefore = hook.anchor();
        uint256 anchorBlockBefore = hook.anchorBlock();
        (bool open, int24 ref) = hook.pool4Reference();
        try hook.pokeAnchor() {
            if (open) {
                assertEq(hook.anchor(), ref);
                assertEq(hook.lastRef(), ref);
                assertEq(hook.blockAnchor(), ref);
            } else if (anchorBlockBefore == block.number) {
                assertEq(hook.anchor(), anchorBefore, "one step per block");
            } else {
                int24 moved = hook.anchor() - anchorBefore;
                assertLe(moved, hook.ANCHOR_STEP());
                assertGe(moved, -hook.ANCHOR_STEP());
                assertEq(hook.blockAnchor(), anchorBefore, "blockAnchor is the value before the step");
            }
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), MedallionHook.Pool4Unavailable.selector);
            assertFalse(open);
            assertFalse(hook.anchorSeeded());
        }
        _snapshot();
    }

    function togglePool4(bool open, int24 ref) external {
        pool4Mock.setMarketOpen(open);
        pool4Mock.setRefTick(int24(bound(int256(ref), -400, 400)));
    }

    function movePlainPool(bool up, uint256 amountIn) external {
        amountIn = bound(amountIn, 0.01 ether, 30 ether);
        if (!up) vm.deal(address(this), address(this).balance + amountIn);
        pushPlainSpot(up, amountIn);
        _snapshot();
    }

    // ------------------------------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------------------------------

    /// @dev The pool's own ETH delta for the last swap, read from the PoolManager's Swap event, which
    /// is emitted before the hook's delta is applied.
    function poolGrossEth() internal returns (uint256 gross) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_TOPIC) continue;
            if (logs[i].topics[1] != PoolId.unwrap(poolId)) continue;
            (int128 amount0,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            gross = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
            found = true;
        }
        require(found, "no Swap event");
    }

    function manager_() external view returns (PoolManager) {
        return manager;
    }

    function hook_() external view returns (MedallionHook) {
        return hook;
    }

    function token_() external view returns (FareToken) {
        return token;
    }

    function imdHeldBy(address who) external view returns (uint256) {
        return imdBalance(who);
    }

    function plainSpot() external view returns (int24) {
        return currentTick(plainKey);
    }

    function fareSupplyAccountedFor() external view returns (uint256 sum) {
        sum = token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(address(hook));
        for (uint256 i = 0; i < traders.length; i++) {
            sum += token.balanceOf(traders[i]);
        }
    }
}

/// @notice Properties that must hold after any sequence of swaps, burns, pokes, retirements, POOL4
/// outages and plain-pool moves.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract MedallionLedgerInvariantTest is Test {
    LedgerHandler internal handler;
    MedallionHook internal hook;
    PoolManager internal manager;
    FareToken internal token;

    function setUp() public {
        handler = new LedgerHandler();
        handler.setUp();
        hook = handler.hook_();
        manager = handler.manager_();
        token = handler.token_();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LedgerHandler.swap.selector;
        selectors[1] = LedgerHandler.retire.selector;
        selectors[2] = LedgerHandler.burn.selector;
        selectors[3] = LedgerHandler.poke.selector;
        selectors[4] = LedgerHandler.togglePool4.selector;
        selectors[5] = LedgerHandler.movePlainPool.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Conservation: with no donations the claims equal the ledger exactly, and the manager's
    /// ETH backs them.
    function invariant_claimsEqualTheLedgerAndAreBacked() public view {
        uint256 claims = manager.balanceOf(address(hook), 0);
        assertEq(claims, hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        assertEq(claims, hook.reservedClaims());
        assertGe(address(manager).balance, claims);
    }

    /// @dev The hook's fees are exactly what the PoolManager's own swap events imply.
    function invariant_totalFeesMatchTheGhostLedger() public view {
        assertEq(hook.totalFees(), handler.ghostFees());
        assertEq(hook.burnSpent(), handler.ghostBurnSpent());
        assertEq(hook.imdBurned(), handler.ghostImdOut());
    }

    function invariant_countersOnlyGrowAndRetirementIsFinal() public {
        assertGe(hook.totalFees(), handler.maxTotalFeesSeen());
        assertGe(hook.burnSpent(), handler.maxBurnSpentSeen());
        assertGe(hook.imdBurned(), handler.maxImdBurnedSeen());
        if (handler.ghostRetired()) assertTrue(hook.retired(), "retirement reopened");
        assertLe(handler.ghostRetires(), 1);
        assertLe(hook.lastBurnBlock(), block.number);
    }

    function invariant_creatorIsPaidOnceExactlyTheCapAndOnlyByRetire() public view {
        uint256 paid = hook.creatorPaid();
        assertTrue(paid == 0 || paid == hook.CREATOR_CAP());
        assertEq(paid == hook.CREATOR_CAP(), hook.retired());
        assertEq(hook.CREATOR().balance, paid);
        if (hook.retired()) {
            assertGe(hook.totalFees(), hook.CREATOR_CAP());
            assertEq(handler.nft().ownerOf(447), hook.DEAD());
        } else {
            assertEq(handler.nft().ownerOf(447), handler.nftOwner());
        }
    }

    function invariant_burnableFormulaAndTheCapIsAlwaysBacked() public view {
        uint256 fees = hook.totalFees();
        uint256 entitlement = fees < hook.CREATOR_CAP() ? fees : hook.CREATOR_CAP();
        assertEq(hook.creatorEntitlement(), entitlement);
        assertEq(hook.burnable(), fees - entitlement - hook.burnSpent());
        assertLe(hook.burnSpent() + entitlement, fees);
        if (!hook.retired()) assertGe(manager.balanceOf(address(hook), 0), entitlement, "the entitlement is backed");
    }

    function invariant_everyBoughtImdIsAtTheSinkAndTheHookHoldsNothing() public view {
        assertEq(handler.imdHeldBy(hook.DEAD()), hook.imdBurned());
        assertEq(handler.imdHeldBy(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(hook.IMD()))), 0);
    }

    function invariant_anchorStaysInsideItsBounds() public view {
        if (!hook.anchorSeeded()) return;
        int24 anchor = hook.anchor();
        assertGe(anchor, TickMath.MIN_TICK);
        assertLe(anchor, TickMath.MAX_TICK);
        assertLe(anchor - hook.lastRef(), hook.FALLBACK_BAND());
        assertGe(anchor - hook.lastRef(), -hook.FALLBACK_BAND());
        assertLe(anchor - hook.blockAnchor(), hook.ANCHOR_STEP());
        assertGe(anchor - hook.blockAnchor(), -hook.ANCHOR_STEP());
        assertLe(hook.anchorBlock(), block.number);
        assertLe(hook.lastRefBlock(), hook.anchorBlock());
    }

    function invariant_fareSupplyIsFixedAndAccountedFor() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(handler.fareSupplyAccountedFor(), 1e27);
    }

    function invariant_statusFollowsTheState() public view {
        bytes memory s = bytes(hook.status());
        bytes memory expected = hook.retired()
            ? bytes("RETIRED.")
            : (hook.totalFees() >= hook.CREATOR_CAP() ? bytes("RECOUPED, NOT RETIRED.") : bytes("IN SERVICE."));
        bytes memory head = new bytes(expected.length);
        for (uint256 i = 0; i < expected.length; i++) {
            head[i] = s[i];
        }
        assertEq(head, expected);
    }
}
