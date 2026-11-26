// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VLEIRegistry} from "../src/VLEIRegistry.sol";
import {VLEILauncherFactory} from "../src/VLEILauncherFactory.sol";
import {VLEIMintLauncher} from "../src/VLEIMintLauncher.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {IVLEIRegistry} from "../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

/// Deploys VLEIRegistry, the BNB/USD feed (Atlas or MockPriceFeed) and the VLEILauncherFactory (which deploys the
/// VLEIMintLauncher implementation bound to itself and the UpgradeableBeacon), then writes the addresses to JSON.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY   deployer (admin unless ADMIN_ADDRESS is set)
///   VERIFIER_ADDRESS       EIP-712 signer of the backend verifier (or VERIFIER_PRIVATE_KEY)
///   ADMIN_ADDRESS          optional; registry admin and factory owner (default: deployer)
///   ATLAS_FEED_ADDRESS     optional; a MockPriceFeed (8 dp, $600) is deployed when empty
///   MAX_PRICE_AGE          optional; seconds, default 3600 (max 7 days)
///   FLAP_PORTAL            optional; default 0x000042108465206185A077Edc3F3fd2b49060000 (BNB Chain + Testnet)
///   FLAP_GUARDIAN          optional; default per chain (56: 0x9e27…8a4b, else 0x00004d58…0000)
///   DEPLOYMENTS_FILE       optional; default ./deployments/<chainId>.json (set it on an anvil fork of 97 so the
///                          real testnet file is not overwritten, e.g. ./deployments/97-fork.json)
contract Deploy is Script {
    address constant DEFAULT_PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);

        address verifier = vm.envOr("VERIFIER_ADDRESS", address(0));
        if (verifier == address(0)) verifier = vm.addr(vm.envUint("VERIFIER_PRIVATE_KEY"));

        address atlas = vm.envOr("ATLAS_FEED_ADDRESS", address(0));
        uint256 maxAge = vm.envOr("MAX_PRICE_AGE", uint256(3600));
        address portal = vm.envOr("FLAP_PORTAL", DEFAULT_PORTAL);
        address guardian = vm.envOr(
            "FLAP_GUARDIAN",
            block.chainid == 56
                ? 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b
                : address(0x00004d58290854c5E9880F4b5B1993c6Ad8b0000)
        );
        string memory defaultOut = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory outFile = vm.envOr("DEPLOYMENTS_FILE", defaultOut);
        // An empty DEPLOYMENTS_FILE= line in .env means "use the default".
        if (bytes(outFile).length == 0) outFile = defaultOut;

        vm.startBroadcast(pk);
        VLEIRegistry registry = new VLEIRegistry(admin, verifier);

        bool mockFeed = atlas == address(0);
        if (mockFeed) atlas = address(new MockPriceFeed(8, 600e8));

        VLEILauncherFactory factory = new VLEILauncherFactory(
            portal, guardian, IVLEIRegistry(address(registry)), IPriceFeed(atlas), maxAge, admin
        );
        VLEIMintLauncher impl = VLEIMintLauncher(payable(factory.beaconImplementation()));
        vm.stopBroadcast();

        console2.log("VLEIRegistry        ", address(registry));
        console2.log("VLEILauncherFactory ", address(factory));
        console2.log("VLEIMintLauncher impl", address(impl));
        console2.log("Beacon              ", factory.beacon());
        console2.log("PriceFeed           ", atlas, mockFeed ? "(mock)" : "(atlas)");
        console2.log("Portal              ", portal);
        console2.log("Guardian            ", guardian);
        console2.log("Verifier signer     ", verifier);
        console2.log("Written to          ", outFile);

        string memory k = "deploy";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "registry", address(registry));
        vm.serializeAddress(k, "factory", address(factory));
        vm.serializeAddress(k, "launcherImpl", address(impl));
        vm.serializeAddress(k, "beacon", factory.beacon());
        vm.serializeAddress(k, "priceFeed", atlas);
        vm.serializeBool(k, "mockPriceFeed", mockFeed);
        vm.serializeAddress(k, "portal", portal);
        vm.serializeAddress(k, "guardian", guardian);
        vm.serializeUint(k, "maxPriceAge", maxAge);
        vm.serializeUint(k, "minTargetUsd", factory.minTargetUsd());
        vm.serializeAddress(k, "admin", admin);
        string memory json = vm.serializeAddress(k, "verifier", verifier);
        vm.writeJson(json, outFile);
    }
}
