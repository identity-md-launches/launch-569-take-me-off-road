// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Stands in for the IMD network's POOL4 hook, etched at POOL4_HOOK (0x...2840). That address
/// carries the beforeInitialize, beforeAddLiquidity and afterSwap flags, so those three callbacks must
/// answer with their selectors for the PoolManager to accept the POOL4 pool key. `marketOpen()` and
/// `refTick()` are the two views the MedallionHook reads.
contract MockPool4Hook {
    bool public marketOpen;
    int24 public refTick;

    function setMarketOpen(bool open) external {
        marketOpen = open;
    }

    function setRefTick(int24 tick) external {
        refTick = tick;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }
}
