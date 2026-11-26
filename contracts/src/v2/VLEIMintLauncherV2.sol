// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPortalTypes} from "src/flap/IPortal.sol";
import {VLEILauncherBaseV2} from "./VLEILauncherBaseV2.sol";

/// @title VLEIMintLauncherV2
/// @notice v2 of `VLEIMintLauncher`: same gate and economics (1M supply, 50% pool / 50% pro-rata claim, 3%/5% tax,
///         burn 10 / LP 15 / DIVIDEND 75, no commission), with the quote asset chosen by the factory (native BNB or
///         an 18-decimal ERC20 such as USDT). The DIVIDEND slot pays in the quote (`dividendToken = address(0)`).
contract VLEIMintLauncherV2 is VLEILauncherBaseV2 {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address factory_) VLEILauncherBaseV2(factory_) {}

    function _feeConfigs() internal pure override returns (IPortalTypes.FeeConfig[] memory fees) {
        fees = new IPortalTypes.FeeConfig[](3);
        fees[0] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 1000, configData: ""});
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.LP_BPS, bps: 1500, configData: ""});
        fees[2] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.DIVIDEND,
            bps: 7500,
            configData: abi.encode(
                IPortalTypes.FeeConfigDividend({dividendToken: address(0), minimumShareBalance: TOTAL_SUPPLY / 1000})
            )
        });
    }

    function _texts() internal pure override returns (string memory, string memory, string memory, string memory) {
        return (
            unicode"vLEI 认证募资发射",
            "vLEI-gated contribution round",
            unicode"仅限通过 vLEI 认证的法人参与。以报价资产（BNB 或 USDT）募集直至达到目标，募集资金与 50% 的代币供应注入流动性池，另外 50% 由已认证的贡献者按出资比例领取。每个法人的出资以 USD 计有上限。",
            "Only vLEI-verified legal entities may contribute. The quote asset (BNB or USDT) is collected until the target is met; the raise and 50% of the supply then seed the pool and the other 50% is claimed by verified contributors pro rata. Each entity has a USD cap."
        );
    }
}
