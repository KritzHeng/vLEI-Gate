// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @title AtlasSignedFeed
/// @notice On-chain, aggregator-style (Chainlink AggregatorV3 subset) price feed fed by signed reports from the
///         Atlas Oracle Pull API (`POST /report/v1/price/latest` with `signed: true`).
///
///         Anyone can relay a report with `submit(payload, signature)`; it is accepted only if
///           - the signature (65 bytes r|s|v, v = 27/28, low-s) over `keccak256(payload)` (raw, no EIP-191 prefix)
///             recovers to `atlasSigner`,
///           - the payload contains an entry for `feedId`, with a non-zero price,
///           - the entry timestamp is strictly newer than the stored one and at most `MAX_FUTURE_SKEW` in the future.
///
///         Payload layout (see docs/atlas-payload-format.md), big-endian, tightly packed:
///           N × [ feedId uint32 (4) | price uint80 (10, 1e18 scale) | timestampSeconds uint48 (6) ] ‖ N uint8 (1)
///         i.e. `length == 20 * N + 1` and the last byte equals N.
///
///         The answer is exposed with 8 decimals (Chainlink convention, same as the MockPriceFeed this replaces);
///         the raw 18-decimal Atlas price is kept in `latestRawPrice()`. `updatedAt` is the Atlas price timestamp
///         (not the relay time), so consumers' staleness checks measure the age of the observation itself.
contract AtlasSignedFeed is IPriceFeed, Ownable2Step {
    uint8 public constant override decimals = 8;
    /// @notice Atlas prices are 1e18-scaled; answer = raw / 1e10.
    uint256 public constant SCALE_DOWN = 1e10;
    /// @notice Tolerated clock skew for report timestamps ahead of `block.timestamp`.
    uint256 public constant MAX_FUTURE_SKEW = 60;
    uint256 internal constant ENTRY_LEN = 20;

    /// @notice Atlas feed id this contract tracks (the `feedId` string from the API, as a number). 0 = not set yet.
    uint32 public feedId;
    /// @notice Address that signs Atlas reports (docs: 0x59ed4701224fd9e2a85ef2946c2ab828c1ddc600).
    address public atlasSigner;

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _rawPrice;
    uint256 internal _updatedAt;

    event PriceSubmitted(uint80 indexed roundId, int256 answer, uint256 rawPrice, uint256 timestamp, address indexed relayer);
    event AtlasSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event FeedIdUpdated(uint32 previousFeedId, uint32 newFeedId);

    error ZeroAddress();
    error FeedIdNotSet();
    error FeedIdLocked();
    error InvalidFeedId();
    error UnexpectedSigner(address recovered);
    error MalformedPayload(uint256 length);
    error FeedNotInPayload(uint32 feedId);
    error InvalidPrice();
    error NotNewer(uint256 timestamp, uint256 latest);
    error FutureTimestamp(uint256 timestamp);

    constructor(address owner_, address atlasSigner_, uint32 feedId_) Ownable(owner_) {
        if (atlasSigner_ == address(0)) revert ZeroAddress();
        atlasSigner = atlasSigner_;
        feedId = feedId_;
        emit AtlasSignerUpdated(address(0), atlasSigner_);
        if (feedId_ != 0) emit FeedIdUpdated(0, feedId_);
    }

    // ── Relay ───────────────────────────────────────────────────────────────

    /// @notice Store the price for `feedId` from a signed Atlas report. Permissionless.
    /// @param payload   `data.payload` from the Atlas response, as bytes.
    /// @param signature `data.signature` (65 bytes r|s|v).
    function submit(bytes calldata payload, bytes calldata signature) external returns (uint80 roundId) {
        uint32 id = feedId;
        if (id == 0) revert FeedIdNotSet();

        address recovered = ECDSA.recover(keccak256(payload), signature);
        if (recovered != atlasSigner) revert UnexpectedSigner(recovered);

        (uint256 raw, uint256 ts) = decodeEntry(payload, id);
        int256 answer = int256(raw / SCALE_DOWN);
        if (answer <= 0) revert InvalidPrice();
        if (ts <= _updatedAt) revert NotNewer(ts, _updatedAt);
        if (ts > block.timestamp + MAX_FUTURE_SKEW) revert FutureTimestamp(ts);

        roundId = ++_roundId;
        _answer = answer;
        _rawPrice = raw;
        _updatedAt = ts;
        emit PriceSubmitted(roundId, answer, raw, ts, msg.sender);
    }

    // ── Owner ───────────────────────────────────────────────────────────────

    /// @notice Rotate the Atlas signing address (Atlas publishes the current one in its docs).
    function setAtlasSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit AtlasSignerUpdated(atlasSigner, newSigner);
        atlasSigner = newSigner;
    }

    /// @notice Set the tracked feed id. Only possible until the first successful `submit`, so a consumer can never
    ///         see a price silently switch to a different asset.
    function setFeedId(uint32 newFeedId) external onlyOwner {
        if (_roundId != 0) revert FeedIdLocked();
        if (newFeedId == 0) revert InvalidFeedId();
        emit FeedIdUpdated(feedId, newFeedId);
        feedId = newFeedId;
    }

    // ── Views ───────────────────────────────────────────────────────────────

    function description() external pure returns (string memory) {
        return "Atlas BNB / USD (signed)";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc IPriceFeed
    /// @dev Before the first submit everything is 0; consumers reject answer <= 0.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    /// @notice Last accepted Atlas price in its native 1e18 scale.
    function latestRawPrice() external view returns (uint256) {
        return _rawPrice;
    }

    /// @notice Decode the entry for `id` from an Atlas payload. Reverts MalformedPayload / FeedNotInPayload.
    /// @return price     Raw price (1e18 scale).
    /// @return timestamp Price timestamp (unix seconds).
    function decodeEntry(bytes calldata payload, uint32 id) public pure returns (uint256 price, uint256 timestamp) {
        uint256 len = payload.length;
        if (len < ENTRY_LEN + 1 || (len - 1) % ENTRY_LEN != 0) revert MalformedPayload(len);
        uint256 n = (len - 1) / ENTRY_LEN;
        if (uint8(payload[len - 1]) != n) revert MalformedPayload(len);
        for (uint256 i; i < n; ++i) {
            uint256 o = i * ENTRY_LEN;
            if (uint32(bytes4(payload[o:o + 4])) == id) {
                price = uint80(bytes10(payload[o + 4:o + 14]));
                timestamp = uint48(bytes6(payload[o + 14:o + 20]));
                return (price, timestamp);
            }
        }
        revert FeedNotInPayload(id);
    }
}
