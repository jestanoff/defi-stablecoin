// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;


interface IDscEngine {
    function depositCollateralAndMintDsc() external;

    function depositCollateral() external;

    function redeemCollateralForDsc() external;

    function redeemCollateral() external;

    function burnDsc() external;

    function mintDsc() external;

    function liquidate() external;

    function getHealthFactor() external view;
}
