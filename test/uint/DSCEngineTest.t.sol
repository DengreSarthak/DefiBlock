//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

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

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dscE, helperconfig) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) =
            helperconfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
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

        vm.expectRevert(DSCEngine.DSCEngine_tokenAddressAndPriceFeedAddressShouldBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////////////////// 
    ////  DEPOSIT COLLATERAL TEST /////
    ///////////////////////////////////

    function testRevertWitUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedTokenAddress.selector);
        dscE.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateralAndMintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = dscE.getAccountInformation(USER);

        uint256 expectedTotalDSCMinted = amountToMint;
        uint256 expectedCollateralAmount = dscE.getTokenAmountFromUsd(weth, collateralValueInUSD);
        assertEq(totalDscMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL , expectedCollateralAmount);
    }

    function testDSCMinted() public depositedCollateralAndMintedDsc{

        (uint256 totalDscMinted, ) = dscE.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
    }


    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine_amountShouldBeGreaterThanZero.selector);
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


    // 100,000,000,000,000,000,000





    /////////////////////////////////// 
    ///       PRICE TEST      /////////
    ///////////////////////////////////


    function testGetUsdValue() public view{
        uint256 ethAmount = 15e18;

        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscE.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }


    function testRevertIfdepositCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_amountShouldBeGreaterThanZero.selector);
        dscE.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}


