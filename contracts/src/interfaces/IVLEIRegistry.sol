// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read interface used by the launcher and the gated token.
interface IVLEIRegistry {
    function isActive(address wallet) external view returns (bool);
    function isActiveWithRole(address wallet, uint8 minRole) external view returns (bool);
    function canLaunch(address wallet) external view returns (bool);
    function leiHashOf(address wallet) external view returns (bytes32);
}
