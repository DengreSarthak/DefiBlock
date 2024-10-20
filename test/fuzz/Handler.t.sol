//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol"; 
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dscE;
    DecentralizedStableCoin dsc;
    
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timeMintIsCalled = 0;
    uint256 public timeDepositIsCalled = 0;
    uint256 public timeReedemIsCalled = 0;

    uint256 MAX_DEPOSIT_SIZE = type(uint16).max;

    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscE = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscE.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscE.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(dscE.getCollateralTokenPriceFeed(address(wbtc)));
    }

    function depositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        // Proceed to deposit collateral

        vm.startPrank(msg.sender);
        collateral.approve(address(dscE), amountCollateral);       
        collateral.mint(msg.sender, amountCollateral);
        dscE.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
        timeDepositIsCalled++;
    }

    function reedemCollateral(uint256 collateralSeed, uint256 amountCollateral, uint256 addressSeed) public {

        if(usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = dscE.getCollateralBalanceOfUser(sender, address(collateral));
        (uint256 totalDSCMinted, ) = dscE.getAccountInformation(sender);

        // console.log("collateral value:  %s and %s = ", maxCollateral, totalDSCMinted);

        if(maxCollateral < totalDSCMinted) {
            return;
        }
        maxCollateral -= totalDSCMinted;
        amountCollateral = bound(amountCollateral, 0, maxCollateral);

        if (amountCollateral == 0) {
            return;
        }
        vm.startPrank(sender);
        dscE.reedemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        timeReedemIsCalled++;
    }

    function mintDSC(uint256 amount, uint256 addressSeed) public {
        if(usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = dscE.getAccountInformation(sender);

        if (collateralValueInUsd / 2 < totalDSCMinted) {
            return;
        }
        uint256 maxDSCToMint = (collateralValueInUsd / 2) - totalDSCMinted;
        
        // int256 maxDSCToMint = (int256(collateralValueInUsd)/2) - int256(totalDSCMinted);
        if(maxDSCToMint < 0) {
            return;
        }

        amount = bound(amount, 0, maxDSCToMint);
        if(amount == 0) {
            return;
        }

        vm.startPrank(sender);
        dscE.mintDSC(amount);
        vm.stopPrank();

        timeMintIsCalled++;
    }

    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // must be more than 0
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);


        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscE), amountCollateral);
        dscE.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper function

    function _getCollateralFromSeed(uint256 collateralSeed) public view returns(ERC20Mock) {
        if(collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;        
    }
}

