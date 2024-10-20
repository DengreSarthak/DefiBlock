// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
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
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "../node_modules/@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    error DSCEngine_amountShouldBeGreaterThanZero();
    error DSCEngine_tokenAddressAndPriceFeedAddressShouldBeSame();
    error DSCEngine_NotAllowedTokenAddress();
    error DCSEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor();
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address tokenCollateral => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amoount)) private s_CollateralDeposited;
    mapping(address user => uint256 amountDSC) s_DSCMinted;

    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed user,
        address indexed to,
        address indexed tokenm,
        uint256 amount
    );

    modifier moreThanZero(uint256 amountCollateral) {
        if (amountCollateral <= 0) {
            revert DSCEngine_amountShouldBeGreaterThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedTokenAddress();
        }
        _;
    }

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddress,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine_tokenAddressAndPriceFeedAddressShouldBeSame();
        }
        for (uint256 i = 0; i < priceFeedAddress.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_CollateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DCSEngine_TransferFailed();
        }
    }

    function mintDSC(
        uint256 amountDSCToMint
    ) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) public moreThanZero(amountCollateral) {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    function reedemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _reedemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC(uint256 amount) external moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // Don't think we need this
    }

    function reedemCollateralForDSC(
        address tokenCollateral,
        uint256 amountCollateral,
        uint256 amountDSCToBurn
    )
        external
        moreThanZero(amountCollateral)
        moreThanZero(amountDSCToBurn)
        nonReentrant
    {
        _burnDSC(amountDSCToBurn, msg.sender, msg.sender);
        _reedemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateral,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }

        uint256 tokenAmountFromDebitCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebitCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToReedem = tokenAmountFromDebitCovered +
            bonusCollateral;

        _reedemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToReedem
        );
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external {}

    /////////////PRIVATE & INTERNAL////////////////////////////

    function _burnDSC(
        uint256 amountDSCToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDSCToBurn
        );
        if (!success) {
            revert DCSEngine_TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    function _reedemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_CollateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );

        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DCSEngine_TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUSD)
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValueInUSD = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDSCMinted,
            uint256 totalCollateralValueInUSD
        ) = _getAccountInformation(user);
        return
            _calculateHealthFactor(totalDSCMinted, totalCollateralValueInUSD);
    }

    function _calculateHealthFactor(
        uint256 totalDSCMinted,
        uint256 totalCollateralValueInUSD
    ) internal pure returns (uint256) {
        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (totalCollateralValueInUSD *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor();
        }
    }

    /// Publlic Functionns

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUSD) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_CollateralDeposited[user][token];
            totalCollateralValueInUSD += getUsdValue(token, amount);
        }
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUSD)
    {
        (totalDscMinted, totalCollateralValueInUSD) = _getAccountInformation(
            user
        );
    }

    // getter 


     function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256) {
        return s_CollateralDeposited[user][token];
    }
}