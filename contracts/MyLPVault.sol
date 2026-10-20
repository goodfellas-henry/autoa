// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * MyLPVault
 * ---------------------------------------------------------------------------
 * 自分専用の Uniswap V3 自動運用金庫（Base 用）。
 *
 * 安全の約束（コードで強制）:
 *   1. 持ち主(owner)は作った人で固定。後から変えられない。
 *   2. お金を外に出す関数は持ち主しか呼べず、送り先は必ず持ち主。
 *   3. ロボット(keeper)にできるのは「範囲の追従」と「手数料の回収」だけ。
 *      ロボットは交換(スワップ)もできず、価格帯も自分では選べない
 *      （価格帯は金庫が現在価格から自動で計算する）。
 *   4. 価格を一瞬だけ動かす攻撃への対策として、直近の平均価格(TWAP)と
 *      今の価格が離れすぎている時は、組み直しを拒否する。
 *   5. プログラムの書き換え(アップグレード)機能はない。
 *
 * 運用方針: 「範囲だけ追いかける」
 *   価格が範囲の上に抜けた → 中身はすべて token1。現在価格のすぐ下に新しい範囲を置く。
 *   価格が範囲の下に抜けた → 中身はすべて token0。現在価格のすぐ上に新しい範囲を置く。
 *   組み直しで売買(スワップ)はしない。
 */

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
    function feeAmountTickSpacing(uint24) external view returns (int24);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function increaseObservationCardinalityNext(uint16 next) external;
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function factory() external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        );
    function mint(MintParams calldata)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata) external payable returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external payable;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256 amountOut);
}

