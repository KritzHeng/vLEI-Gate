// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VLEIMintConfig} from "../VLEIMintLauncher.sol";
import {VLEILauncherFactoryBaseV2} from "./VLEILauncherFactoryBaseV2.sol";
import {VLEIMintLauncherV2} from "./VLEIMintLauncherV2.sol";
import {IVLEIRegistry} from "../interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @title VLEILauncherFactoryV2
/// @notice v2 of `VLEILauncherFactory` (DIVIDEND tax slot), with a factory-level quote asset (native or ERC20).
contract VLEILauncherFactoryV2 is VLEILauncherFactoryBaseV2 {
    event VLEILauncherCreated(
        address indexed launcher,
        address indexed creator,
        bytes32 indexed creatorLeiHash,
        bytes32 launchSalt,
        uint256 targetRaise,
        uint256 capUsdPerEntity
    );

    constructor(
        address hub_,
        address guardian_,
        IVLEIRegistry registry_,
        IPriceFeed priceFeed_,
        address quoteToken_,
        uint256 maxPriceAge_,
        address owner_
    ) VLEILauncherFactoryBaseV2(hub_, guardian_, registry_, priceFeed_, quoteToken_, maxPriceAge_, owner_) {}

    function _deployImplementation() internal override returns (address) {
        return address(new VLEIMintLauncherV2(address(this)));
    }

    function _emitCreated(address launcher, address creator, bytes32 lei, VLEIMintConfig memory c) internal override {
        emit VLEILauncherCreated(launcher, creator, lei, c.salt, c.targetRaise, c.capUsdPerEntity);
    }

    function _schemaDescription() internal pure override returns (string memory) {
        return "vLEI-gated contribution round. Only a vLEI-verified OOR officer can create it; only verified legal entities can contribute, each capped in USD. The quote asset is fixed by the factory (quoteToken(): 0x0 = BNB valued with Atlas BNB/USD, otherwise an ERC20 such as USDT counted 1:1 as USD; approve the launcher, then contribute()). The raise and 50% of the supply seed the pool, the other 50% is claimed by verified contributors pro rata. Refunds if the target is missed or the creator's vLEI is revoked.";
    }
}
