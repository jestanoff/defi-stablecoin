// SPDX-License-Identifier: MIT

// Have  our invariants

// What are our invariants?
// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should never revert < evergreen invariant

pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig}  from "../../script/HelperConfig.s.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";
import { console } from "forge-std/console.sol";

contract InvariantsTest is StdInvariant, Test {
  DeployDsc deployer;
  DscEngine dsce;
  DecentralizedStableCoin dsc;
  HelperConfig config;
  address weth;
  address wbtc;
  Handler handler;

  function setUp() external {
    deployer = new DeployDsc();
    (dsc, dsce, config) = deployer.run();
    (,, weth, wbtc,) = config.activeNetworkConfig();
    handler = new Handler(dsce, dsc);
    targetContract(address(handler));
    // targetContract(address(dsce));
    // hey don't call redeemcollateral unless there is collateral to redeem
  }

  function invariant_protocolMustHaveMoreValueThanTotalSupplyUsd() public view {
    // get the value of all the collateral in the protocol
    // compare it to all the debt (dsc.)
    uint256 totalSupply = dsc.totalSupply();
    uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(dsce));
    uint256 totalBtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

    uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
    uint256 wbtcValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

    console.log("wethValue: %s", wethValue);
    console.log("wbtcValue: %s", wbtcValue);

    assert(wethValue + wbtcValue >= totalSupply);
  }
}
