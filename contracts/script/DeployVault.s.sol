// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {VLEIVaultLauncherFactory} from "../src/VLEIVaultLauncherFactory.sol";
import {VLEIDividendVaultFactory} from "../src/vault/VLEIDividendVaultFactory.sol";
import {IVLEIRegistry} from "../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

/// Deploys the gated-yield pair NEXT TO the existing deployment (nothing existing is touched):
///   1. VLEIDividendVaultFactory(portal, guardian, predictedLauncherFactory)   (deploys the vault impl + beacon)
///   2. VLEIVaultLauncherFactory(portal, guardian, registry, feed, maxAge, owner, vaultFactory)
///      (deploys the VLEIMintVaultLauncher impl + beacon; checks the pairing both ways)
/// It reuses the live VLEIRegistry and price feed from ./deployments/<chainId>.json unless overridden.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY   deployer
///   REGISTRY_ADDRESS       optional; default deployments/<chainId>.json .registry
///   PRICE_FEED_ADDRESS     optional; default deployments/<chainId>.json .priceFeed
///   ADMIN_ADDRESS          optional; launcher-factory owner (maxPriceAge / minTargetUsd only). Default: deployer
///   MAX_PRICE_AGE          optional; default 3600
///   FLAP_PORTAL, FLAP_GUARDIAN  optional; same defaults as Deploy.s.sol
///   VAULT_DEPLOYMENTS_FILE optional; default ./deployments/<chainId>-vault.json (written only when broadcasting)
///
/// Simulate (no broadcast):  forge script script/DeployVault.s.sol --rpc-url $BSC_TESTNET_RPC
contract DeployVault is Script {
    address constant DEFAULT_PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;

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

        address registry = vm.envOr("REGISTRY_ADDRESS", address(0));
        address feed = vm.envOr("PRICE_FEED_ADDRESS", address(0));
        if (registry == address(0) || feed == address(0)) {
            string memory json = vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
            if (registry == address(0)) registry = vm.parseJsonAddress(json, ".registry");
            if (feed == address(0)) feed = vm.parseJsonAddress(json, ".priceFeed");
        }
        require(registry.code.length > 0, "registry has no code on this chain");
        require(feed.code.length > 0, "price feed has no code on this chain");

        vm.startBroadcast(pk);
        // The launcher factory is the deployer's next CREATE after the vault factory.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        VLEIDividendVaultFactory vaultFactory = new VLEIDividendVaultFactory(portal, guardian, predicted);
        VLEIVaultLauncherFactory factory = new VLEIVaultLauncherFactory(
            portal, guardian, IVLEIRegistry(registry), IPriceFeed(feed), maxAge, admin, address(vaultFactory)
        );
        vm.stopBroadcast();
        require(address(factory) == predicted, "launcher factory address prediction failed");

        console2.log("VLEIDividendVaultFactory", address(vaultFactory));
        console2.log("  vault impl / beacon   ", vaultFactory.beaconImplementation(), vaultFactory.beacon());
        console2.log("VLEIVaultLauncherFactory", address(factory));
        console2.log("  launcher impl / beacon", factory.beaconImplementation(), factory.beacon());
        console2.log("Registry (reused)       ", registry);
        console2.log("Price feed (reused)     ", feed);

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory defaultOut = string.concat("./deployments/", vm.toString(block.chainid), "-vault.json");
            string memory outFile = vm.envOr("VAULT_DEPLOYMENTS_FILE", defaultOut);
            if (bytes(outFile).length == 0) outFile = defaultOut;
            string memory k = "vault";
            vm.serializeUint(k, "chainId", block.chainid);
            vm.serializeAddress(k, "vaultFactory", address(vaultFactory));
            vm.serializeAddress(k, "vaultImpl", vaultFactory.beaconImplementation());
            vm.serializeAddress(k, "vaultBeacon", vaultFactory.beacon());
            vm.serializeAddress(k, "vaultLauncherFactory", address(factory));
            vm.serializeAddress(k, "vaultLauncherImpl", factory.beaconImplementation());
            vm.serializeAddress(k, "vaultLauncherBeacon", factory.beacon());
            vm.serializeAddress(k, "registry", registry);
            vm.serializeAddress(k, "priceFeed", feed);
            vm.serializeAddress(k, "portal", portal);
            string memory out = vm.serializeAddress(k, "guardian", guardian);
            vm.writeJson(out, outFile);
            console2.log("Written to              ", outFile);
        }
    }
}
