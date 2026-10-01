// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A minimal ERC-721 standing in for the medallion collection, etched at MEDALLION_NFT in tests.
/// `silentRefuse` makes transferFrom return without moving the token, to exercise the hook's re-read of
/// ownerOf after the transfer.
contract MockMedallion {
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    bool public silentRefuse;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    error NotOwner();
    error NotApproved();

    function mint(address to, uint256 tokenId) external {
        _owner[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function setSilentRefuse(bool value) external {
        silentRefuse = value;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owner[tokenId];
        if (owner == address(0)) revert NotOwner();
        return owner;
    }

    function approve(address to, uint256 tokenId) external {
        if (_owner[tokenId] != msg.sender) revert NotOwner();
        getApproved[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        address owner = _owner[tokenId];
        if (owner != from) revert NotOwner();
        if (msg.sender != owner && getApproved[tokenId] != msg.sender && !isApprovedForAll[owner][msg.sender]) {
            revert NotApproved();
        }
        if (silentRefuse) return;
        delete getApproved[tokenId];
        _owner[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}

/// @notice A medallion contract whose transferFrom calls back into the hook's retire(), to prove the
/// transient lock holds while the NFT transfer is in flight.
contract ReentrantMedallion {
    address public hook;
    address internal _owner447;

    constructor(address hook_, address owner_) {
        hook = hook_;
        _owner447 = owner_;
    }

    function ownerOf(uint256) external view returns (address) {
        return _owner447;
    }

    function transferFrom(address, address to, uint256) external {
        (bool ok, bytes memory ret) = hook.call(abi.encodeWithSignature("retire()"));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        _owner447 = to;
    }
}

/// @notice Answers every call with a stored byte string. Etched where the hook expects a contract, it
/// exercises the length and range checks on low-level reads.
contract RawAnswer {
    mapping(bytes4 => bytes) internal _answers;
    mapping(bytes4 => bool) internal _reverts;

    function setAnswer(bytes4 selector, bytes calldata answer) external {
        _answers[selector] = answer;
        _reverts[selector] = false;
    }

    function setRevert(bytes4 selector) external {
        _reverts[selector] = true;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (_reverts[msg.sig]) revert("raw revert");
        return _answers[msg.sig];
    }
}
