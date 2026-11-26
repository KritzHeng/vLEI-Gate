// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {AtlasSignedFeed} from "../src/oracle/AtlasSignedFeed.sol";
import {VLEILauncherFactoryV2} from "../src/v2/VLEILauncherFactoryV2.sol";
import {IVLEIRegistry} from "../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

/// Deploys, NEXT TO the existing deployments (nothing existing is touched):
///   1. AtlasSignedFeed(owner, atlasSigner, feedId)        signed Atlas Pull API reports -> AggregatorV3-style feed
///   2. VLEILauncherFactoryV2(portal, guardian, registry, feed, quote = address(0) (native BNB), maxAge, owner)
/// Reuses the live VLEIRegistry (deployments/<chainId>.json .registry).
///
/// Env:
///   DEPLOYER_PRIVATE_KEY   deployer
///   ATLAS_BNB_FEED_ID      optional; Atlas feedId of BNB/USD. 0/empty => deployed unset; the owner must call
///                          setFeedId(id) before the first submit (setFeedId is locked after the first submit).
///   ATLAS_SIGNER           optional; default 0x59ed4701224fd9e2a85ef2946c2ab828c1ddc600 (Atlas docs)
///   ADMIN_ADDRESS          optional; owner of the feed and the factory. Default: deployer
///   MAX_PRICE_AGE          optional; default 3600
///   REGISTRY_ADDRESS, FLAP_PORTAL, FLAP_GUARDIAN  optional; same defaults as DeployUsdt.s.sol
///   ATLAS_DEPLOYMENTS_FILE optional; default ./deployments/<chainId>-atlas.json (written only when broadcasting)
///
/// Simulate:  forge script script/DeployAtlasFeed.s.sol --rpc-url $RPC_URL
/// Deploy:    forge script script/DeployAtlasFeed.s.sol --rpc-url $RPC_URL --broadcast --verify --verifier sourcify
contract DeployAtlasFeed is Script {
    address constant DEFAULT_PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    address constant DEFAULT_ATLAS_SIGNER = 0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);
        uint256 maxAge = vm.envOr("MAX_PRICE_AGE", uint256(3600));
        address portal = vm.envOr("FLAP_PORTAL", DEFAULT_PORTAL);
        address guardian = vm.envOr(
            "FLAP_GUARDIAN",
            block.chainid == 56
                ? 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b
                : address(0x00004d58290854c5E9880F4b5B1993c6Ad8b0000)
        );
        address signer = vm.envOr("ATLAS_SIGNER", DEFAULT_ATLAS_SIGNER);
        uint256 feedIdRaw = vm.envOr("ATLAS_BNB_FEED_ID", uint256(0));
        require(feedIdRaw <= type(uint32).max, "ATLAS_BNB_FEED_ID > uint32");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 feedId = uint32(feedIdRaw);

        address registry = vm.envOr("REGISTRY_ADDRESS", address(0));
        if (registry == address(0)) {
            string memory json = vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
            registry = vm.parseJsonAddress(json, ".registry");
        }
        require(registry.code.length > 0, "registry has no code on this chain");

        vm.startBroadcast(pk);
        AtlasSignedFeed feed = new AtlasSignedFeed(admin, signer, feedId);
        VLEILauncherFactoryV2 factory = new VLEILauncherFactoryV2(
            portal, guardian, IVLEIRegistry(registry), IPriceFeed(address(feed)), address(0), maxAge, admin
        );
        vm.stopBroadcast();

        console2.log("AtlasSignedFeed            ", address(feed));
        console2.log("  atlasSigner              ", signer);
        console2.log("  feedId (0 = unset)       ", feedId);
        console2.log("VLEILauncherFactoryV2 (BNB)", address(factory));
        console2.log("  launcher impl / beacon   ", factory.beaconImplementation(), factory.beacon());
        console2.log("Registry (reused)          ", registry);
        console2.log("minTargetUsd (USD 18dp)    ", factory.minTargetUsd());

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory defaultOut = string.concat("./deployments/", vm.toString(block.chainid), "-atlas.json");
            string memory outFile = vm.envOr("ATLAS_DEPLOYMENTS_FILE", defaultOut);
            if (bytes(outFile).length == 0) outFile = defaultOut;
            string memory k = "atlas";
            vm.serializeUint(k, "chainId", block.chainid);
            vm.serializeAddress(k, "atlasSignedFeed", address(feed));
            vm.serializeAddress(k, "atlasSigner", signer);
            vm.serializeUint(k, "atlasFeedId", feedId);
            vm.serializeAddress(k, "quoteToken", address(0));
            vm.serializeAddress(k, "factory", address(factory));
            vm.serializeAddress(k, "launcherImpl", factory.beaconImplementation());
            vm.serializeAddress(k, "beacon", factory.beacon());
            vm.serializeAddress(k, "registry", registry);
            vm.serializeAddress(k, "portal", portal);
            vm.serializeAddress(k, "guardian", guardian);
            vm.serializeAddress(k, "admin", admin);
            vm.serializeUint(k, "maxPriceAge", maxAge);
            string memory out = vm.serializeString(k, "minTargetUsd", vm.toString(factory.minTargetUsd()));
            vm.writeJson(out, outFile);
            console2.log("Written to                 ", outFile);
        }
    }
}
