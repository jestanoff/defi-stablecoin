//SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract DscEngineTest is Test {
  DeployDsc deployer;
  DecentralizedStableCoin dsc;
  DscEngine engine;
  HelperConfig config;
  address ethUsdPriceFeed;
  address btcUsdPriceFeed;
  address weth;
  address wbtc;
  uint256 AMOUNT_COLLATERAL = 10 ether;
  uint256 STARTING_ERC20_BALANCE = 10 ether;
  address USER = makeAddr('user');

  modifier depositCollateral() {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    engine.depositCollateral(weth, AMOUNT_COLLATERAL);
    vm.stopPrank();
    _;
  }

  function setUp() public {
    deployer = new DeployDsc();
    (dsc, engine, config) = deployer.run();
    (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config.activeNetworkConfig();
    ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
  }

  ////////////////////////////////
  // Constructur Test ////////////
  ////////////////////////////////
  address[] public tokenAddresses;
  address[] public priceFeedAddresses;

  function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
    tokenAddresses.push(weth);
    priceFeedAddresses.push(ethUsdPriceFeed);
    priceFeedAddresses.push(btcUsdPriceFeed);

    vm.expectRevert(DscEngine.DscEngine__TokenAdderssesAndPriceFeedAddressesMustBeSameLength.selector);
    new DscEngine(tokenAddresses, priceFeedAddresses, address(dsc));
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

  function testGetTokenAmountFromUsd() public view {
    uint256 usdAmount = 100 ether;
    // $2000 per ETH, $100
    uint256 expectedWeth = 0.05 ether;
    uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
    assertEq(expectedWeth, actualWeth, "getTokenAmountFromUsd should return the correct value");  
  }

  ////////////////////////////////
  // DepositCollateral Tests /////
  ////////////////////////////////

  function testRevertsDepositCollateralIfCollateralZero() public {
    vm.startPrank(USER);
    uint256 amountCollateral = 0;
    ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

    vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
    engine.depositCollateral(weth, amountCollateral);
    vm.stopPrank();
  }
  
  function testRevertsDepositCollateralWithUnapprovedCollateral() public {
    ERC20Mock fancyToken = new ERC20Mock();
    vm.startPrank(USER);
    vm.expectRevert(DscEngine.DscEngine__TokenNotAllowed.selector);
    engine.depositCollateral(address(fancyToken), AMOUNT_COLLATERAL);
    vm.stopPrank();
  }

  // function testRevertsDepositCollateralOnReentrancy() public {
  //   uint256 amountCollateral = 1 ether;
  //   vm.startPrank(USER);
  //   ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
  //   vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
  //   engine.depositCollateral(weth, amountCollateral);
  //   // engine.depositCollateral(weth, amountCollateral);
  //   vm.stopPrank();
  // }

  function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

    uint256 expectedTotalDscMinted = 0;
    uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
    assertEq(totalDscMinted, expectedTotalDscMinted);
    assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
  }

  function test
}