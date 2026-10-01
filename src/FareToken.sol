// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Fare for Medallion 447 (FARE447)
/// @notice The launch token beside `MedallionHook`. A fixed-supply, self-contained ERC-20: the whole
/// supply of 1,000,000,000 tokens (1e27 minor units, 18 decimals) is minted once to the deployer in the
/// constructor and nothing can ever mint again. Holders may burn their own balance or a balance they
/// were approved for.
/// @dev No owner, no minter, no pause, no blocklist, no fee on transfer, no proxy, no hooks on
/// transfer. The 2% ETH fee of the launch lives in the hook, never in this token.
contract FareToken {
    string public constant name = "Fare for Medallion 447";
    string public constant symbol = "FARE447";
    uint8 public constant decimals = 18;

    /// @notice The whole supply, minted once to the deployer.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error InvalidReceiver(address receiver);
    error InvalidSpender(address spender);

    /// @notice Mints exactly `INITIAL_SUPPLY` to `msg.sender`, the launch factory.
    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender(spender);
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    /// @notice Destroys `value` of the caller's balance.
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    /// @notice Destroys `value` of `from`'s balance using the caller's allowance.
    function burnFrom(address from, uint256 value) external {
        _spendAllowance(from, msg.sender, value);
        _burn(from, value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert InvalidReceiver(to);
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance(from, fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            // The total supply bounds every balance, so this cannot overflow.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _burn(address from, uint256 value) internal {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance(from, fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert InsufficientAllowance(spender, current, value);
        unchecked {
            allowance[owner][spender] = current - value;
        }
    }
}
