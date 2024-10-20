//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    HelperConfig helperconfig;
    DSCEngine dscE;
    DecentralizedStableCoin dsc;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    uint256 amountToMint = 100 ether;
    uint256 debtToCover = 10 ether;
    uint256 public constant amountCollateral = 10 ether;

    uint256 public constant LIQUIDATION_THERSHOLD = 50;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    address public user2 = makeAddr("user2");
    address public USER = makeAddr("user");

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), amountCollateral);
        dscE.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), amountCollateral);
        dscE.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }


    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dscE, helperconfig) = deployer.run();
        (
            wethUsdPriceFeed,
            wbtcUsdPriceFeed,
            weth,
            wbtc,
            deployerKey
        ) = helperconfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    }

    ///////////////////////////////////
    ///    CONSTRUCTOR TEST   /////////
    ///////////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfPriceFeedsAndTokenLengthDoNotMatch() public {
        tokenAddresses.push(weth);

        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine_tokenAddressAndPriceFeedAddressShouldBeSame
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////////////////
    ////  DEPOSIT COLLATERAL TEST /////
    ///////////////////////////////////

    function testRevertWitUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock(
            "RAN",
            "RAN",
            USER,
            amountCollateral
        );
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedTokenAddress.selector);
        dscE.depositCollateral(address(ranToken), amountCollateral);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateralAndMintedDsc
    {
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = dscE
            .getAccountInformation(USER);

        uint256 expectedTotalDSCMinted = amountToMint;
        uint256 expectedCollateralAmount = dscE.getTokenAmountFromUsd(
            weth,
            collateralValueInUSD
        );
        assertEq(totalDscMinted, expectedTotalDSCMinted);
        assertEq(amountCollateral, expectedCollateralAmount);
    }

    function testDSCMinted() public depositedCollateralAndMintedDsc {
        (uint256 totalDscMinted, ) = dscE.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
    }

    ///////////////////////////////////
    ////  Burn COLLATERAL TEST /////
    ///////////////////////////////////



    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), amountCollateral);
        dscE.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(
            DSCEngine.DSCEngine_amountShouldBeGreaterThanZero.selector
        );
        dscE.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscE.burnDSC(1);
    }

    function testCanBurnDSC() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscE), amountToMint);
        dscE.burnDSC(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }


    ///////////////////////////////////
    ////  Reedem COLLATERAL TEST /////
    ///////////////////////////////////


    function testRevertIfReedemAmountIsZero() public depositedCollateral{
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_amountShouldBeGreaterThanZero.selector);
        dscE.reedemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanReedemCollateral() public depositedCollateral {
        vm.prank(USER);
        dscE.reedemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountCollateral);
    }
    

    ///////////////////////////////////
    ///     LIQUIDITY TEST     ////////
    ///////////////////////////////////

    // function testLiquidateFailsIfHealthFactorOk()
    //     public
    //     depositedCollateralAndMintedDsc
    // {
    //     vm.startPrank(user2);
    //     // dsc.approve(address(dscE), amountCollateral);
    //     // dscE.depositCollateralAndMintDSC(weth, amountCollateral, debtToCover);
    //     vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOk.selector);
    //     dscE.liquidate(weth, USER, debtToCover);
    //     vm.stopPrank();
    // }

    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(wethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));


        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
        mockDsce.depositCollateralAndMintDSC(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();



        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDSC(
            weth,
            collateralToCover,
            amountToMint
        );
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

  
    ///////////////////////////////////
    ///       PRICE TEST      /////////
    ///////////////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;

        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscE.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testRevertIfdepositCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), amountCollateral);

        vm.expectRevert(
            DSCEngine.DSCEngine_amountShouldBeGreaterThanZero.selector
        );
        dscE.depositCollateral(weth, 0);
        vm.stopPrank();
    }

}