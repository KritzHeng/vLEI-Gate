// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @notice Test / fallback feed. Used only when no Atlas feed address is configured.
contract MockPriceFeed is IPriceFeed {
    uint8 public immutable override decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _round;
    address public owner;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        owner = msg.sender;
        _set(answer_);
    }

    function description() external pure returns (string memory) {
        return "MOCK BNB / USD";
    }

    function setAnswer(int256 answer_) external {
        require(msg.sender == owner, "owner");
        _set(answer_);
    }

    function setUpdatedAt(uint256 ts) external {
        require(msg.sender == owner, "owner");
        _updatedAt = ts;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }

    function _set(int256 answer_) internal {
        _answer = answer_;
        _updatedAt = block.timestamp;
        _round++;
    }
}
