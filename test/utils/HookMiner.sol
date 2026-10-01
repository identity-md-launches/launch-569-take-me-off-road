// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Mines a CREATE2 salt so the hook lands on an address whose low 14 bits are the declared
/// flags, the same way the launch deployer does.
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF;

    function find(address deployer, uint160 flags, bytes memory initCode, uint256 start)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = start; i < start + 500_000; i++) {
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, bytes32(i));
        }
        revert("HookMiner: no salt found");
    }

    function flagsOf(address a) internal pure returns (uint160) {
        return uint160(a) & FLAG_MASK;
    }
}