contract MyLPVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ 定数
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint32 public constant MIN_TWAP_WINDOW = 60; // 1分
    uint32 public constant MAX_TWAP_WINDOW = 3600; // 1時間
    uint32 public constant MAX_REBALANCE_INTERVAL = 1 days;

    // ------------------------------------------------------------------ 固定値
    address public immutable owner;
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter02 public immutable swapRouter;
    IWETH9 public immutable weth;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    IUniswapV3Pool public immutable pool;

    // ------------------------------------------------------------------ 設定
    address public keeper;
    bool public paused;
    bool public feesToOwner; // true: 手数料は回収のたびに持ち主の財布へ / false: 金庫に残し次の組み直しで再投資
    int24 public rangeWidth; // 価格帯の幅（tick数、tickSpacing の倍数）
    uint32 public twapWindow; // 平均価格を取る期間（秒）
    int24 public maxTwapDeviation; // 今の価格と平均価格のずれの上限（tick）
    uint32 public minRebalanceInterval; // 組み直しの最短間隔（秒）

    // ------------------------------------------------------------------ 状態
    uint256 public positionId; // 0 = 運用中のポジションなし
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public lastRebalance;

    // ------------------------------------------------------------------ イベント
    event Started(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event Rebalanced(uint256 indexed oldId, uint256 indexed newId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event FeesCollected(uint256 amount0, uint256 amount1, bool sentToOwner);
    event PositionClosed(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed token, uint256 amount);
    event KeeperChanged(address keeper);
    event ParamsChanged(int24 rangeWidth, uint32 twapWindow, int24 maxTwapDeviation, uint32 minInterval, bool feesToOwner);
    event PausedChanged(bool paused);

    // ------------------------------------------------------------------ エラー
    error NotOwner();
    error NotKeeperOrOwner();
    error IsPaused();
    error HasPosition();
    error NoPosition();
    error InRange();
    error TooSoon();
    error PriceUnstable(int24 tick, int24 twapTick);
    error BadParam();
    error EthTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner) revert NotKeeperOrOwner();
        _;
    }

    constructor(
        address _positionManager,
        address _swapRouter,
        address _weth,
        address _otherToken,
        uint24 _fee,
        address _keeper,
        int24 _rangeWidth
    ) {
        owner = msg.sender;
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter02(_swapRouter);
        weth = IWETH9(_weth);
        (token0, token1) = _weth < _otherToken ? (_weth, _otherToken) : (_otherToken, _weth);
        fee = _fee;

        IUniswapV3Factory factory = IUniswapV3Factory(positionManager.factory());
        int24 spacing = factory.feeAmountTickSpacing(_fee);
        address _pool = factory.getPool(token0, token1, _fee);
        if (spacing <= 0 || _pool == address(0)) revert BadParam();
        tickSpacing = spacing;
        pool = IUniswapV3Pool(_pool);

        keeper = _keeper;
        _setParams(_rangeWidth, 300, 100, 600, true);
    }

    receive() external payable {}

    // ================================================================== 持ち主の操作

    /// @notice 運用を始める。送ったETHと金庫内の残高で、現在価格を中心とした範囲に預ける。
    /// @param swapBps 預ける前に WETH の何割を相手の通貨に交換するか（1万分率。5000 = 半分）
    /// @param minOut 交換で最低限受け取る量（画面側で現在価格から計算して渡す）
    function start(uint16 swapBps, uint256 minOut) external payable onlyOwner nonReentrant {
        if (positionId != 0) revert HasPosition();
        _checkPriceStable(); // 交換の前に、価格が操作されていないか確認する
        _wrapAndSwap(swapBps, minOut);

        (, int24 tick,,,,,) = pool.slot0();
        int24 lower = _floorTick(tick - rangeWidth / 2);
        int24 upper = lower + rangeWidth;
        _checkTicks(lower, upper);

        (uint256 id, uint128 liq) = _mint(lower, upper);
        lastRebalance = block.timestamp;
        emit Started(id, lower, upper, liq);
    }

    /// @notice 運用中のポジションに資金を追加する。
    function addFunds(uint16 swapBps, uint256 minOut) external payable onlyOwner nonReentrant {
        if (positionId == 0) revert NoPosition();
        _checkPriceStable();
        _wrapAndSwap(swapBps, minOut);
        (uint256 b0, uint256 b1) = _balances();
        _approve(token0, b0);
        _approve(token1, b1);
        positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: b0,
                amount1Desired: b1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        _approve(token0, 0);
        _approve(token1, 0);
    }

    /// @notice ポジションを閉じる（お金は金庫に残る）。設定を変えて start し直したい時に使う。
    function closePosition() external onlyOwner nonReentrant {
        _closePosition();
    }

    /// @notice 全部やめる。ポジションを閉じ、全額を持ち主の財布へ送る。
    /// @param unwrap true なら WETH を ETH に戻して送る
    function exit(bool unwrap) external onlyOwner nonReentrant {
        if (positionId != 0) _closePosition();
        _sendAll(unwrap);
    }

    /// @notice 金庫にある通貨を持ち主に送る（送り先は持ち主に固定）。
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(owner, amount);
        emit Withdrawn(token, amount);
    }

    /// @notice 金庫にある ETH を持ち主に送る。
    function withdrawETH(uint256 amount) external onlyOwner nonReentrant {
        _sendEth(amount);
        emit Withdrawn(address(0), amount);
    }

    /// @notice 緊急用：運用中のポジション(NFT)を、そのまま持ち主の財布へ移す。
    ///         移した後は Uniswap の公式サイトで自分で管理できる。
    function rescuePositionNFT() external onlyOwner nonReentrant {
        uint256 id = positionId;
        if (id == 0) revert NoPosition();
        positionId = 0;
        positionManager.safeTransferFrom(address(this), owner, id);
    }

    /// @notice 金庫内で通貨を交換する（持ち主のみ）。
    function ownerSwap(address tokenIn, uint256 amountIn, uint256 minOut) external onlyOwner nonReentrant returns (uint256) {
        if (tokenIn != token0 && tokenIn != token1) revert BadParam();
        return _swap(tokenIn, amountIn, minOut);
    }

    /// @notice プールの価格記録の保存数を増やす（平均価格の計算に必要。通常は不要）。
    function prepareOracle(uint16 cardinality) external onlyOwner {
        pool.increaseObservationCardinalityNext(cardinality);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperChanged(_keeper);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedChanged(_paused);
    }

    function setParams(
        int24 _rangeWidth,
        uint32 _twapWindow,
        int24 _maxTwapDeviation,
        uint32 _minInterval,
        bool _feesToOwner
    ) external onlyOwner {
        _setParams(_rangeWidth, _twapWindow, _maxTwapDeviation, _minInterval, _feesToOwner);
    }

    // ================================================================== ロボットの操作

    /// @notice 価格が範囲から外れていたら、範囲だけを価格に追従させる（売買はしない）。
    function rebalance() external onlyKeeperOrOwner nonReentrant {
        if (paused) revert IsPaused();
        uint256 oldId = positionId;
        if (oldId == 0) revert NoPosition();
        if (block.timestamp < lastRebalance + minRebalanceInterval) revert TooSoon();
        int24 tick = _checkPriceStable();

        (bool needed, int24 lower, int24 upper) = _targetRange(tick);
        if (!needed) revert InRange();
        _checkTicks(lower, upper);

        _closePosition();
        (uint256 newId, uint128 liq) = _mint(lower, upper);
        lastRebalance = block.timestamp;
        emit Rebalanced(oldId, newId, lower, upper, liq);
    }

    /// @notice たまった手数料を回収する。設定に応じて持ち主へ送るか、金庫に残す。
    function collectFees() external onlyKeeperOrOwner nonReentrant {
        if (paused) revert IsPaused();
        if (positionId == 0) revert NoPosition();
        _collectFees();
    }

    // ================================================================== 表示用

    function currentTick() external view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
    }

    function twapTick() public view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        ago[1] = 0;
        (int56[] memory cum,) = pool.observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 window = int56(uint56(twapWindow));
        int24 avg = int24(delta / window);
        if (delta < 0 && (delta % window != 0)) avg--;
        return avg;
    }

    function inRange() external view returns (bool) {
        if (positionId == 0) return false;
        (, int24 tick,,,,,) = pool.slot0();
        return tick >= tickLower && tick < tickUpper;
    }

    /// @notice ロボット用：今 rebalance を呼ぶべきか
    function needsRebalance() external view returns (bool) {
        if (paused || positionId == 0) return false;
        if (block.timestamp < lastRebalance + minRebalanceInterval) return false;
        (, int24 tick,,,,,) = pool.slot0();
        (bool needed,,) = _targetRange(tick);
        if (!needed) return false;
        int24 avg = twapTick();
        int24 diff = tick > avg ? tick - avg : avg - tick;
        return diff <= maxTwapDeviation;
    }

    function liquidity() public view returns (uint128 liq) {
        if (positionId == 0) return 0;
        (,,,,,,, liq,,,,) = positionManager.positions(positionId);
    }

    // ================================================================== 内部処理

    function _setParams(
        int24 _rangeWidth,
        uint32 _twapWindow,
        int24 _maxTwapDeviation,
        uint32 _minInterval,
        bool _feesToOwner
    ) internal {
        if (
            _rangeWidth < tickSpacing * 2 || _rangeWidth > 50000 || _rangeWidth % tickSpacing != 0
                || _twapWindow < MIN_TWAP_WINDOW || _twapWindow > MAX_TWAP_WINDOW || _maxTwapDeviation <= 0
                || _maxTwapDeviation > 2000 || _minInterval > MAX_REBALANCE_INTERVAL
        ) revert BadParam();
        rangeWidth = _rangeWidth;
        twapWindow = _twapWindow;
        maxTwapDeviation = _maxTwapDeviation;
        minRebalanceInterval = _minInterval;
        feesToOwner = _feesToOwner;
        emit ParamsChanged(_rangeWidth, _twapWindow, _maxTwapDeviation, _minInterval, _feesToOwner);
    }

    function _checkPriceStable() internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
        int24 avg = twapTick();
        int24 diff = tick > avg ? tick - avg : avg - tick;
        if (diff > maxTwapDeviation) revert PriceUnstable(tick, avg);
    }

    /// 価格が範囲から外れていて、かつ新しい範囲が今と違う場合だけ needed = true
    function _targetRange(int24 tick) internal view returns (bool needed, int24 lower, int24 upper) {
        if (tick >= tickUpper) {
            // 価格が上に抜けた：中身は token1 のみ → 現在価格のすぐ下に置く
            upper = _floorTick(tick);
            lower = upper - rangeWidth;
        } else if (tick < tickLower) {
            // 価格が下に抜けた：中身は token0 のみ → 現在価格のすぐ上に置く
            lower = _floorTick(tick) + tickSpacing;
            upper = lower + rangeWidth;
        } else {
            return (false, tickLower, tickUpper);
        }
        needed = (lower != tickLower || upper != tickUpper);
    }

    function _floorTick(int24 tick) internal view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _checkTicks(int24 lower, int24 upper) internal pure {
        if (lower >= upper || lower < MIN_TICK || upper > MAX_TICK) revert BadParam();
    }

    function _balances() internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(token0).balanceOf(address(this));
        b1 = IERC20(token1).balanceOf(address(this));
    }

    function _approve(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(positionManager), amount);
    }

    function _wrapAndSwap(uint16 swapBps, uint256 minOut) internal {
        if (swapBps > 10000) revert BadParam();
        if (msg.value > 0) weth.deposit{value: msg.value}();
        if (swapBps > 0) {
            uint256 amountIn = (weth.balanceOf(address(this)) * swapBps) / 10000;
            if (amountIn > 0) _swap(address(weth), amountIn, minOut);
        }
    }

    function _swap(address tokenIn, uint256 amountIn, uint256 minOut) internal returns (uint256 out) {
        address tokenOut = tokenIn == token0 ? token1 : token0;
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        out = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(swapRouter), 0);
    }

    function _mint(int24 lower, int24 upper) internal returns (uint256 id, uint128 liq) {
        (uint256 b0, uint256 b1) = _balances();
        _approve(token0, b0);
        _approve(token1, b1);
        (id, liq,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: b0,
                amount1Desired: b1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        _approve(token0, 0);
        _approve(token1, 0);
        positionId = id;
        tickLower = lower;
        tickUpper = upper;
    }

    function _collectFees() internal {
        // 流動性を減らす前の collect は「手数料だけ」を受け取る
        (uint256 a0, uint256 a1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: feesToOwner ? owner : address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (a0 > 0 || a1 > 0) emit FeesCollected(a0, a1, feesToOwner);
    }

    function _closePosition() internal {
        uint256 id = positionId;
        if (id == 0) revert NoPosition();
        _collectFees();
        uint128 liq = liquidity();
        uint256 a0;
        uint256 a1;
        if (liq > 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: id,
                    liquidity: liq,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            (a0, a1) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: id,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }
        positionManager.burn(id);
        positionId = 0;
        emit PositionClosed(id, a0, a1);
    }

    function _sendAll(bool unwrap) internal {
        (uint256 b0, uint256 b1) = _balances();
        address w = address(weth);
        if (unwrap) {
            uint256 wb = w == token0 ? b0 : b1;
            if (wb > 0) weth.withdraw(wb);
            address other = w == token0 ? token1 : token0;
            uint256 ob = w == token0 ? b1 : b0;
            if (ob > 0) IERC20(other).safeTransfer(owner, ob);
        } else {
            if (b0 > 0) IERC20(token0).safeTransfer(owner, b0);
            if (b1 > 0) IERC20(token1).safeTransfer(owner, b1);
        }
        uint256 eb = address(this).balance;
        if (eb > 0) _sendEth(eb);
    }

    function _sendEth(uint256 amount) internal {
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
