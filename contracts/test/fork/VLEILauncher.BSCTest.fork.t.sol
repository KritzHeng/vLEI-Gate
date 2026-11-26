// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPortal} from "src/flap/IPortal.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";

import {VLEIRegistry} from "../../src/VLEIRegistry.sol";
import {VLEILauncherFactory} from "../../src/VLEILauncherFactory.sol";
import {VLEIMintLauncher, VLEIMintConfig} from "../../src/VLEIMintLauncher.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";
import {IVLEIRegistry} from "../../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {RegistryHelper} from "../utils/RegistryHelper.sol";

interface IProxyAdminLike {
    function owner() external view returns (address);
}

interface IVersioned {
    function version() external view returns (string memory);
}

/// @notice Adapted from Flap's `test/launcher/MintLauncher.fork.t.sol`: the vLEI factory on the LIVE BNB Testnet
///         Portal. Needs `BSC_TESTNET_RPC_URL` (Flap's name) or `BSC_TESTNET_RPC` (this project's); skipped without.
///
///         Enabling a factory is a Portal admin action (`setLauncherFactoryMultiplier` needs DEFAULT_ADMIN, MANAGE or
///         AUDITOR role). The admin is the owner of the Portal's ProxyAdmin, as in Flap's ForkBase. The Flap Guardian
///         has no Portal role; it is only the factory's upgrade authority.
contract VLEILauncherBSCTestForkTest is RegistryHelper {
    address constant PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    address constant PORTAL_PROXY_ADMIN = 0x0000Ed588dfc01749C20bA69b5f8c77d706E0000;
    address constant TOKEN_IMPL = 0x7777c57ff7dc441c1715b2e36fa581c48B782222;
    address constant GUARDIAN = 0x00004d58290854c5E9880F4b5B1993c6Ad8b0000;

    IPortal portal = IPortal(PORTAL);
    address portalAdmin;
    VLEILauncherFactory factory;
    MockPriceFeed feed;
    address regAdmin = address(uint160(0xC0DE00AD));

    // Plain accounts with no code on BNB Testnet (Flap's convention).
    address alice = address(uint160(0xC0DE0002)); //    OOR officer of the issuer: creates the launcher
    address bob = address(uint160(0xC0DE0003)); //      ECR of entity B
    address carol = address(uint160(0xC0DE0005)); //    ECR of entity C
    address outsider = address(uint160(0xC0DE0006)); // never verified

    bytes32 issuerLei = keccak256("5493001KJTIIGC8Y1R12");
    bytes32 leiB = keccak256("984500E1B2C3D4E5F617");
    bytes32 leiC = keccak256("529900T8BM49AURSDO55");

    uint256 saltCounter;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("BSC_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 97, "not BNB Testnet");
        assertEq(LaunchVaultAddresses.hub(), PORTAL);
        assertEq(LaunchVaultAddresses.guardian(), GUARDIAN);
        emit log_named_string("Portal version", IVersioned(PORTAL).version());
        portalAdmin = IProxyAdminLike(PORTAL_PROXY_ADMIN).owner();

        registry = new VLEIRegistry(regAdmin, vm.addr(verifierPk));
        address atlas = vm.envOr("ATLAS_FEED_ADDRESS", address(0));
        feed = new MockPriceFeed(8, 600e8);
        IPriceFeed f = atlas == address(0) ? IPriceFeed(address(feed)) : IPriceFeed(atlas);
        factory = new VLEILauncherFactory(PORTAL, GUARDIAN, IVLEIRegistry(address(registry)), f, 1 days, regAdmin);

        _register(alice, issuerLei, OFFICER);
        _register(bob, leiB, ECR);
        _register(carol, leiC, ECR);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 30 ether);
        vm.deal(carol, 30 ether);
        vm.deal(outsider, 30 ether);
        require(alice.code.length + bob.code.length + carol.code.length + outsider.code.length == 0, "code");
    }

    function _mineSalt(bytes32 seed) internal returns (bytes32 salt) {
        uint256 start = ++saltCounter << 128;
        for (uint256 i = start;; ++i) {
            assembly ("memory-safe") {
                mstore(0x00, seed)
                mstore(0x20, i)
                salt := keccak256(0x00, 0x40)
            }
            if (uint16(uint160(Clones.predictDeterministicAddress(TOKEN_IMPL, salt, PORTAL))) == 0x7777) return salt;
        }
    }

    function _config(bytes32 seed) internal returns (VLEIMintConfig memory c) {
        c.name = "Siam T-Bill 2027";
        c.symbol = "STB27";
        c.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        c.salt = _mineSalt(seed);
        c.targetRaise = 10 ether;
        c.saleDuration = 1 days;
        c.capUsdPerEntity = 5_000e18; // $5,000 per entity (8.33 BNB at $600)
    }

    function _enable() internal {
        vm.prank(portalAdmin);
        portal.setLauncherFactoryMultiplier(address(factory), 10_000, true);
    }

    /// @dev Only the Portal admin can open a factory; the Flap Guardian holds no Portal role.
    function test_01_onlyPortalAdminCanEnableFactory() public {
        vm.prank(GUARDIAN);
        vm.expectRevert();
        portal.setLauncherFactoryMultiplier(address(factory), 10_000, true);

        vm.prank(alice);
        vm.expectRevert();
        portal.setLauncherFactoryMultiplier(address(factory), 10_000, true);

        _enable();
        (bool enabled,) = portal.launcherFactoryMultiplier(address(factory));
        assertTrue(enabled);
    }

    /// @dev With creation paused (the BNB Chain mainnet state, and Flap's ForkBase setup) a launcher of an ENABLED
    ///      factory launches through the pause. Whether an unopened factory is refused is Portal policy: on testnet
    ///      v1.2.0 it was NOT refused when this was written, so that half is logged, not asserted.
    function test_04_pausedPortalWithEnabledFactory() public {
        vm.prank(portalAdmin);
        portal.setCreationPaused(true);
        assertEq(portal.featureFlags() & 1, 1, "paused");
        uint256 fee = portal.SALT_LOCK_FEE();

        // Unopened factory under pause: observed only.
        vm.prank(alice);
        VLEIMintLauncher u =
            VLEIMintLauncher(payable(portal.newLauncher{value: fee}(address(factory), abi.encode(_config("p-un")))));
        vm.prank(bob);
        u.contribute{value: 4 ether}();
        vm.prank(carol);
        try u.contribute{value: 6 ether}() {
            emit log("paused + UNOPENED factory: launch OK (Portal does not gate it)");
        } catch {
            emit log("paused + UNOPENED factory: launch REVERTED");
        }

        _enable();
        vm.prank(alice);
        VLEIMintLauncher l =
            VLEIMintLauncher(payable(portal.newLauncher{value: fee}(address(factory), abi.encode(_config("p-en")))));
        vm.deal(bob, 30 ether);
        vm.deal(carol, 30 ether);
        // Fresh entities so the per-entity cap from the first launcher does not interfere.
        address dave = address(uint160(0xC0DE0007));
        address erin = address(uint160(0xC0DE0008));
        _register(dave, keccak256("LEI-D"), ECR);
        _register(erin, keccak256("LEI-E"), ECR);
        vm.deal(dave, 30 ether);
        vm.deal(erin, 30 ether);
        vm.prank(dave);
        l.contribute{value: 4 ether}();
        vm.prank(erin);
        l.contribute{value: 6 ether}();
        assertTrue(l.launched(), "an enabled factory launches through the pause");
    }

    /// @dev Observation on the live testnet (creation NOT paused at the time of writing): records whether an
    ///      unopened factory can create and launch. Logged, not asserted, because Flap can change this any time.
    function test_05_unopenedFactoryOnLiveTestnet() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        emit log_named_uint("featureFlags (bit0 = paused)", portal.featureFlags());
        vm.prank(alice);
        try portal.newLauncher{value: fee}(address(factory), abi.encode(_config("unopened"))) returns (address a) {
            emit log("newLauncher via an UNOPENED factory: OK");
            VLEIMintLauncher l = VLEIMintLauncher(payable(a));
            vm.prank(bob);
            l.contribute{value: 4 ether}();
            vm.prank(carol);
            try l.contribute{value: 6 ether}() {
                emit log(l.launched() ? "launch via an UNOPENED factory: OK" : "launch: not launched");
            } catch {
                emit log("launch via an UNOPENED factory: REVERTED");
            }
        } catch {
            emit log("newLauncher via an UNOPENED factory: REVERTED");
        }
    }

    function test_02_vleiFullJourney() public {
        _enable();
        uint256 fee = portal.SALT_LOCK_FEE();

        // An ECR wallet cannot create a launcher.
        bytes memory badData = abi.encode(_config("ecr"));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactory.CreatorNotAuthorized.selector, bob));
        portal.newLauncher{value: fee}(address(factory), badData);

        // Verified OOR officer alice creates through the Portal.
        VLEIMintConfig memory c = _config("journey");
        vm.prank(alice);
        VLEIMintLauncher l = VLEIMintLauncher(payable(portal.newLauncher{value: fee}(address(factory), abi.encode(c))));
        assertEq(portal.getLauncher(address(l)).launcherFactory, address(factory), "Portal recorded the launcher");
        assertEq(l.creator(), alice);
        assertEq(l.status(), 0);

        // Unverified outsider is rejected.
        vm.prank(outsider);
        vm.expectRevert(VLEIMintLauncher.NotVerified.selector);
        l.contribute{value: 1 ether}();

        // Verified contributors fill the target; the last contribution launches on the real Portal.
        vm.prank(bob);
        l.contribute{value: 4 ether}();
        vm.recordLogs();
        vm.prank(carol);
        l.contribute{value: 6 ether}();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(l.launched(), "launched");
        assertEq(l.status(), 1);
        address token = l.token();
        assertTrue(token.code.length > 0, "token deployed");
        assertEq(uint16(uint160(token)), 0x7777, "vanity suffix");
        assertTrue(l.pool() != address(0), "pool");
        emit log_named_address("token", token);
        emit log_named_address("pool", l.pool());
        emit log_named_uint("logs in launch tx", logs.length);

        uint256 reserved = l.TOTAL_SUPPLY() - l.POOL_TOKEN();
        vm.prank(bob);
        l.claim();
        assertEq(IERC20(token).balanceOf(bob), reserved * 4 / 10, "bob 40%");

        // Admin revokes bob (already claimed) and carol (not yet claimed): carol's claim is blocked.
        vm.startPrank(regAdmin);
        registry.revokeWallet(bob, "ECR revoked");
        registry.revokeWallet(carol, "ECR revoked");
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(VLEIMintLauncher.NotVerified.selector);
        l.claim();
        assertEq(l.claimableOf(carol), reserved * 6 / 10, "tokens stay reserved for carol");

        // Re-verification unlocks the claim.
        _register(carol, leiC, ECR);
        vm.prank(carol);
        l.claim();
        assertEq(IERC20(token).balanceOf(carol), reserved * 6 / 10, "carol 60%");
    }

    function test_03_capPerEntityAndCancelOnLivePortal() public {
        _enable();
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        VLEIMintLauncher l =
            VLEIMintLauncher(payable(portal.newLauncher{value: fee}(address(factory), abi.encode(_config("cap")))));

        vm.prank(bob);
        l.contribute{value: 8 ether}(); // $4,800
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(VLEIMintLauncher.CapExceeded.selector, 4_800e18, 600e18, 5_000e18));
        l.contribute{value: 1 ether}();

        vm.prank(regAdmin);
        registry.revokeWallet(alice, "OOR revoked");
        l.cancelIfCreatorRevoked();
        vm.prank(bob);
        l.refund();
        assertEq(bob.balance, 30 ether);
        assertFalse(l.launched());
    }

    /// Regression (review #1b, reviewer's PoCFork): targets below the USD minimum are refused at creation instead of
    /// producing a sale that can never pass the Portal's liquidity floor.
    function test_06_tinyTargetsRejectedAtCreation() public {
        _enable();
        uint256 fee = portal.SALT_LOCK_FEE();
        uint256[4] memory targets = [uint256(1), 0.001 ether, 0.1 ether, 1 ether];
        for (uint256 i; i < targets.length; ++i) {
            VLEIMintConfig memory c = _config(bytes32(i + 1));
            c.targetRaise = targets[i];
            vm.prank(alice);
            vm.expectPartialRevert(VLEILauncherFactory.TargetBelowMinimum.selector);
            portal.newLauncher{value: fee}(address(factory), abi.encode(c));
        }
    }

    /// Regression (review #1c): when the live Portal rejects the launch (below its liquidity floor), the raise is not
    /// locked: the launcher records LaunchFailed and everyone refunds immediately. Forced here by inflating our mock
    /// BNB/USD price so a tiny target passes our USD minimum while the Portal, using its own price, rejects it.
    function test_07_portalRejectionOpensRefunds() public {
        if (vm.envOr("ATLAS_FEED_ADDRESS", address(0)) != address(0)) vm.skip(true);
        _enable();
        feed.setAnswer(100_000e8); // $100,000 per BNB in our feed only
        VLEIMintConfig memory c = _config("floor");
        c.targetRaise = 0.02 ether; // $2,000 by our feed, about $12 to the Portal
        c.capUsdPerEntity = 1e30;
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        VLEIMintLauncher l = VLEIMintLauncher(payable(portal.newLauncher{value: fee}(address(factory), abi.encode(c))));

        vm.prank(bob);
        l.contribute{value: 0.01 ether}();
        vm.recordLogs();
        vm.prank(carol);
        l.contribute{value: 0.05 ether}(); // 0.01 accepted, 0.04 returned
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory reason;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(l) && logs[i].topics[0] == VLEIMintLauncher.LaunchFailed.selector) {
                reason = abi.decode(logs[i].data, (bytes));
            }
        }
        emit log_named_bytes("Portal revert reason", reason);
        assertTrue(reason.length >= 4, "LaunchFailed emitted with the Portal's reason");
        assertFalse(l.launched());
        assertTrue(l.launchFailed());
        assertEq(l.status(), 2);
        assertEq(carol.balance, 30 ether - 0.01 ether, "excess returned");

        vm.prank(bob);
        l.refund();
        vm.prank(carol);
        l.refund();
        assertEq(bob.balance, 30 ether);
        assertEq(carol.balance, 30 ether);
        assertEq(address(l).balance, 0);
    }
}
