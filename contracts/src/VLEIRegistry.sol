// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IVLEIRegistry} from "./interfaces/IVLEIRegistry.sol";

/// @title VLEIRegistry
/// @notice Stores the result of an off-chain vLEI verification per wallet.
///         A registration is created from an EIP-712 attestation signed by an
///         address holding VERIFIER_ROLE. Anyone may relay the attestation, but
///         only the bound wallet is registered.
/// @dev Role separation:
///      - DEFAULT_ADMIN_ROLE: revocation, verifier rotation (grant/revoke VERIFIER_ROLE).
///      - VERIFIER_ROLE: its signatures are accepted for registration. Nothing else.
contract VLEIRegistry is IVLEIRegistry, AccessControl, EIP712 {
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    /// @dev Credential roles. Ordered so that `role >= minRole` means "at least".
    uint8 public constant ROLE_NONE = 0;
    uint8 public constant ROLE_ECR = 1; //          Engagement Context Role: buy / hold / receive
    uint8 public constant ROLE_OOR = 2; //          Official Organizational Role: buy / hold / receive
    uint8 public constant ROLE_OOR_OFFICER = 3; //  OOR with an authorized official role: may also create pools

    bytes32 public constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(address wallet,bytes32 leiHash,uint8 role,uint256 nonce,uint64 expiresAt)");

    struct Attestation {
        address wallet;
        bytes32 leiHash;
        uint8 role;
        uint256 nonce;
        uint64 expiresAt;
    }

    struct Registration {
        bytes32 leiHash;
        uint8 role;
        uint64 expiresAt;
        uint64 registeredAt;
        address verifier;
    }

    mapping(address => Registration) private _registrations;
    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public entityRevoked;
    mapping(address => bool) public walletRevoked;

    /// @notice Upper bound on attestation lifetime, so a leaked attestation cannot be valid forever.
    uint64 public maxAttestationTtl = 30 days;

    event Registered(address indexed wallet, bytes32 indexed leiHash, uint8 role, uint64 expiresAt, address verifier);
    event EntityRevoked(bytes32 indexed leiHash, string reason);
    event EntityReinstated(bytes32 indexed leiHash);
    event WalletRevoked(address indexed wallet, string reason);
    event MaxAttestationTtlUpdated(uint64 ttl);

    error InvalidRole();
    error InvalidNonce();
    error AttestationExpired();
    error TtlTooLong();
    error InvalidSigner(address recovered);
    error EntityIsRevoked();
    error ZeroAddress();

    constructor(address admin, address verifier) EIP712("vLEI-Gate Registry", "1") {
        if (admin == address(0) || verifier == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VERIFIER_ROLE, verifier);
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    function hashAttestation(Attestation calldata att) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(ATTESTATION_TYPEHASH, att.wallet, att.leiHash, att.role, att.nonce, att.expiresAt))
        );
    }

    function register(Attestation calldata att, bytes calldata signature) external {
        if (att.wallet == address(0)) revert ZeroAddress();
        if (att.role == ROLE_NONE || att.role > ROLE_OOR_OFFICER) revert InvalidRole();
        if (att.nonce != nonces[att.wallet]) revert InvalidNonce();
        if (att.expiresAt <= block.timestamp) revert AttestationExpired();
        if (att.expiresAt > block.timestamp + maxAttestationTtl) revert TtlTooLong();
        if (entityRevoked[att.leiHash]) revert EntityIsRevoked();

        address signer = ECDSA.recover(hashAttestation(att), signature);
        if (!hasRole(VERIFIER_ROLE, signer)) revert InvalidSigner(signer);

        unchecked {
            nonces[att.wallet] = att.nonce + 1;
        }
        _registrations[att.wallet] = Registration({
            leiHash: att.leiHash,
            role: att.role,
            expiresAt: att.expiresAt,
            registeredAt: uint64(block.timestamp),
            verifier: signer
        });
        // A fresh verifier attestation supersedes an earlier wallet-level revocation.
        walletRevoked[att.wallet] = false;

        emit Registered(att.wallet, att.leiHash, att.role, att.expiresAt, signer);
    }

    // ------------------------------------------------------------------
    // Revocation (admin only)
    // ------------------------------------------------------------------

    /// @notice Revoke every wallet of an entity, e.g. after a watcher detects a TEL revocation.
    function revokeEntity(bytes32 leiHash, string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        entityRevoked[leiHash] = true;
        emit EntityRevoked(leiHash, reason);
    }

    function reinstateEntity(bytes32 leiHash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        entityRevoked[leiHash] = false;
        emit EntityReinstated(leiHash);
    }

    /// @notice Revoke a single representative's wallet (e.g. OOR/ECR credential revoked).
    function revokeWallet(address wallet, string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        walletRevoked[wallet] = true;
        // Invalidate any attestation already issued for this wallet but not yet submitted,
        // so a stockpiled attestation cannot undo the revocation.
        unchecked {
            nonces[wallet]++;
        }
        emit WalletRevoked(wallet, reason);
    }

    function setMaxAttestationTtl(uint64 ttl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxAttestationTtl = ttl;
        emit MaxAttestationTtlUpdated(ttl);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getRegistration(address wallet) external view returns (Registration memory) {
        return _registrations[wallet];
    }

    function leiHashOf(address wallet) external view returns (bytes32) {
        return _registrations[wallet].leiHash;
    }

    function isActive(address wallet) public view returns (bool) {
        Registration storage r = _registrations[wallet];
        return r.role != ROLE_NONE && !walletRevoked[wallet] && !entityRevoked[r.leiHash]
            && block.timestamp < r.expiresAt;
    }

    function isActiveWithRole(address wallet, uint8 minRole) public view returns (bool) {
        return isActive(wallet) && _registrations[wallet].role >= minRole;
    }

    /// @notice Pool creation requires an OOR credential with an authorized official role.
    ///         ECR roles are free text set by the entity, so ECR never grants launch rights.
    function canLaunch(address wallet) external view returns (bool) {
        return isActiveWithRole(wallet, ROLE_OOR_OFFICER);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
