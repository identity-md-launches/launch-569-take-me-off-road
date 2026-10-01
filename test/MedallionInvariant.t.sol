// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {MedallionHook} from "../src/MedallionHook.sol";
import {MedallionTestBase} from "./utils/MedallionTestBase.sol";
import {MockMedallion} from "./mocks/MockMedallion.sol";

/// @notice Drives random swaps in all four shapes, claim donations, retirements and burns against one
/// hook and checks the ledger after every call.
contract MedallionHandler is MedallionTestBase {
    uint256 public swaps;
    uint256 public burns;
    uint256 public retires;

    function setUp() public override {
        super.setUp();
        setUpIMD(0, 500 ether);
        MockMedallion impl = new MockMedallion();
        vm.etch(hook.MEDALLION_NFT(), address(impl).code);
        MockMedallion(hook.MEDALLION_NFT()).mint(address(this), 447);
        MockMedallion(hook.MEDALLION_NFT()).setApprovalForAll(address(hook), true);
    }

    function swap(uint8 shape, uint256 amount) external {
        shape = uint8(bound(shape, 0, 3));
        amount = bound(amount, 1e12, 20 ether);
        if (shape == 0) buyExactIn(amount);
        else if (shape == 1) sellExactOut(amount);
        else if (shape == 2) buyExactOut(amount, amount * 3 + 1 ether);
        else sellExactIn(amount);
        swaps++;
    }

    function donateClaims(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        manager.transfer(address(hook), 0, manager.balanceOf(address(this), 0));
    }

    function retire() external {
        if (hook.totalFees() < hook.CREATOR_CAP() || hook.retired()) return;
        hook.retire();
        retires++;
    }

    function burn(bool viaPool4, uint8 blocks) external {
        vm.roll(block.number + bound(blocks, 0, 7));
        if (hook.burnable() < hook.MIN_BURN()) return;
        if (block.number < hook.lastBurnBlock() + hook.MIN_BLOCKS_BETWEEN_BURNS()) return;
        hook.burnIMD(viaPool4, 0);
        burns++;
    }

    function closeOrOpenPool4(bool open, int24 ref) external {
        pool4Mock.setMarketOpen(open);
        pool4Mock.setRefTick(int24(bound(int256(ref), -300, 300)));
    }

    function manager_() external view returns (PoolManager) {
        return manager;
    }

    function hook_() external view returns (MedallionHook) {
        return hook;
    }

    function imdBalanceOfHook() external view returns (uint256) {
        return imdBalance(address(hook));
    }
}

contract MedallionInvariantTest is Test {
    MedallionHandler internal handler;
    MedallionHook internal hook;
    PoolManager internal manager;

    function setUp() public {
        handler = new MedallionHandler();
        handler.setUp();
        hook = handler.hook_();
        manager = handler.manager_();
        targetContract(address(handler));
    }

    function invariant_claimsCoverTheLedger() public view {
        assertGe(manager.balanceOf(address(hook), 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }

    function invariant_creatorPaidIsZeroOrCap() public view {
        uint256 paid = hook.creatorPaid();
        assertTrue(paid == 0 || paid == hook.CREATOR_CAP());
        assertEq(paid == hook.CREATOR_CAP(), hook.retired());
        assertEq(hook.CREATOR().balance, paid);
    }

    function invariant_burnableFollowsTheFormula() public view {
        uint256 fees = hook.totalFees();
        uint256 entitlement = fees < hook.CREATOR_CAP() ? fees : hook.CREATOR_CAP();
        assertEq(hook.creatorEntitlement(), entitlement);
        assertEq(hook.burnable(), fees - entitlement - hook.burnSpent());
        assertLe(hook.burnSpent() + entitlement, fees);
    }

    function invariant_hookNeverHoldsTokensOrEth() public view {
        assertEq(address(hook).balance, 0);
        assertEq(handler.imdBalanceOfHook(), 0);
    }
}
