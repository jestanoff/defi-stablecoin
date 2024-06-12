//SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DscEngineTest is Test {
  DeployDsc deployer;
  DecentralizedStableCoin dsc;
  DscEngine engine;
  HelperConfig config;
  address ethUsdPriceFeed;
  address weth;
  uint256 AMOUNT_COLLATERAL = 10 ether;
  uint256 STARTING_ERC20_BALANCE = 10 ether;
  address USER = makeAddr('user');

  function setUp() public {
    deployer = new DeployDsc();
    (dsc, engine, config) = deployer.run();
    (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();
    ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
  }

  ////////////////////////////////
  // Price Tests /////////////////
  ////////////////////////////////

  function testGetUsdValue() public view {
    uint256 eathAmout = 15 ether; // 15e18
    uint256 expectedUsd = 30000e18; // 15e18 * 2000e18 = 30000e18
    uint256 actualUsd = engine.getUsdValue(weth, eathAmout);
    assertEq(expectedUsd, actualUsd, "getUsdValue should return the correct value");
  }

  ////////////////////////////////
  // DepositCollateral Tests /////
  ////////////////////////////////

  function testRevertsIfCollateralZero() public {
    vm.startPrank(USER);
    uint256 amountCollateral = 0;
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

    vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
    engine.depositCollateral(weth, amountCollateral);
    vm.stopPrank();
  }
}