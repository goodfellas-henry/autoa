// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {MyLPVault, INonfungiblePositionManager, ISwapRouter02} from "../src/MyLPVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestWETH9, INPMFull, IPoolFull} from "./MyLPVault.t.sol";

contract TestCbBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}
    function decimals() public pure override returns (uint8) { return 8; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// BTC/ETH（cbBTC は 8 桁、WETH が token0）の金庫が正しく動くことの確認
contract MyLPVaultBtcTest is Test {
    address constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
    address constant CBBTC_ADDR = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint24 constant FEE = 500;
    // 1 BTC = 45.8 ETH
    uint160 constant SQRT_PRICE = 117070330589512434866634;

    TestWETH9 weth;
    TestCbBTC btc;
    address factory;
    address npm;
    address router;
    address poolAddr;
    MyLPVault vault;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address whale = makeAddr("whale");
    address trader = makeAddr("trader");

    function _deployArtifact(string memory path, bytes memory args) internal returns (address a) {
        string memory json = vm.readFile(path);
        bytes memory code = abi.encodePacked(vm.parseJsonBytes(json, ".bytecode"), args);
        assembly { a := create(0, add(code, 0x20), mload(code)) }
        require(a != address(0), "deploy failed");
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        deployCodeTo("MyLPVault.t.sol:TestWETH9", WETH_ADDR);
        deployCodeTo("MyLPVaultBtc.t.sol:TestCbBTC", CBBTC_ADDR);
        weth = TestWETH9(payable(WETH_ADDR));
        btc = TestCbBTC(CBBTC_ADDR);
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
        poolAddr = INPMFull(npm).createAndInitializePoolIfNecessary(WETH_ADDR, CBBTC_ADDR, FEE, SQRT_PRICE);
        IPoolFull(poolAddr).increaseObservationCardinalityNext(500);

        // 大口の流動性: 1000 ETH + 21.834 BTC
        vm.deal(whale, 1000 ether);
        vm.startPrank(whale);
        weth.deposit{value: 1000 ether}();
        btc.mint(whale, 2_183_400_000);
        weth.approve(npm, type(uint256).max);
        btc.approve(npm, type(uint256).max);
        INonfungiblePositionManager(npm).mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH_ADDR,
                token1: CBBTC_ADDR,
                fee: FEE,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 ether,
                amount1Desired: 2_183_400_000,
                amount0Min: 0,
                amount1Min: 0,
                recipient: whale,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        vm.deal(trader, 10_000 ether);
        vm.startPrank(trader);
        weth.deposit{value: 5_000 ether}();
        btc.mint(trader, 200e8);
        weth.approve(router, type(uint256).max);
        btc.approve(router, type(uint256).max);
        vm.stopPrank();

        _passTime(1 hours);

        // ±3% 相当（spacing 10 → 590 tick）
        vm.prank(owner);
        vault = new MyLPVault(npm, router, WETH_ADDR, CBBTC_ADDR, FEE, keeper, 590);
        vm.deal(owner, 100 ether);
    }

    function _passTime(uint256 s) internal {
        vm.warp(block.timestamp + s);
        vm.roll(block.number + s / 2);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,,,,) = IPoolFull(poolAddr).slot0();
    }

    function _swap(address tokenIn, uint256 amountIn) internal {
        address tokenOut = tokenIn == WETH_ADDR ? CBBTC_ADDR : WETH_ADDR;
        vm.prank(trader);
        ISwapRouter02(router).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams(tokenIn, tokenOut, FEE, trader, amountIn, 0, 0)
        );
    }

    function test_Btc_TokenOrderAndSpacing() public view {
        assertEq(vault.token0(), WETH_ADDR);
        assertEq(vault.token1(), CBBTC_ADDR);
        assertEq(vault.tickSpacing(), 10);
    }

    /// 操作画面と同じ計算の minOut（想定 −1%）で開始できる
    function test_Btc_StartWithDashboardMinOut() public {
        // 5 ETH の半分 = 2.5 ETH → 2.5 / 45.8 BTC × (1 − 0.05%) × 0.99
        uint256 minOut = uint256(2.5e8) * 10 / 458 * 9995 / 10000 * 99 / 100; // ≒ 0.0540 BTC
        vm.prank(owner);
        vault.start{value: 5 ether}(5000, minOut);
        assertTrue(vault.inRange());
        assertGt(vault.liquidity(), 0);
        // 余りは少しだけ
        assertLt(weth.balanceOf(address(vault)), 0.2 ether);
    }

    /// minOut を高くしすぎると交換が中止される（サンドイッチ対策が効いている）
    function test_Btc_StartRevertsOnBadMinOut() public {
        vm.prank(owner);
        vm.expectRevert();
        vault.start{value: 5 ether}(5000, 0.06e8);
    }

    function test_Btc_FollowBothWaysAndExit() public {
        vm.prank(owner);
        vault.start{value: 10 ether}(5000, 0);
        uint256 rebalances;
        for (uint256 i; i < 4; i++) {
            _passTime(15 minutes);
            if (i % 2 == 0) _swap(WETH_ADDR, 800 ether); // ETH を売る → BTC が ETH 建てで上がる
            else _swap(CBBTC_ADDR, 30e8);
            _passTime(10 minutes);
            int24 t = _tick();
            if (vault.needsRebalance()) {
                vm.prank(keeper);
                vault.rebalance();
                rebalances++;
                assertTrue(vault.tickUpper() <= t || vault.tickLower() > t);
                assertGt(vault.liquidity(), 0);
            }
        }
        assertGt(rebalances, 0);
        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        vault.exit(true);
        assertEq(weth.balanceOf(address(vault)) + btc.balanceOf(address(vault)), 0);
        assertGt(owner.balance - ethBefore + btc.balanceOf(owner), 0);
    }

    function test_Btc_KeeperCannotWithdraw() public {
        vm.prank(owner);
        vault.start{value: 1 ether}(5000, 0);
        vm.startPrank(keeper);
        vm.expectRevert(MyLPVault.NotOwner.selector);
        vault.exit(false);
        vm.expectRevert(MyLPVault.NotOwner.selector);
        vault.withdraw(CBBTC_ADDR, 1);
        vm.stopPrank();
    }
}
