// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

import {IDscEngine} from "./IDscEngine.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";

pragma solidity 0.8.26;

/**
 * @title DSCEngine
 * @author jestanoff
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmic Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WTBC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. Ih handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DscEngine is ReentrancyGuard {
    ////////////
    // Errors //
    ////////////
    error DscEngine__NeedsMoreThanZero();
    error DscEngine__TokenAdderssesAndPriceFeedAddressesMustBeSameLength();
    error DscEngine__TokenNotAllowed();
    error DscEngine__TransferFailed();
    error DscEngine__BreaksHealthFactor();
    error DscEngine__MintFailed();
    error DscEngine__HealthFactorOk();
    error DscEngine__HealthFactorNotImproved();

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DscEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DscEngine__TokenNotAllowed();
        }
        _;
    }

    /////////////////////
    // State variables //
    /////////////////////

    // Stable coin token addresses mapped to price feeds for that stable coin to fiat currency
    // For example, WETH => ETH/USD, WBTC => BTC/USD
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18; // 18 zeroes is the standard for Ethereum
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over-collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means 10%

    DecentralizedStableCoin private immutable i_dsc;

    ////////////
    // Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////
    // Functions //
    ///////////////

    /**
     * @param tokenAddresses The addresses of the tokens to use as collateral
     * @param priceFeedAddresses The addresses of the price feeds for the collateral tokens to USD
     * @param dscAddress The address of the DecentralizedStableCoin contract
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DscEngine__TokenAdderssesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i += 1) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the collateral to deposit
     * @param amountDscToMin The amount of decentralized stable coint to mint
     * @notice this function will depoist your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMin
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMin);
    }

    /**
     * To buy DSC, you must deposit collateral tokens
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the token to deposit as collateral
     * @notice follows CEI pattern (Checks-Effects-Interactions)
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        // Should the depositor first approve the amount on the wrapped token before depositing?
        // Or would the approval be done via his wallet?
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DscEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress The address of the token to redeem as collateral
     * @param amountCollateral The amount of the token to redeem as collateral
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // Threshold to let's say 150%
    // $100 ETH -> $74 ETH
    // $50 DSC
    // UNDERCOLLATERALIZED!!!

    // Hey, if someone pays your minted DSC, they can have all your collateral for a discount
    // In order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral is pulled out
    // CEI: check, effect, interaction
    /**
     * When you decide you want your collateral back, you can withdraw it from the system
     * @param tokenCollateralAddress The address of the token to redeem as collateral
     * @param amountCollateral The amount of the token to redeem as collateral
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI pattern (Checks-Effects-Interactions)
     * @param amountDscToMint The amount of decentralized stable coint to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // Check if the collateral amount > than DSC amount. Which involves checking price feeds and value of collateral
        // mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
        s_DscMinted[msg.sender] += amountDscToMint;

        // If they minted too much DSC revert the transaction
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DscEngine__MintFailed();
        }
    }

    /**
     * @param amount The amount of DSC to burn
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // In the event that ETH tanks down from $100 to say $50, the collateral value wouldn't be enough to cover the DSC minted
    // In that case some position would be undercollateralized
    // When somone is close to be undercollateralized, we will pay you to liquidate them
    /**
      * @param collateral The ERC20 collateral address to liquidate from the user
      * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
      * @notice You can partially liquidate a user
      * @notice You will get a luquidation bonus for taking the user funds
      * @notice This function working assumes the protocol will be roughlt 200% overcollateralized in order for this to work
      * @notice A know bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
      * For example, if the price of the collateral plummeted before anyone could be liquidated.
      * 
      * Follows CEI: Checks, Effects, Interactions
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DscEngine__HealthFactorOk();
        }
        // We want to burn their DSC "debt: and take their collateral
        // Bad UserL $140 ETH, $100 DSC. 1.4 health factor
        // debtToCover = $100
        // $100 of DSC == ??? ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        // 0.05 * 0.1 = 0.005 getting 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateral = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateral);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DscEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////
    // Private & Internal Functions //
    ///////////////////////////////////

    /**
     * @dev Low-level internal function, do not call unless the function calling it is 
     * checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DscEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        if (!success) {
            revert DscEngine__TransferFailed();
        }
    }

    /**
     * @param user The user to get the account information for
     * @return totalDscMinted
     * @return collateralValueInUsd
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @param user The user to get the health factor for
     * @return The health factor of the user
     * @notice Returns how close to liquidation a user is
     * If a user goes below 1, then they are can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION / totalDscMinted);
    }

    /**
     * @param user The user to check the health factor for
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DscEngine__BreaksHealthFactor();
        }
    }

    ///////////////////////////////////////
    // Public & External View Functions //
    //////////////////////////////////////
    /**
     * @param user The user to get the account information for
     * @return totalCollateralValueInUsd The total value of the collateral in USD
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @param token The token to get the USD value for
     * @param amount The amount of the token to get the USD value for
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from Chainlink will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e8 * (1e10)) * 1000 / 1e18
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns (uint256) {
      // In case they haven't minted any DSC yet we return the max value
      // as otherwise we would be dividing by zero
      if (totalDscMinted == 0) return type(uint256).max;
      uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
      return (collateralAdjustedForThreshold * PRECISION / totalDscMinted);
    }

    function getPrecision() external pure returns (uint256) {
      return PRECISION;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns (uint256) {
      return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getLiquidationBonus() external pure returns (uint256) {
      return LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
      return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
      return s_collateralTokens;
    }

    function getMinHealthFactor() external pure returns (uint256) {
      return MIN_HEALTH_FACTOR;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
      return LIQUIDATION_THRESHOLD;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
      return s_collateralDeposited[user][token];
    }

    function getDsc() external view returns (address) {
      return address(i_dsc);
    }

    /**
     * @param token The token to get the amount of tokens from USD
     * @param usdAmountInWei The amount of USD to get the token amount for
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH ??
        // there is $1000DSC
        // and ETH is equal to $2000USD
        // $2000 / $1000= 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // $10e18 * 1e18 / ($2000e8 * 1e10) = 0.005
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
      (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}
