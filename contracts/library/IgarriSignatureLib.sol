// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

library IgarriSignatureLib {
    // --- TypeHashes ---
    bytes32 private constant BUY_SHARES_TYPEHASH = keccak256("BuyShares(address buyer,bool isYes,uint256 shareAmount,uint256 nonce,uint256 deadline)");
    bytes32 private constant OPEN_POSITION_TYPEHASH = keccak256("OpenPosition(address trader,bool isYes,uint256 collateral,uint256 leverage,uint256 minShares,uint256 nonce,uint256 deadline)");
    bytes32 private constant CLOSE_POSITION_TYPEHASH = keccak256("ClosePosition(address trader,bool isYes,uint256 minUSDCReturned,uint256 nonce,uint256 deadline)");
    bytes32 private constant BULK_LIQUIDATE_TYPEHASH = keccak256("BulkLiquidate(bytes32 payloadHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant CLAIM_TIER_TYPEHASH = keccak256("ClaimTier(address user,uint8 tier,uint256 nonce,uint256 deadline)");
    
    bytes32 private constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256(bytes("IgarriMarket"));
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

    function _hashTypedDataV4(bytes32 structHash, address verifyingContract) private view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, verifyingContract));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function verifyBuyShares(address verifyingContract, address buyer, bool isYes, uint256 shareAmount, uint256 nonce, uint256 deadline, bytes calldata userSig, bytes calldata serverSig, address serverSigner) external view {
        bytes32 structHash = keccak256(abi.encode(BUY_SHARES_TYPEHASH, buyer, isYes, shareAmount, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash, verifyingContract);
        require(ECDSA.recover(digest, userSig) == buyer && ECDSA.recover(digest, serverSig) == serverSigner, "Invalid Signature");
    }

    function verifyOpenPosition(address verifyingContract, address trader, bool isYes, uint256 collateral, uint256 leverage, uint256 minSharesExpected, uint256 nonce, uint256 deadline, bytes calldata userSig, bytes calldata serverSig, address serverSigner) external view {
        bytes32 structHash = keccak256(abi.encode(OPEN_POSITION_TYPEHASH, trader, isYes, collateral, leverage, minSharesExpected, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash, verifyingContract);
        require(ECDSA.recover(digest, userSig) == trader && ECDSA.recover(digest, serverSig) == serverSigner, "Invalid Signature");
    }

    function verifyClosePosition(address verifyingContract, address trader, bool isYes, uint256 minUSDCReturned, uint256 nonce, uint256 deadline, bytes calldata userSig, bytes calldata serverSig, address serverSigner) external view {
        bytes32 structHash = keccak256(abi.encode(CLOSE_POSITION_TYPEHASH, trader, isYes, minUSDCReturned, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash, verifyingContract);
        require(ECDSA.recover(digest, userSig) == trader && ECDSA.recover(digest, serverSig) == serverSigner, "Invalid Signature");
    }

    function verifyBulkLiquidate(address verifyingContract, address[] calldata traders, bool[] calldata isYesSides, uint256 nonce, uint256 deadline, bytes calldata serverSig, address serverSigner) external view {
        bytes32 payloadHash = keccak256(abi.encode(traders, isYesSides));
        bytes32 structHash = keccak256(abi.encode(BULK_LIQUIDATE_TYPEHASH, payloadHash, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash, verifyingContract);
        require(ECDSA.recover(digest, serverSig) == serverSigner, "Invalid Signature");
    }

    function verifyClaimTier(address verifyingContract, address user, uint8 tier, uint256 nonce, uint256 deadline, bytes calldata serverSig, address serverSigner) external view {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TIER_TYPEHASH, user, tier, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash, verifyingContract);
        require(ECDSA.recover(digest, serverSig) == serverSigner, "Invalid Signature");
    }
}