// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VLEIMintConfig} from "../VLEIMintLauncher.sol";
import {VLEILauncherFactoryBaseV2} from "./VLEILauncherFactoryBaseV2.sol";
import {VLEIMintVaultLauncherV2} from "./VLEIMintVaultLauncherV2.sol";
import {IVLEIRegistry} from "../interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @notice The getters this factory reads from its paired vault factory.
interface IPairedVaultFactoryV2 {
    function launcherFactory() external view returns (address);
    function quoteToken() external view returns (address);
}

/// @title VLEIVaultLauncherFactoryV2
/// @notice v2 of `VLEIVaultLauncherFactory`: deploys `VLEIMintVaultLauncherV2`s whose VAULT slot names `vaultFactory`
///         (a `VLEIDividendVaultFactoryV2` that only serves this factory and uses the same quote asset).
contract VLEIVaultLauncherFactoryV2 is VLEILauncherFactoryBaseV2 {
    /// @notice The paired `VLEIDividendVaultFactoryV2`.
    address public immutable vaultFactory;

    event VLEIVaultLauncherCreated(
        address indexed launcher,
        address indexed creator,
        bytes32 indexed creatorLeiHash,
        bytes32 launchSalt,
        uint256 targetRaise,
        uint256 capUsdPerEntity
    );

    error VaultFactoryNotPaired(address vaultFactory);
    error VaultQuoteMismatch(address vaultQuote, address launcherQuote);

    constructor(
        address hub_,
        address guardian_,
        IVLEIRegistry registry_,
        IPriceFeed priceFeed_,
        address quoteToken_,
        uint256 maxPriceAge_,
        address owner_,
        address vaultFactory_
    ) VLEILauncherFactoryBaseV2(hub_, guardian_, registry_, priceFeed_, quoteToken_, maxPriceAge_, owner_) {
        if (vaultFactory_ == address(0)) revert ZeroAddress();
        if (IPairedVaultFactoryV2(vaultFactory_).launcherFactory() != address(this)) {
            revert VaultFactoryNotPaired(vaultFactory_);
        }
        address vq = IPairedVaultFactoryV2(vaultFactory_).quoteToken();
        if (vq != quoteToken_) revert VaultQuoteMismatch(vq, quoteToken_);
        vaultFactory = vaultFactory_;
    }

    function _deployImplementation() internal override returns (address) {
        return address(new VLEIMintVaultLauncherV2(address(this)));
    }

    function _emitCreated(address launcher, address creator, bytes32 lei, VLEIMintConfig memory c) internal override {
        emit VLEIVaultLauncherCreated(launcher, creator, lei, c.salt, c.targetRaise, c.capUsdPerEntity);
    }

    function _schemaDescription() internal pure override returns (string memory) {
        return "vLEI-gated contribution round with gated yield. Only a vLEI-verified OOR officer can create it; only verified legal entities can contribute, each capped in USD. The quote asset is fixed by the factory (quoteToken(): 0x0 = BNB valued with Atlas BNB/USD, otherwise an ERC20 such as USDT counted 1:1 as USD; approve the launcher, then contribute()). The raise and 50% of the supply seed the pool, the other 50% is claimed by verified contributors pro rata. 75% of the token's tax, paid in the quote asset, goes to a paired vault that pays only stakers who are vLEI-verified (no fee). Refunds if the target is missed or the creator's vLEI is revoked.";
    }
}
