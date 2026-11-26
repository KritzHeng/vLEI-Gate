// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {VLEILauncherFactoryV2} from "../src/v2/VLEILauncherFactoryV2.sol";
import {VLEIVaultLauncherFactoryV2} from "../src/v2/VLEIVaultLauncherFactoryV2.sol";
import {VLEIDividendVaultFactoryV2} from "../src/v2/vault/VLEIDividendVaultFactoryV2.sol";
import {IVLEIRegistry} from "../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

interface IQuoteConfigPortal {
    function launchQuoteConfig(uint8 kind, address quoteToken) external view returns (bool enabled, uint256 priceUsd);
}

/// Deploys the v2 ERC20-quote (USDT) factories NEXT TO the existing BNB deployment (nothing existing is touched):
///   1. VLEIDividendVaultFactoryV2(portal, guardian, predictedVaultLauncherFactory, USDT)   (vault impl + beacon)
///   2. VLEIVaultLauncherFactoryV2(portal, guardian, registry, feed=0, USDT, maxAge, owner, vaultFactory)
///   3. VLEILauncherFactoryV2(portal, guardian, registry, feed=0, USDT, maxAge, owner)       (plain, DIVIDEND slot)
/// Reuses the live VLEIRegistry (deployments/<chainId>.json .registry, default 0x7210…89EF on 97). No price feed.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY   deployer
///   QUOTE_TOKEN            optional; default Flap's mock USDT 0x190C989D5665a0e404B444b53CAE9AbCfb600157 (97)
///   REGISTRY_ADDRESS       optional; default deployments/<chainId>.json .registry
///   ADMIN_ADDRESS          optional; factories' owner (maxPriceAge / minTargetUsd only). Default: deployer
///   MAX_PRICE_AGE          optional; default 3600 (unused on the ERC20 path, kept for the shared base)
///   FLAP_PORTAL, FLAP_GUARDIAN  optional; same defaults as Deploy.s.sol
///   USDT_DEPLOYMENTS_FILE  optional; default ./deployments/<chainId>-usdt.json (written only when broadcasting)
///
/// Simulate (no broadcast):  forge script script/DeployUsdt.s.sol --rpc-url $BSC_TESTNET_RPC
contract DeployUsdt is Script {
    address constant DEFAULT_PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    address constant TESTNET_MOCK_USDT = 0x190C989D5665a0e404B444b53CAE9AbCfb600157;

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
        address quote = vm.envOr("QUOTE_TOKEN", block.chainid == 97 ? TESTNET_MOCK_USDT : address(0));
        require(quote != address(0) && quote.code.length > 0, "QUOTE_TOKEN required (ERC20 with code)");

        address registry = vm.envOr("REGISTRY_ADDRESS", address(0));
        if (registry == address(0)) {
            string memory json = vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
            registry = vm.parseJsonAddress(json, ".registry");
        }
        require(registry.code.length > 0, "registry has no code on this chain");

        (bool enabled, uint256 quotePrice) = IQuoteConfigPortal(portal).launchQuoteConfig(0, quote);
        console2.log("Portal launchQuoteConfig(0, quote): enabled", enabled, "priceUsd", quotePrice);
        require(enabled, "quote not enabled on the Portal");

        vm.startBroadcast(pk);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        VLEIDividendVaultFactoryV2 vaultFactory = new VLEIDividendVaultFactoryV2(portal, guardian, predicted, quote);
        VLEIVaultLauncherFactoryV2 vaultLauncherFactory = new VLEIVaultLauncherFactoryV2(
            portal, guardian, IVLEIRegistry(registry), IPriceFeed(address(0)), quote, maxAge, admin, address(vaultFactory)
        );
        VLEILauncherFactoryV2 factory = new VLEILauncherFactoryV2(
            portal, guardian, IVLEIRegistry(registry), IPriceFeed(address(0)), quote, maxAge, admin
        );
        vm.stopBroadcast();
        require(address(vaultLauncherFactory) == predicted, "vault launcher factory address prediction failed");

        console2.log("Quote token                ", quote);
        console2.log("VLEILauncherFactoryV2      ", address(factory));
        console2.log("  launcher impl / beacon   ", factory.beaconImplementation(), factory.beacon());
        console2.log("VLEIDividendVaultFactoryV2 ", address(vaultFactory));
        console2.log("  vault impl / beacon      ", vaultFactory.beaconImplementation(), vaultFactory.beacon());
        console2.log("VLEIVaultLauncherFactoryV2 ", address(vaultLauncherFactory));
        console2.log("  launcher impl / beacon   ", vaultLauncherFactory.beaconImplementation(), vaultLauncherFactory.beacon());
        console2.log("Registry (reused)          ", registry);
        console2.log("minTargetUsd (quote units) ", factory.minTargetUsd());

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory defaultOut = string.concat("./deployments/", vm.toString(block.chainid), "-usdt.json");
            string memory outFile = vm.envOr("USDT_DEPLOYMENTS_FILE", defaultOut);
            if (bytes(outFile).length == 0) outFile = defaultOut;
            string memory k = "usdt";
            vm.serializeUint(k, "chainId", block.chainid);
            vm.serializeAddress(k, "quoteToken", quote);
            vm.serializeAddress(k, "factory", address(factory));
            vm.serializeAddress(k, "launcherImpl", factory.beaconImplementation());
            vm.serializeAddress(k, "beacon", factory.beacon());
            vm.serializeAddress(k, "vaultFactory", address(vaultFactory));
            vm.serializeAddress(k, "vaultImpl", vaultFactory.beaconImplementation());
            vm.serializeAddress(k, "vaultBeacon", vaultFactory.beacon());
            vm.serializeAddress(k, "vaultLauncherFactory", address(vaultLauncherFactory));
            vm.serializeAddress(k, "vaultLauncherImpl", vaultLauncherFactory.beaconImplementation());
            vm.serializeAddress(k, "vaultLauncherBeacon", vaultLauncherFactory.beacon());
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
