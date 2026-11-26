// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AtlasSignedFeed} from "../src/oracle/AtlasSignedFeed.sol";
import {VLEIRegistry} from "../src/VLEIRegistry.sol";
import {VLEILauncherFactoryV2} from "../src/v2/VLEILauncherFactoryV2.sol";
import {VLEILauncherFactoryBaseV2} from "../src/v2/VLEILauncherFactoryBaseV2.sol";
import {IVLEIRegistry} from "../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {MockPortalV2} from "./mocks/MockPortalV2.sol";

/// Uses the real signed examples published in the Atlas Pull API docs (docs/reference/atlas-pull-api.txt).
contract AtlasSignedFeedTest is Test {
    address constant ATLAS_SIGNER = 0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600;
    uint32 constant DOC_FEED = 624;

    // /v1/price/latest example
    bytes constant P1 = hex"0000027000000de01dedfc23734f00006a27cdd301";
    bytes constant S1 =
        hex"447d98f5648f0fd1571fd38558dfeb5ab9ee07e7546aaef8f0b45851bbee4a160eeedec974cf0b72a114b176f710e2ca8035520bafd89fb31e231059fd9056171b";
    uint256 constant PRICE1 = 999832025250886479;
    uint256 constant TS1 = 1780993491;
    // WebSocket push example
    bytes constant P2 = hex"0000027000000ddff9a9ef12d28d00006a27d82d01";
    bytes constant S2 =
        hex"1ddd2aff803f74ce925b4616a382712142c015d4a1b943d8e17ff1a17f02aee75f7f1a62da1d79bb738873b9867063a73360460a62e44a3a4633ff932d1678201b";
    uint256 constant PRICE2 = 999792150555316877;
    uint256 constant TS2 = 1780996141;
    // /v1/price/history example (v = 28)
    bytes constant P3 = hex"0000027000000ddecb3a6f7ee60700006a6aef1e01";
    bytes constant S3 =
        hex"cae7b64e8151162fb533f5544aa4802e66edbf15a01e96f4f49b8cbd7c195b1f178d29705bc79c85a444fa5687f101690604a074f107c1fd91c151b958fbceee1c";
    uint256 constant PRICE3 = 999459619161957895;
    uint256 constant TS3 = 1785392926;

    address owner = makeAddr("owner");
    AtlasSignedFeed feed;

    function setUp() public {
        feed = new AtlasSignedFeed(owner, ATLAS_SIGNER, DOC_FEED);
        vm.warp(TS3 + 10);
    }

    // ── format / hashing evidence ───────────────────────────────────────────

    function test_docExamplesRecoverAtlasSigner_rawKeccak() public pure {
        assertEq(ECDSA.recover(keccak256(P1), S1), ATLAS_SIGNER);
        assertEq(ECDSA.recover(keccak256(P2), S2), ATLAS_SIGNER);
        assertEq(ECDSA.recover(keccak256(P3), S3), ATLAS_SIGNER);
    }

    function test_docExamplesDecode() public view {
        (uint256 p, uint256 t) = feed.decodeEntry(P1, DOC_FEED);
        assertEq(p, PRICE1);
        assertEq(t, TS1);
        (p, t) = feed.decodeEntry(P2, DOC_FEED);
        assertEq(p, PRICE2);
        assertEq(t, TS2);
        (p, t) = feed.decodeEntry(P3, DOC_FEED);
        assertEq(p, PRICE3);
        assertEq(t, TS3);
    }

    // ── submit ──────────────────────────────────────────────────────────────

    function test_submit_storesPrice() public {
        vm.expectEmit(true, true, false, true);
        emit AtlasSignedFeed.PriceSubmitted(1, int256(PRICE1 / 1e10), PRICE1, TS1, address(this));
        feed.submit(P1, S1);
        (uint80 r, int256 a, uint256 st, uint256 up, uint80 ar) = feed.latestRoundData();
        assertEq(r, 1);
        assertEq(ar, 1);
        assertEq(a, int256(PRICE1 / 1e10));
        assertEq(st, TS1);
        assertEq(up, TS1);
        assertEq(feed.latestRawPrice(), PRICE1);
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "Atlas BNB / USD (signed)");
        assertEq(feed.atlasSigner(), ATLAS_SIGNER);
        assertEq(feed.feedId(), DOC_FEED);
    }

    function test_submit_sequenceThenRejectsReplayAndRollback() public {
        feed.submit(P1, S1);
        feed.submit(P2, S2);
        feed.submit(P3, S3);
        (uint80 r,,, uint256 up,) = feed.latestRoundData();
        assertEq(r, 3);
        assertEq(up, TS3);

        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.NotNewer.selector, TS3, TS3));
        feed.submit(P3, S3); // replay
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.NotNewer.selector, TS1, TS3));
        feed.submit(P1, S1); // rollback
    }

    function test_submit_rejectsFutureTimestamp() public {
        vm.warp(TS1 - 61);
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.FutureTimestamp.selector, TS1));
        feed.submit(P1, S1);
        vm.warp(TS1 - 60); // within skew
        feed.submit(P1, S1);
    }

    function test_submit_rejectsWrongSigner() public {
        AtlasSignedFeed other = new AtlasSignedFeed(owner, makeAddr("notAtlas"), DOC_FEED);
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.UnexpectedSigner.selector, ATLAS_SIGNER));
        other.submit(P1, S1);
    }

    function test_submit_rejectsWrongFeedId() public {
        AtlasSignedFeed bnb = new AtlasSignedFeed(owner, ATLAS_SIGNER, 625);
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.FeedNotInPayload.selector, uint32(625)));
        bnb.submit(P1, S1);
    }

    function test_submit_rejectsTamperedPayload() public {
        bytes memory p = P1;
        p[10] = bytes1(uint8(p[10]) ^ 0x01); // flip a price bit
        vm.expectRevert(); // recovers some other address
        feed.submit(p, S1);
        // and with the signature of another report
        vm.expectRevert();
        feed.submit(P1, S2);
    }

    function test_submit_rejectsMalleableSignature() public {
        // (r, n - s, v ^ 1) recovers the same key but OZ ECDSA rejects high-s.
        bytes memory sig = S1;
        bytes32 r;
        bytes32 s;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(n - uint256(s));
        bytes memory mal = abi.encodePacked(r, s2, uint8(28));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, s2));
        feed.submit(P1, mal);
    }

    function test_submit_rejectsBadLength() public {
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        feed.submit(P1, new bytes(64));
    }

    function test_submit_requiresFeedId() public {
        AtlasSignedFeed unset = new AtlasSignedFeed(owner, ATLAS_SIGNER, 0);
        vm.expectRevert(AtlasSignedFeed.FeedIdNotSet.selector);
        unset.submit(P1, S1);
        vm.prank(owner);
        unset.setFeedId(DOC_FEED);
        unset.submit(P1, S1);
        vm.prank(owner);
        vm.expectRevert(AtlasSignedFeed.FeedIdLocked.selector);
        unset.setFeedId(625);
    }

    // ── synthetic multi-entry payloads signed by a test key ─────────────────

    function _sign(uint256 pk, bytes memory payload) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(payload));
        return abi.encodePacked(r, s, v);
    }

    function _entry(uint32 id, uint80 price, uint48 ts) internal pure returns (bytes memory) {
        return abi.encodePacked(id, price, ts);
    }

    function test_multiEntryPayload_picksOwnFeed() public {
        (address signer, uint256 pk) = makeAddrAndKey("atlas-test");
        AtlasSignedFeed bnb = new AtlasSignedFeed(owner, signer, 9);
        uint48 ts = uint48(block.timestamp);
        bytes memory payload = abi.encodePacked(_entry(624, 1e18, ts), _entry(9, 612.345678e18, ts), uint8(2));
        bnb.submit(payload, _sign(pk, payload));
        (, int256 a,, uint256 up,) = bnb.latestRoundData();
        assertEq(a, 612.345678e8);
        assertEq(up, ts);
    }

    function test_rejectsZeroPrice_andMalformed() public {
        (address signer, uint256 pk) = makeAddrAndKey("atlas-test");
        AtlasSignedFeed bnb = new AtlasSignedFeed(owner, signer, 9);
        uint48 ts = uint48(block.timestamp);
        bytes memory zero = abi.encodePacked(_entry(9, 1e9, ts), uint8(1)); // < 1e-8 USD -> 0 at 8 dp
        bytes memory sigZero = _sign(pk, zero);
        vm.expectRevert(AtlasSignedFeed.InvalidPrice.selector);
        bnb.submit(zero, sigZero);

        bytes memory badCount = abi.encodePacked(_entry(9, 600e18, ts), uint8(2));
        bytes memory sigBad = _sign(pk, badCount);
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.MalformedPayload.selector, uint256(21)));
        bnb.submit(badCount, sigBad);

        bytes memory truncated = abi.encodePacked(uint32(9), uint80(600e18));
        bytes memory sigTrunc = _sign(pk, truncated);
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.MalformedPayload.selector, uint256(14)));
        bnb.submit(truncated, sigTrunc);
    }

    // ── owner ───────────────────────────────────────────────────────────────

    function test_setAtlasSigner_onlyOwner_andRotates() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        feed.setAtlasSigner(address(1));

        address next = makeAddr("nextSigner");
        vm.expectEmit(true, true, false, false);
        emit AtlasSignedFeed.AtlasSignerUpdated(ATLAS_SIGNER, next);
        vm.prank(owner);
        feed.setAtlasSigner(next);
        assertEq(feed.atlasSigner(), next);
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.UnexpectedSigner.selector, ATLAS_SIGNER));
        feed.submit(P1, S1);

        vm.prank(owner);
        vm.expectRevert(AtlasSignedFeed.ZeroAddress.selector);
        feed.setAtlasSigner(address(0));
    }

    function test_setFeedId_onlyOwner_nonZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        feed.setFeedId(1);
        vm.prank(owner);
        vm.expectRevert(AtlasSignedFeed.InvalidFeedId.selector);
        feed.setFeedId(0);
    }

    // ── consumed by the v2 BNB-quote factory ────────────────────────────────

    function test_v2FactoryQuoteUsd_usesSignedPrice() public {
        (address signer, uint256 pk) = makeAddrAndKey("atlas-test");
        AtlasSignedFeed bnb = new AtlasSignedFeed(owner, signer, 9);
        VLEIRegistry registry = new VLEIRegistry(owner, makeAddr("verifier"));
        VLEILauncherFactoryV2 factory = new VLEILauncherFactoryV2(
            address(new MockPortalV2()),
            makeAddr("guardian"),
            IVLEIRegistry(address(registry)),
            IPriceFeed(address(bnb)),
            address(0),
            1 hours,
            owner
        );
        // nothing pushed yet -> InvalidPrice
        vm.expectRevert(VLEILauncherFactoryBaseV2.InvalidPrice.selector);
        factory.quoteUsd(1 ether);

        bytes memory payload = abi.encodePacked(_entry(9, 600e18, uint48(block.timestamp)), uint8(1));
        bnb.submit(payload, _sign(pk, payload));
        assertEq(factory.quoteUsd(2.5 ether), 1500e18);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(VLEILauncherFactoryBaseV2.StalePrice.selector);
        factory.quoteUsd(1 ether);
    }

    // ── review additions ────────────────────────────────────────────────────

    /// A report up to MAX_FUTURE_SKEW ahead is accepted by the feed, but the factory treats updatedAt > now as
    /// StalePrice, so launches/contributions revert until the chain clock catches up (self-healing, <= 60 s).
    function test_futureSkewReport_factoryRevertsUntilClockCatchesUp() public {
        (address signer, uint256 pk) = makeAddrAndKey("atlas-test");
        AtlasSignedFeed bnb = new AtlasSignedFeed(owner, signer, 9);
        VLEILauncherFactoryV2 factory = new VLEILauncherFactoryV2(
            address(new MockPortalV2()),
            makeAddr("guardian"),
            IVLEIRegistry(address(new VLEIRegistry(owner, makeAddr("verifier")))),
            IPriceFeed(address(bnb)),
            address(0),
            1 hours,
            owner
        );
        bytes memory payload = abi.encodePacked(_entry(9, 600e18, uint48(block.timestamp + 30)), uint8(1));
        bnb.submit(payload, _sign(pk, payload));
        vm.expectRevert(VLEILauncherFactoryBaseV2.StalePrice.selector);
        factory.quoteUsd(1 ether);
        vm.warp(block.timestamp + 30);
        assertEq(factory.quoteUsd(1 ether), 600e18);
    }

    /// Any newer-than-stored signed report is accepted, including an older (history endpoint) one, so a relayer can
    /// choose which observation within the factory's maxPriceAge window becomes the price.
    function test_relayerCanPickAnyReportNewerThanStored() public {
        (address signer, uint256 pk) = makeAddrAndKey("atlas-test");
        AtlasSignedFeed bnb = new AtlasSignedFeed(owner, signer, 9);
        uint48 nowTs = uint48(block.timestamp);
        bytes memory old_ = abi.encodePacked(_entry(9, 550e18, nowTs - 3000), uint8(1));
        bytes memory fresh = abi.encodePacked(_entry(9, 600e18, nowTs), uint8(1));
        bytes memory sigOld = _sign(pk, old_);
        bytes memory sigFresh = _sign(pk, fresh);
        bnb.submit(old_, sigOld); // front-run with the older one: accepted
        (, int256 a,,,) = bnb.latestRoundData();
        assertEq(a, 550e8);
        bnb.submit(fresh, sigFresh); // the fresher one still lands afterwards
        (, a,,,) = bnb.latestRoundData();
        assertEq(a, 600e8);
        vm.expectRevert(abi.encodeWithSelector(AtlasSignedFeed.NotNewer.selector, uint256(nowTs - 3000), uint256(nowTs)));
        bnb.submit(old_, sigOld); // but can no longer roll back
    }

    function test_rejectsV0V1Signature() public {
        bytes memory sig = S1;
        sig[64] = bytes1(uint8(sig[64]) - 27); // 27 -> 0
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        feed.submit(P1, sig);
    }

    function test_ownable2Step_transfer() public {
        address next = makeAddr("next");
        vm.prank(owner);
        feed.transferOwnership(next);
        assertEq(feed.owner(), owner);
        vm.prank(next);
        feed.acceptOwnership();
        assertEq(feed.owner(), next);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        feed.setAtlasSigner(address(1));
    }
}
