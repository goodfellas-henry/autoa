// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {MyLPVault, INonfungiblePositionManager, ISwapRouter02} from "../src/MyLPVault.sol";
import {TestWETH9, TestUSDC, INPMFull, IPoolFull} from "./MyLPVault.t.sol";

/// USDC が token0、WETH が token1 になる並び順でも正しく動くことの確認
contract MyLPVaultReversedTest is Test {
    // Base と同じアドレスに置いて、token0 = WETH / token1 = USDC の並びを再現する
    address constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
    address constant USDC_ADDR = 0x0000000000000000000000000000000000001234;
    uint24 constant FEE = 3000;
    uint160 constant SQRT_PRICE_2400 = 1617238095152076543778314735768381;

    TestWETH9 weth;
    TestUSDC usdc;
    address factory;
    address npm;
    address router;
    address poolAddr;
    MyLPVault vault;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address whale = makeAddr("whale");
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");

    function _deployArtifact(string memory path, bytes memory args) internal returns (address a) {
        string memory json = vm.readFile(path);
        bytes memory code = abi.encodePacked(vm.parseJsonBytes(json, ".bytecode"), args);
        assembly { a := create(0, add(code, 0x20), mload(code)) }
        require(a != address(0), "deploy failed");
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        deployCodeTo("MyLPVault.t.sol:TestWETH9", WETH_ADDR);
        deployCodeTo("MyLPVault.t.sol:TestUSDC", USDC_ADDR);
        weth = TestWETH9(payable(WETH_ADDR));
        usdc = TestUSDC(USDC_ADDR);

        factory = _deployArtifact(
            "node_modules/@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json", ""
        );
        npm = _deployArtifact(
            "node_modules/@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json",
            abi.encode(factory, WETH_ADDR, address(0))
        );
        router = _deployArtifact(
            "node_modules/@uniswap/swap-router-contracts/artifacts/contracts/SwapRouter02.sol/SwapRouter02.json",
            abi.encode(address(0), factory, npm, WETH_ADDR)
        );
        poolAddr = INPMFull(npm).createAndInitializePoolIfNecessary(USDC_ADDR, WETH_ADDR, FEE, SQRT_PRICE_2400);
        IPoolFull(poolAddr).increaseObservationCardinalityNext(500);

        // 大口の流動性（全範囲）: 1000 ETH + 2,400,000 USDC
        vm.deal(whale, 1000 ether);
        vm.startPrank(whale);
        weth.deposit{value: 1000 ether}();
        usdc.mint(whale, 2_400_000e6);
        weth.approve(npm, type(uint256).max);
        usdc.approve(npm, type(uint256).max);
        INonfungiblePositionManager(npm).mint(
            INonfungiblePositionManager.MintParams({
                token0: USDC_ADDR,
                token1: WETH_ADDR,
                fee: FEE,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: 2_400_000e6,
                amount1Desired: 1000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: whale,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        // 取引をする人
        vm.deal(trader, 10_000 ether);
        vm.startPrank(trader);
        weth.deposit{value: 5_000 ether}();
        usdc.mint(trader, 50_000_000e6);
        weth.approve(router, type(uint256).max);
        usdc.approve(router, type(uint256).max);
        vm.stopPrank();

        _passTime(1 hours);

        // 持ち主が金庫を作る（幅 600 tick ≒ ±3%）
        vm.prank(owner);
        vault = new MyLPVault(npm, router, WETH_ADDR, USDC_ADDR, FEE, keeper, 600);
        vm.deal(owner, 100 ether);
    }

    // ------------------------------------------------------------ helpers
    function _passTime(uint256 s) internal {
        vm.warp(block.timestamp + s);
        vm.roll(block.number + s / 2);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,,,,) = IPoolFull(poolAddr).slot0();
    }

    function _swap(address tokenIn, uint256 amountIn) internal {
        address tokenOut = tokenIn == WETH_ADDR ? USDC_ADDR : WETH_ADDR;
        vm.prank(trader);
        ISwapRouter02(router).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams(tokenIn, tokenOut, FEE, trader, amountIn, 0, 0)
        );
    }

    /// 価格を上げる（USDC で WETH を買う）
    function _pushUp(uint256 usdcIn) internal { _swap(USDC_ADDR, usdcIn); }
    /// 価格を下げる（WETH を売る）
    function _pushDown(uint256 wethIn) internal { _swap(WETH_ADDR, wethIn); }

    function _start(uint256 ethIn) internal {
        vm.prank(owner);
        vault.start{value: ethIn}(5000, 0);
    }

    function _vaultValueUsdc() internal view returns (uint256) {
        // 金庫の残高 + ポジションの中身を、現在価格の USDC に換算（概算）
        (uint160 sp,,,,,,) = IPoolFull(poolAddr).slot0();
        uint256 price = uint256(sp) * uint256(sp) * 1e18 >> 192; // USDC(6桁) per 1 WETH
        uint256 w = weth.balanceOf(address(vault));
        uint256 u = usdc.balanceOf(address(vault));
        return u + w * price / 1e18;
    }

    // ------------------------------------------------------------ tests
    function test_Rev_StartAndFollowBothWays() public {
        _start(10 ether);
        assertTrue(vault.inRange());
        assertEq(vault.token0(), USDC_ADDR);
        for (uint256 i; i < 4; i++) {
            _passTime(15 minutes);
            if (i % 2 == 0) _pushUp(1_500_000e6); // ETH 値上がり（この並びでは tick は下がる）
            else _pushDown(1_000 ether);
            _passTime(10 minutes);
            int24 t = _tick();
            if (vault.needsRebalance()) {
                vm.prank(keeper);
                vault.rebalance();
                // 新しい範囲は価格に隣接し、範囲外（片側）である
                assertTrue(vault.tickUpper() <= t || vault.tickLower() > t);
                assertGt(vault.liquidity(), 0);
            }
        }
        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        vault.exit(true);
        assertEq(weth.balanceOf(address(vault)) + usdc.balanceOf(address(vault)), 0);
        assertGt(owner.balance - ethBefore + usdc.balanceOf(owner), 0);
    }

    function test_Rev_KeeperCannotWithdraw() public {
        _start(10 ether);
        vm.prank(keeper);
        vm.expectRevert(MyLPVault.NotOwner.selector);
        vault.exit(false);
    }
}
