// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FareToken} from "../src/FareToken.sol";

contract FareTokenTest is Test {
    FareToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new FareToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Fare for Medallion 447");
        assertEq(token.symbol(), "FARE447");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyOneBillionToDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 1e27);
        vm.prank(alice);
        FareToken fresh = new FareToken();
        assertEq(fresh.balanceOf(alice), 1e27);
    }

    function test_transfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), alice, 5 ether);
        assertTrue(token.transfer(alice, 5 ether));
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 5 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FareToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(FareToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), alice, 10 ether);
        assertTrue(token.approve(alice, 10 ether));
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 4 ether));
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.allowance(address(this), alice), 6 ether);
    }

    function test_transferFromRevertsOnInsufficientAllowance() public {
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FareToken.InsufficientAllowance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(address(this), bob, 2 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(FareToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_burnReducesSupply() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), address(0), 7 ether);
        token.burn(7 ether);
        assertEq(token.totalSupply(), 1e27 - 7 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 7 ether);
    }

    function test_burnRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FareToken.InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_burnFromUsesAllowance() public {
        token.approve(alice, 3 ether);
        vm.prank(alice);
        token.burnFrom(address(this), 2 ether);
        assertEq(token.totalSupply(), 1e27 - 2 ether);
        assertEq(token.allowance(address(this), alice), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FareToken.InsufficientAllowance.selector, alice, 1 ether, 2 ether));
        token.burnFrom(address(this), 2 ether);
    }

    function test_noMintOwnerPauseOrUpgradeSurface() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "setMinter(address)",
            "blacklist(address)",
            "setFee(uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, 1e27);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(to), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_burnFromAccounting(uint256 approved, uint256 burned) public {
        approved = bound(approved, 0, 1e27);
        burned = bound(burned, 0, 1e27);
        token.approve(alice, approved);
        vm.prank(alice);
        if (burned > approved) {
            vm.expectRevert(abi.encodeWithSelector(FareToken.InsufficientAllowance.selector, alice, approved, burned));
            token.burnFrom(address(this), burned);
        } else {
            token.burnFrom(address(this), burned);
            assertEq(token.totalSupply(), 1e27 - burned);
            assertEq(token.allowance(address(this), alice), approved - burned);
        }
    }
}
