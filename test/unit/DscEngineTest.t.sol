//SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DscEngine} from "../../src/DscEngine.sol";

contract DscEngineTest is Test {
  DeployDsc deployer;
  DecentralizedStableCoin dsc;
  DscEngine engine;
  HelperConfig config;
  address ethUsdPriceFeed;
  address weth;
  // address USER = addr(0x1);

  function setUp() public {
    deployer = new DeployDsc();
    (dsc, engine, config) = deployer.run();
    (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();
  }

  ////////////////////////////////
  // Price Tests /////////////////
  ////////////////////////////////

  function testGetUsdValue() public view {
    uint256 eathAmout = 15e18;
    uint256 expectedUsd = 30000e18;
    uint256 actualUsd = engine.getUsdValue(weth, eathAmout);
    assertEq(expectedUsd, actualUsd, "getUsdValue should return the correct value");
  }
}