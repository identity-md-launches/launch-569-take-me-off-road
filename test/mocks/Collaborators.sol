// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

/// @notice The contracts the hook talks to, each written to misbehave in one way. They are etched at
/// the fixed addresses (POOL4_HOOK, MEDALLION_NFT, CREATOR), so every one of them keeps its
/// configuration in storage set after the etch, never in constructor state.

/// @dev Answers every call and every plain ETH transfer with a revert.
contract Reverting {
    fallback() external payable {
        revert("Reverting: touched");
    }

    receive() external payable {
        revert("Reverting: eth");
    }
}

/// @dev A POOL4 hook whose afterSwap, called by the PoolManager while the MedallionHook's burn swap
/// is in flight, makes one configurable call back into the MedallionHook and bubbles its revert.
/// `payload` empty means afterSwap simply reverts.
contract ReentrantPool4Hook {
    bool public marketOpen;
    int24 public refTick;
    address public target;
    bytes public payload;
    bool public plainRevert;

    function setMarketOpen(bool open) external {
        marketOpen = open;
    }

    function setRefTick(int24 tick) external {
        refTick = tick;
    }

    function setReentry(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function setPlainRevert(bool value) external {
        plainRevert = value;
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
        returns (bytes4, int128)
    {
        if (plainRevert) revert("pool4: closed for business");
        if (target != address(0)) {
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return (IHooks.afterSwap.selector, 0);
    }
}

/// @dev Code at CREATOR that refuses ETH.
contract EthRejectingCreator {
    receive() external payable {
        revert("creator: no");
    }
}

/// @dev Code at CREATOR whose receive re-enters retire() and bubbles the result.
contract ReenteringCreator {
    address public hook;

    function setHook(address hook_) external {
        hook = hook_;
    }

    receive() external payable {
        (bool ok, bytes memory ret) = hook.call(abi.encodeWithSignature("retire()"));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @dev A medallion whose transferFrom runs one configurable call before (optionally) moving the token.
/// With `payload` aimed at the hook it checks the transient lock; with `swapRouter` set it trades on
/// the launch pool while retire() is in flight.
contract CallbackMedallion {
    mapping(uint256 => address) internal _owner;
    address public target;
    bytes public payload;
    PoolSwapTest public swapRouter;
    PoolKey internal _key;
    bool public keySet;

    receive() external payable {}

    function mint(address to, uint256 tokenId) external {
        _owner[tokenId] = to;
    }

    function setCall(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function setSwap(PoolSwapTest router, PoolKey calldata key) external {
        swapRouter = router;
        _key = key;
        keySet = true;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owner[tokenId];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owner[tokenId] == from, "not owner");
        if (target != address(0)) {
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        if (keySet) {
            swapRouter.swap{value: 1 ether}(
                _key,
                SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        _owner[tokenId] = to;
    }
}

/// @dev Calls PoolManager.unlock with the hook's own payload shape and records where the callback lands.
contract UnlockProbe is IUnlockCallback {
    IPoolManager public immutable manager;
    uint256 public callbacks;
    bytes public lastData;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function probe(bytes calldata data) external returns (bytes memory) {
        return manager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        callbacks++;
        lastData = data;
        return "";
    }
}
