// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {MyLPVault, INonfungiblePositionManager, ISwapRouter02, IUniswapV3Pool} from "../src/MyLPVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestWETH9 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 a) external { _burn(msg.sender, a); payable(msg.sender).transfer(a); }
    receive() external payable { _mint(msg.sender, msg.value); }
}

contract TestUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

interface INPMFull {
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external payable returns (address);
    function ownerOf(uint256) external view returns (address);
}

interface IPoolFull {
    function increaseObservationCardinalityNext(uint16) external;
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

contract MyLPVaultTest is Test {
    // Base と同じアドレスに置いて、token0 = WETH / token1 = USDC の並びを再現する
    address constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
    address constant USDC_ADDR = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint24 constant FEE = 3000;
    uint160 constant SQRT_PRICE_2400 = 3881371428364983705067955;

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
        poolAddr = INPMFull(npm).createAndInitializePoolIfNecessary(WETH_ADDR, USDC_ADDR, FEE, SQRT_PRICE_2400);
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
                token0: WETH_ADDR,
                token1: USDC_ADDR,
                fee: FEE,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: 1000 ether,
                amount1Desired: 2_400_000e6,
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

    function test_Start_CentersRangeAroundPrice() public {
        _start(10 ether);
        assertGt(vault.positionId(), 0);
        assertTrue(vault.inRange());
        int24 t = _tick();
        assertLe(vault.tickLower(), t);
        assertGt(vault.tickUpper(), t);
        assertEq(vault.tickUpper() - vault.tickLower(), 600);
        assertGt(vault.liquidity(), 0);
        assertEq(INPMFull(npm).ownerOf(vault.positionId()), address(vault));
        // 余りは少ない（テスト用の浅いプールでも入れた額の 5% 未満）
        assertLt(weth.balanceOf(address(vault)), 0.5 ether);
    }

    function test_Start_RespectsMinOut() public {
        vm.prank(owner);
        vm.expectRevert(); // 受け取り最低額を高すぎる値にすると失敗する
        vault.start{value: 10 ether}(5000, 1_000_000e6);
    }

    function test_InRange_RebalanceRejected() public {
        _start(10 ether);
        _passTime(1 hours);
        assertFalse(vault.needsRebalance());
        vm.prank(keeper);
        vm.expectRevert(MyLPVault.InRange.selector);
        vault.rebalance();
    }

    function test_PriceUp_FollowsBelowPrice_NoSwap() public {
        _start(10 ether);
        int24 oldUpper = vault.tickUpper();
        _passTime(20 minutes);
        _pushUp(1_500_000e6); // 大きく買われて価格上昇
        int24 t = _tick();
        assertGt(t, oldUpper);

        // 直後は価格が不安定とみなして拒否される
        vm.prank(keeper);
        vm.expectRevert();
        vault.rebalance();

        _passTime(10 minutes);
        assertTrue(vault.needsRebalance());
        uint256 oldId = vault.positionId();
        vm.prank(keeper);
        vault.rebalance();

        assertTrue(vault.positionId() != oldId);
        assertLe(vault.tickUpper(), t); // 新しい範囲は価格のすぐ下
        assertGt(vault.tickUpper() + 60, t);
        assertEq(vault.tickUpper() - vault.tickLower(), 600);
        assertGt(vault.liquidity(), 0);
        // 中身は USDC だけで預け直され、USDC はほぼ金庫に残らない
        assertLt(usdc.balanceOf(address(vault)), 10e6);
    }

    function test_PriceDown_FollowsAbovePrice() public {
        _start(10 ether);
        int24 oldLower = vault.tickLower();
        _passTime(20 minutes);
        _pushDown(700 ether);
        int24 t = _tick();
        assertLt(t, oldLower);
        _passTime(10 minutes);
        vm.prank(keeper);
        vault.rebalance();
        assertGt(vault.tickLower(), t); // 新しい範囲は価格のすぐ上
        assertLe(vault.tickLower(), t + 60);
        assertGt(vault.liquidity(), 0);
        assertLt(weth.balanceOf(address(vault)), 0.001 ether);
    }

    function test_SlightlyOutOfRange_SameRange_NoRebalance() public {
        _start(10 ether);
        _passTime(20 minutes);
        // 範囲の上限をほんの少しだけ超える所まで上げる
        int24 upper = vault.tickUpper();
        uint256 step = 10_000e6;
        for (uint256 i; i < 200 && _tick() < upper; i++) _pushUp(step);
        assertGe(_tick(), upper);
        if (_tick() < upper + 60) {
            _passTime(10 minutes);
            assertFalse(vault.needsRebalance());
            vm.prank(keeper);
            vm.expectRevert(MyLPVault.InRange.selector);
            vault.rebalance();
        }
    }

    function test_TooSoon() public {
        _start(10 ether);
        _pushUp(1_500_000e6);
        _passTime(6 minutes); // TWAP は落ち着くが、開始から 10 分経っていない
        vm.warp(vault.lastRebalance() + 599);
        vm.prank(keeper);
        vm.expectRevert(MyLPVault.TooSoon.selector);
        vault.rebalance();
    }

    function test_SandwichAttempt_Blocked() public {
        _start(10 ether);
        _passTime(1 hours);
        // 攻撃者が一瞬で価格を動かし、ロボットに不利な位置で組み直させようとする
        _pushUp(1_500_000e6);
        vm.prank(keeper);
        vm.expectRevert();
        vault.rebalance();
        assertFalse(vault.needsRebalance());
    }

    function test_FeesToOwner() public {
        _start(10 ether);
        _passTime(10 minutes);
        // 範囲内で売買を往復させ、手数料を発生させる
        for (uint256 i; i < 10; i++) {
            _pushUp(20_000e6);
            _pushDown(8 ether);
        }
        uint256 wBefore = weth.balanceOf(owner);
        uint256 uBefore = usdc.balanceOf(owner);
        uint128 liqBefore = vault.liquidity();
        vm.prank(keeper);
        vault.collectFees();
        assertGt(weth.balanceOf(owner) + usdc.balanceOf(owner), wBefore + uBefore);
        assertEq(vault.liquidity(), liqBefore); // 元本はそのまま
    }

    function test_FeesStayInVault_WhenConfigured() public {
        vm.prank(owner);
        vault.setParams(600, 300, 100, 600, false);
        _start(10 ether);
        uint256 w0 = weth.balanceOf(address(vault));
        uint256 u0 = usdc.balanceOf(address(vault));
        for (uint256 i; i < 10; i++) {
            _pushUp(20_000e6);
            _pushDown(8 ether);
        }
        vm.prank(keeper);
        vault.collectFees();
        assertGt(weth.balanceOf(address(vault)) + usdc.balanceOf(address(vault)), w0 + u0);
        assertEq(weth.balanceOf(owner), 0);
    }

    function test_Exit_ReturnsEverythingToOwner() public {
        _start(10 ether);
        _passTime(20 minutes);
        _pushUp(1_500_000e6);
        _passTime(10 minutes);
        vm.prank(keeper);
        vault.rebalance();

        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        vault.exit(true);
        assertEq(vault.positionId(), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
        // 価格が上がったので中身は主に USDC で戻る
        assertGt(usdc.balanceOf(owner), 20_000e6);
        assertGe(owner.balance, ethBefore);
    }

    function test_KeeperAndStrangers_CannotTakeFunds() public {
        _start(10 ether);
        address[2] memory bad = [keeper, stranger];
        for (uint256 i; i < 2; i++) {
            vm.startPrank(bad[i]);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.exit(false);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.withdraw(WETH_ADDR, 1);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.withdrawETH(0);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.rescuePositionNFT();
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.closePosition();
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.ownerSwap(WETH_ADDR, 1, 0);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.setKeeper(bad[i]);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.setParams(600, 300, 100, 0, true);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.setPaused(true);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.addFunds(0, 0);
            vm.expectRevert(MyLPVault.NotOwner.selector);
            vault.prepareOracle(10);
            vm.stopPrank();
        }
        // 知らない人はロボットの操作もできない
        vm.startPrank(stranger);
        vm.expectRevert(MyLPVault.NotKeeperOrOwner.selector);
        vault.rebalance();
        vm.expectRevert(MyLPVault.NotKeeperOrOwner.selector);
        vault.collectFees();
        vm.stopPrank();
    }

    function test_Paused_BlocksKeeper() public {
        _start(10 ether);
        vm.prank(owner);
        vault.setPaused(true);
        _pushUp(1_500_000e6);
        _passTime(30 minutes);
        vm.prank(keeper);
        vm.expectRevert(MyLPVault.IsPaused.selector);
        vault.rebalance();
        // 一時停止中でも持ち主は引き出せる
        vm.prank(owner);
        vault.exit(false);
        assertEq(vault.positionId(), 0);
    }

    function test_RescueNFT() public {
        _start(10 ether);
        uint256 id = vault.positionId();
        vm.prank(owner);
        vault.rescuePositionNFT();
        assertEq(INPMFull(npm).ownerOf(id), owner);
        assertEq(vault.positionId(), 0);
    }

    function test_AddFunds() public {
        _start(10 ether);
        uint128 l0 = vault.liquidity();
        vm.prank(owner);
        vault.addFunds{value: 5 ether}(5000, 0);
        assertGt(vault.liquidity(), l0);
    }

    function test_ChangeKeeper() public {
        _start(10 ether);
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        vault.setKeeper(newKeeper);
        _pushUp(1_500_000e6);
        _passTime(30 minutes);
        vm.prank(keeper);
        vm.expectRevert(MyLPVault.NotKeeperOrOwner.selector);
        vault.rebalance();
        vm.prank(newKeeper);
        vault.rebalance();
    }

    function test_BadParamsRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(MyLPVault.BadParam.selector);
        vault.setParams(610, 300, 100, 600, true); // 刻み(60)の倍数でない
        vm.expectRevert(MyLPVault.BadParam.selector);
        vault.setParams(60, 300, 100, 600, true); // 狭すぎ
        vm.expectRevert(MyLPVault.BadParam.selector);
        vault.setParams(600, 10, 100, 600, true); // 平均期間が短すぎ
        vm.stopPrank();
    }

    /// 上下に何度も動かしても、最後に全額を持ち主に戻せる
    function test_ManyCycles_ThenExit() public {
        _start(10 ether);
        for (uint256 i; i < 6; i++) {
            _passTime(15 minutes);
            if (i % 2 == 0) _pushUp(1_500_000e6);
            else _pushDown(1_000 ether);
            _passTime(10 minutes);
            if (vault.needsRebalance()) {
                vm.prank(keeper);
                vault.rebalance();
            }
            assertGt(vault.liquidity(), 0);
        }
        vm.prank(owner);
        vault.exit(false);
        assertEq(weth.balanceOf(address(vault)) + usdc.balanceOf(address(vault)), 0);
        assertGt(weth.balanceOf(owner) + usdc.balanceOf(owner), 0);
    }

    /// 組み直しで価値が減らない（売買しないので、組み直し前後で受け取れる額がほぼ同じ）
    function test_Rebalance_PreservesValue() public {
        _start(10 ether);
        _passTime(20 minutes);
        _pushUp(1_500_000e6);
        _passTime(10 minutes);

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        vault.exit(false);
        uint256 usdcWithout = usdc.balanceOf(owner);
        uint256 wethWithout = weth.balanceOf(owner);
        vm.revertToState(snap);

        vm.prank(keeper);
        vault.rebalance();
        vm.prank(owner);
        vault.exit(false);
        uint256 usdcWith = usdc.balanceOf(owner);
        uint256 wethWith = weth.balanceOf(owner);

        assertEq(wethWith, wethWithout);
        assertApproxEqAbs(usdcWith, usdcWithout, 5); // 端数の誤差のみ
    }

    /// いろいろな大きさの値動きでも、組み直しが正しい側に置かれる
    function testFuzz_FollowDirection(uint256 amt, bool up) public {
        _start(10 ether);
        _passTime(20 minutes);
        if (up) _pushUp(bound(amt, 100_000e6, 3_000_000e6));
        else _pushDown(bound(amt, 50 ether, 1_500 ether));
        _passTime(10 minutes);
        int24 t = _tick();
        if (!vault.needsRebalance()) return;
        vm.prank(keeper);
        vault.rebalance();
        if (up) assertLe(vault.tickUpper(), t);
        else assertGt(vault.tickLower(), t);
        assertEq(vault.tickUpper() - vault.tickLower(), 600);
        assertEq(vault.tickLower() % 60, 0);
    }
}
