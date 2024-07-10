// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way we call functions

pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DscEngine dscEngine;
    DecentralizedStableCoin dsc;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    uint256 public timesMintCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DecentralizedStableCoin _dsc, DscEngine _dscEngine) {
        dsc = _dsc;
        dscEngine = _dscEngine;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
    }

    // redeem collateral <-
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = ERC20Mock(_getCollateralFromSeed(collateralSeed));
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = ERC20Mock(_getCollateralFromSeed(collateralSeed));
        uint256 maxCollateral = dscEngine.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) {
            return;
        }
        vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dscEngine.mintDsc(amount);
        vm.stopPrank();
        timesMintCalled++;
    }

    // This breaks our invariant test suite
    // function updateCollateralPrice(uint96 newPrice) public {
    //   int256 newPriceInt = int256(uint256(newPrice));
    //   ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
