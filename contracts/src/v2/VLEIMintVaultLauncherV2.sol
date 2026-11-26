// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPortalTypes} from "src/flap/IPortal.sol";
import {VLEILauncherBaseV2} from "./VLEILauncherBaseV2.sol";

interface IVLEIVaultLauncherFactoryV2Config {
    function vaultFactory() external view returns (address);
}

interface IVLEIVaultFactoryV2Lookup {
    function vaultOf(address token) external view returns (address);
}

/// @title VLEIMintVaultLauncherV2
/// @notice v2 of `VLEIMintVaultLauncher`: the shared v2 round with a gated-yield vault. Tax split burn 10 / LP 15 /
///         VAULT 75; the VAULT slot names the paired `VLEIDividendVaultFactoryV2` with `vaultData = abi.encode(this)`.
///         The vault is paid in the launch's quote (native BNB or the ERC20).
contract VLEIMintVaultLauncherV2 is VLEILauncherBaseV2 {
    /// @notice The paired vault factory named in the VAULT fee slot (read from the launcher factory).
    address public vaultFactory;
    /// @notice The launch's `VLEIDividendVaultV2` (set at launch).
    address public vault;

    event VaultAttached(address indexed token, address indexed vault);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address factory_) VLEILauncherBaseV2(factory_) {}

    function _initVariant(address factory_) internal override {
        address vf = IVLEIVaultLauncherFactoryV2Config(factory_).vaultFactory();
        if (vf == address(0)) revert InvalidConfig();
        vaultFactory = vf;
    }

    function _afterLaunch(address token_) internal override {
        address v = IVLEIVaultFactoryV2Lookup(vaultFactory).vaultOf(token_);
        vault = v;
        emit VaultAttached(token_, v);
    }

    function _feeConfigs() internal view override returns (IPortalTypes.FeeConfig[] memory fees) {
        fees = new IPortalTypes.FeeConfig[](3);
        fees[0] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 1000, configData: ""});
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.LP_BPS, bps: 1500, configData: ""});
        fees[2] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.VAULT,
            bps: 7500,
            configData: abi.encode(
                IPortalTypes.FeeConfigVault({vaultFactory: vaultFactory, vaultData: abi.encode(address(this))})
            )
        });
    }

    function _texts() internal pure override returns (string memory, string memory, string memory, string memory) {
        return (
            unicode"vLEI 认证募资发射（收益仅限认证法人）",
            "vLEI-gated round with gated yield",
            unicode"仅限通过 vLEI 认证的法人参与。募集的报价资产（BNB 或 USDT）与 50% 的代币供应注入流动性池，另外 50% 由已认证的贡献者按出资比例领取。每个法人的出资以 USD 计有上限。代币税收的 75% 进入配套金库，只分给质押代币且 vLEI 认证有效的持有人；无手续费。",
            "Only vLEI-verified legal entities may contribute. The raise (BNB or USDT) and 50% of the supply seed the pool; the other 50% is claimed by verified contributors pro rata, with a USD cap per entity. 75% of the token's tax (paid in the quote asset) goes to a paired vault that pays only holders who stake the token and are vLEI-verified. No fee."
        );
    }
}
