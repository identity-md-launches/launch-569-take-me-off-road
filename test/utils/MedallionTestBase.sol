// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {FareToken} from "../../src/FareToken.sol";
import {MedallionHook} from "../../src/MedallionHook.sol";
import {HookMiner} from "./HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPool4Hook} from "../mocks/MockPool4Hook.sol";

/// @notice Shared fixture: a fresh PoolManager, the two v4-core test routers, the FARE447 token, a hook
/// deployed with a mined salt, and the ETH/FARE447 launch pool seeded full range at 1:1.
abstract contract MedallionTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = 0x10CC;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant LAUNCH_FEE = 3000;
    int24 internal constant LAUNCH_SPACING = 60;
    int24 internal constant FULL_LOWER_60 = -887220;
    int24 internal constant FULL_UPPER_60 = 887220;
    int24 internal constant FULL_LOWER_200 = -887200;
    int24 internal constant FULL_UPPER_200 = 887200;
    uint256 internal constant LAUNCH_LIQUIDITY = 2_000 ether;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    FareToken internal token;
    MedallionHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;

    receive() external payable {}

    function setUp() public virtual {
        vm.deal(address(this), 10_000_000 ether);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        token = new FareToken();
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);

        hook = deployHook(manager);
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LAUNCH_FEE,
            tickSpacing: LAUNCH_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        addLiquidity(key, FULL_LOWER_60, FULL_UPPER_60, int256(LAUNCH_LIQUIDITY), LAUNCH_LIQUIDITY);
    }

    // ------------------------------------------------------------------------------------------
    // Deployment helpers
    // ------------------------------------------------------------------------------------------

    uint256 internal saltCursor;

    /// @dev Each deployment starts mining after the previous salt so two hooks on the same manager
    /// never collide on the same CREATE2 address.
    function deployHook(IPoolManager pm) internal returns (MedallionHook deployed) {
        bytes memory initCode = abi.encodePacked(type(MedallionHook).creationCode, abi.encode(pm));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FLAGS, initCode, saltCursor);
        saltCursor = uint256(salt) + 1;
        deployed = new MedallionHook{salt: salt}(pm);
        require(address(deployed) == predicted, "hook landed elsewhere");
    }

    function addLiquidity(PoolKey memory k, int24 lower, int24 upper, int256 liquidity, uint256 ethToSend)
        internal
        returns (BalanceDelta)
    {
        return lpRouter.modifyLiquidity{value: ethToSend}(
            k, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: 0}), ""
        );
    }

    // ------------------------------------------------------------------------------------------
    // Swap helpers (launch pool unless a key is given)
    // ------------------------------------------------------------------------------------------

    function swapOn(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 limit, uint256 ethToSend)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap{value: ethToSend}(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Exact-in buy: `ethIn` ETH in, FARE447 out.
    function buyExactIn(uint256 ethIn) internal returns (BalanceDelta) {
        return swapOn(key, true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1, ethIn);
    }

    /// @dev Exact-out buy: `tokensOut` FARE447 out, ETH in. `maxEth` is sent and the rest refunded.
    function buyExactOut(uint256 tokensOut, uint256 maxEth) internal returns (BalanceDelta) {
        return swapOn(key, true, int256(tokensOut), TickMath.MIN_SQRT_PRICE + 1, maxEth);
    }

    /// @dev Exact-in sell: `tokensIn` FARE447 in, ETH out.
    function sellExactIn(uint256 tokensIn) internal returns (BalanceDelta) {
        return swapOn(key, false, -int256(tokensIn), TickMath.MAX_SQRT_PRICE - 1, 0);
    }

    /// @dev Exact-out sell: `ethOut` ETH out, FARE447 in.
    function sellExactOut(uint256 ethOut) internal returns (BalanceDelta) {
        return swapOn(key, false, int256(ethOut), TickMath.MAX_SQRT_PRICE - 1, 0);
    }

    /// @dev Pushes totalFees to exactly CREATOR_CAP with one 82 ETH exact-in buy.
    function reachCap() internal {
        buyExactIn(82 ether);
        assertEq(hook.totalFees(), hook.CREATOR_CAP(), "cap not reached exactly");
    }

    function hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), 0);
    }

    function currentTick(PoolKey memory k) internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(k.toId());
    }

    // ------------------------------------------------------------------------------------------
    // Revert encoding
    // ------------------------------------------------------------------------------------------

    /// @dev The PoolManager wraps a hook revert in ERC-7751 WrappedError(target, selector, reason, details).
    function wrappedHookRevert(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ------------------------------------------------------------------------------------------
    // IMD pools (POOL4 and plain) on this manager
    // ------------------------------------------------------------------------------------------

    MockPool4Hook internal pool4Mock;
    PoolKey internal pool4Key;
    PoolKey internal plainKey;

    /// @dev Etches a mintable ERC-20 at IMD and the POOL4 mock at POOL4_HOOK, opens the market with
    /// `refTick`, initializes both fixed pools at 1:1 and seeds each with `liquidity` full range.
    function setUpIMD(int24 refTick, uint256 liquidity) internal {
        etchIMD();
        etchPool4(true, refTick);
        pool4Key = hook.pool4Key();
        plainKey = hook.plainKey();
        manager.initialize(pool4Key, SQRT_PRICE_1_1);
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        addLiquidity(pool4Key, FULL_LOWER_60, FULL_UPPER_60, int256(liquidity), liquidity);
        addLiquidity(plainKey, FULL_LOWER_200, FULL_UPPER_200, int256(liquidity), liquidity);
    }

    function etchIMD() internal {
        MockERC20 impl = new MockERC20("IMD", "IMD");
        vm.etch(hook.IMD(), address(impl).code);
        MockERC20(hook.IMD()).mint(address(this), 1_000_000_000 ether);
        MockERC20(hook.IMD()).approve(address(lpRouter), type(uint256).max);
        MockERC20(hook.IMD()).approve(address(swapRouter), type(uint256).max);
    }

    function etchPool4(bool open, int24 refTick) internal {
        MockPool4Hook impl = new MockPool4Hook();
        vm.etch(hook.POOL4_HOOK(), address(impl).code);
        pool4Mock = MockPool4Hook(hook.POOL4_HOOK());
        pool4Mock.setMarketOpen(open);
        pool4Mock.setRefTick(refTick);
    }

    function imdBalance(address who) internal view returns (uint256) {
        return MockERC20(hook.IMD()).balanceOf(who);
    }

    /// @dev Moves the plain pool's spot tick. The tick is log(IMD per ETH): selling IMD into the pool
    /// (oneForZero) pushes it up, buying IMD with ETH (zeroForOne) pushes it down.
    function pushPlainSpot(bool up, uint256 amountIn) internal {
        if (up) {
            swapOn(plainKey, false, -int256(amountIn), TickMath.MAX_SQRT_PRICE - 1, 0);
        } else {
            swapOn(plainKey, true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1, amountIn);
        }
    }

    struct BurnLog {
        bool viaPool4;
        bool fallbackMode;
        uint256 ethIn;
        uint256 imdOut;
        int24 refTick;
        int24 spot;
    }

    /// @dev The last IMDBurned event in the recorded logs.
    function lastBurnLog() internal returns (BurnLog memory log_) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != keccak256("IMDBurned(bool,bool,uint256,uint256,int24,int24)")) continue;
            found = true;
            log_.viaPool4 = uint256(logs[i].topics[1]) == 1;
            log_.fallbackMode = uint256(logs[i].topics[2]) == 1;
            (log_.ethIn, log_.imdOut, log_.refTick, log_.spot) =
                abi.decode(logs[i].data, (uint256, uint256, int24, int24));
        }
        require(found, "no IMDBurned event");
    }

    // ------------------------------------------------------------------------------------------
    // Formatting mirror for status() assertions
    // ------------------------------------------------------------------------------------------

    function formatEther(uint256 value, uint256 places) internal pure returns (string memory) {
        uint256 whole = value / 1 ether;
        uint256 frac = (value % 1 ether) / (10 ** (18 - places));
        bytes memory digits = new bytes(places);
        for (uint256 i = places; i > 0; i--) {
            digits[i - 1] = bytes1(uint8(48 + frac % 10));
            frac /= 10;
        }
        return string.concat(vm.toString(whole), ".", string(digits));
    }
}
