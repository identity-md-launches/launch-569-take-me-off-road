// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {MedallionTestBase} from "./utils/MedallionTestBase.sol";
import {MockMedallion, ReentrantMedallion, RawAnswer} from "./mocks/MockMedallion.sol";

/// @notice retire(): the one transaction that moves medallion #447 to DEAD and pays CREATOR 1.64 ETH.
contract MedallionRetireTest is MedallionTestBase {
    event MedallionRetired(address indexed from);
    event CreatorPaid(address indexed creator, uint256 amount);
    event LastFare(uint256 indexed tokenId, bytes32 indexed hash, string fare);

    address internal medallionOwner = makeAddr("medallionOwner");
    address internal stranger = makeAddr("stranger");
    MockMedallion internal nft;

    function etchMedallion(address owner) internal {
        MockMedallion impl = new MockMedallion();
        vm.etch(hook.MEDALLION_NFT(), address(impl).code);
        nft = MockMedallion(hook.MEDALLION_NFT());
        nft.mint(owner, 447);
    }

    function test_retireRevertsBeforeTheCap() public {
        buyExactIn(81 ether); // 1.62 ETH
        etchMedallion(medallionOwner);
        vm.prank(medallionOwner);
        nft.approve(address(hook), 447);
        vm.expectRevert(MedallionHook.NotRecouped.selector);
        hook.retire();
        assertEq(hook.totalFees(), 1.62 ether);
    }

    function test_retireRevertsWhenTheMedallionHasNoCode() public {
        reachCap();
        assertEq(hook.MEDALLION_NFT().code.length, 0, "Sepolia-like: no medallion contract");
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
    }

    function test_retireRevertsOnABadOwnerOfAnswer() public {
        reachCap();
        RawAnswer raw = new RawAnswer();
        vm.etch(hook.MEDALLION_NFT(), address(raw).code);
        RawAnswer at = RawAnswer(payable(hook.MEDALLION_NFT()));

        at.setAnswer(bytes4(0x6352211e), hex"01");
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();

        at.setAnswer(bytes4(0x6352211e), abi.encode(uint256(type(uint160).max) + 1));
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();

        at.setRevert(bytes4(0x6352211e));
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
    }

    function test_retireWithoutApprovalIsRefusedAndChangesNothing() public {
        reachCap();
        etchMedallion(medallionOwner);
        uint256 claimsBefore = hookClaims();
        vm.expectRevert(
            abi.encodeWithSelector(
                MedallionHook.RetireRefused.selector, abi.encodeWithSelector(MockMedallion.NotApproved.selector)
            )
        );
        hook.retire();
        assertEq(nft.ownerOf(447), medallionOwner);
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.CREATOR().balance, 0);
        assertEq(hookClaims(), claimsBefore);
        assertEq(
            hook.status(),
            "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447."
        );
    }

    function test_retireIsRefusedWhenTheTransferSilentlyDoesNothing() public {
        reachCap();
        etchMedallion(medallionOwner);
        nft.setSilentRefuse(true);
        vm.prank(medallionOwner);
        nft.approve(address(hook), 447);
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.RetireRefused.selector, bytes("")));
        hook.retire();
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
    }

    function test_retireMovesTheMedallionPaysTheCreatorAndEmitsInOneTransaction() public {
        reachCap();
        buyExactIn(10 ether); // 0.2 ETH above the cap stays for burns
        etchMedallion(medallionOwner);
        vm.prank(medallionOwner);
        nft.setApprovalForAll(address(hook), true);

        uint256 claimsBefore = hookClaims();
        uint256 managerEthBefore = address(manager).balance;

        vm.expectEmit(true, false, false, true, address(hook));
        emit MedallionRetired(medallionOwner);
        vm.expectEmit(true, false, false, true, address(hook));
        emit CreatorPaid(hook.CREATOR(), 1.64 ether);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LastFare(447, hook.LAST_FARE_HASH(), hook.LAST_FARE());

        vm.prank(stranger); // permissionless
        hook.retire();

        assertEq(nft.ownerOf(447), hook.DEAD());
        assertEq(hook.CREATOR().balance, 1.64 ether, "exactly the cap, nothing more");
        assertTrue(hook.retired());
        assertEq(hook.creatorPaid(), 1.64 ether);
        assertEq(hookClaims(), claimsBefore - 1.64 ether);
        assertEq(address(manager).balance, managerEthBefore - 1.64 ether);
        assertEq(hook.totalFees(), 1.84 ether);
        assertEq(hook.burnable(), 0.2 ether);
        assertEq(hookClaims(), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        assertEq(stranger.balance, 0, "the caller gets nothing");
        assertEq(
            hook.status(),
            "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: 0.0."
        );
    }

    function test_retireCannotRunTwice() public {
        reachCap();
        etchMedallion(medallionOwner);
        vm.prank(medallionOwner);
        nft.approve(address(hook), 447);
        hook.retire();
        vm.expectRevert(MedallionHook.AlreadyRetired.selector);
        hook.retire();
        assertEq(hook.CREATOR().balance, 1.64 ether);
    }

    function test_retireSkipsTheTransferWhenTheMedallionIsAlreadyDead() public {
        reachCap();
        etchMedallion(hook.DEAD());
        vm.recordLogs();
        hook.retire();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != keccak256("MedallionRetired(address)"), "no transfer happened");
        }
        assertTrue(hook.retired());
        assertEq(hook.CREATOR().balance, 1.64 ether);
    }

    function test_retireFeesKeepAccruingAfterRetirement() public {
        reachCap();
        etchMedallion(medallionOwner);
        vm.prank(medallionOwner);
        nft.approve(address(hook), 447);
        hook.retire();
        buyExactIn(1 ether);
        assertEq(hook.totalFees(), 1.66 ether);
        assertEq(hook.burnable(), 0.02 ether);
        assertEq(hookClaims(), 0.02 ether);
        assertEq(hook.CREATOR().balance, 1.64 ether, "no second payment, ever");
    }

    function test_retireIsGuardedAgainstReentrancyFromTheMedallion() public {
        reachCap();
        ReentrantMedallion impl = new ReentrantMedallion(address(hook), medallionOwner);
        vm.etch(hook.MEDALLION_NFT(), address(impl).code);
        // The etched copy's storage is empty: set the owner slot and hook slot by re-deploying state.
        vm.store(hook.MEDALLION_NFT(), bytes32(uint256(0)), bytes32(uint256(uint160(address(hook)))));
        vm.store(hook.MEDALLION_NFT(), bytes32(uint256(1)), bytes32(uint256(uint160(medallionOwner))));

        vm.expectRevert(
            abi.encodeWithSelector(
                MedallionHook.RetireRefused.selector, abi.encodeWithSelector(MedallionHook.Reentrancy.selector)
            )
        );
        hook.retire();
        assertFalse(hook.retired());
        assertEq(hook.CREATOR().balance, 0);
    }

    function test_creatorPaidIsZeroOrCap() public {
        assertEq(hook.creatorPaid(), 0);
        reachCap();
        assertEq(hook.creatorPaid(), 0);
        etchMedallion(medallionOwner);
        vm.prank(medallionOwner);
        nft.approve(address(hook), 447);
        hook.retire();
        assertEq(hook.creatorPaid(), hook.CREATOR_CAP());
    }
}
