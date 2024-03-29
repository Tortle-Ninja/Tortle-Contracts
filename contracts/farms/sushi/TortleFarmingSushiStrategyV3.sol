// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "../../interfaces/IMasterChef.sol";
import "../../interfaces/IRewarderSushiSwap.sol";
import "../../interfaces/ITortleVault.sol";

error TortleFarmingSushiStrategy__SenderIsNotVault();
error TortleFarmingSushiStrategy__InvalidAmount();
error TortleFarmingSushiStrategy__InsufficientLPAmount();

contract TortleFarmingSushiStrategyV3 is Ownable, Pausable {
    using SafeERC20 for IERC20;

    address public immutable weth;
    address public immutable complexRewardToken;
    address public immutable rewardToken;
    address public immutable lpToken;
    address public immutable lpToken0;
    address public immutable lpToken1;

    address public immutable uniRouter;
    address public immutable masterChef;
    address public immutable complexrewarder;
    uint8 public immutable poolId;
    uint256 public lastAutocompoundTime;

    address public immutable treasury;
    address public immutable vault;

    uint256 public slippageFactorMin = 950;
    uint256 private constant ACC_SUSHI_PRECISION = 1e12;

    address[] public complexRewardTokenToWethRoute;
    address[] public complexRewardTokenToLp0Route;
    address[] public complexRewardTokenToLp1Route;
    address[] public rewardTokenToWethRoute;
    address[] public rewardTokenToLp0Route;
    address[] public rewardTokenToLp1Route;

    struct Harvest {
        uint256 timestamp;
        uint256 vaultSharePrice;
    }
    Harvest[] public harvestLog;

    uint256 public harvestLogCadence;
    uint256 public lastHarvestTimestamp;

    event StratHarvest(address indexed harvester);
    event SlippageFactorMinUpdated(uint256 newSlippageFactorMin);

    constructor(
        address _lpToken,
        uint8 _poolId,
        address _vault,
        address _treasury,
        address _uniRouter,
        address _masterChef,
        address _complexrewarder,
        address _complexRewardToken,
        address _rewardToken,
        address _weth
    ) {
        uniRouter = _uniRouter;
        masterChef = _masterChef;
        complexrewarder = _complexrewarder;
        complexRewardToken = _complexRewardToken;
        rewardToken = _rewardToken;
        weth = _weth;

        lpToken = _lpToken;
        poolId = _poolId;
        lastAutocompoundTime = block.timestamp;
        vault = _vault;
        treasury = _treasury;

        lpToken0 = IUniswapV2Pair(lpToken).token0();
        lpToken1 = IUniswapV2Pair(lpToken).token1();

        if (lpToken0 == weth) {
            complexRewardTokenToLp0Route = [complexRewardToken, weth];
            rewardTokenToLp0Route = [rewardToken, weth];
        } else {
            if (lpToken0 != complexRewardToken) complexRewardTokenToLp0Route = [complexRewardToken, weth, lpToken0];
            if (lpToken0 != rewardToken) rewardTokenToLp0Route = [rewardToken, weth, lpToken0];
        }

        if (lpToken1 == weth) {
            complexRewardTokenToLp1Route = [complexRewardToken, weth];
            rewardTokenToLp1Route = [rewardToken, weth];
        } else {
            if (lpToken1 != complexRewardToken) complexRewardTokenToLp1Route = [complexRewardToken, weth, lpToken1];
            if (lpToken1 != rewardToken) rewardTokenToLp1Route = [rewardToken, weth, lpToken1];
        }

        complexRewardTokenToWethRoute = [complexRewardToken, weth];
        rewardTokenToWethRoute = [rewardToken, weth];

        harvestLog.push(
            Harvest({
                timestamp: block.timestamp,
                vaultSharePrice: ITortleVault(_vault).getPricePerFullShare()
            })
        );
    }

    function deposit() public whenNotPaused {
        if(IERC20(complexRewardToken).balanceOf(address(this)) >= 10**15) convertRewardToLP();
        
        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
        if(lpBalance <= 0) revert TortleFarmingSushiStrategy__InsufficientLPAmount();
        
        IERC20(lpToken).safeApprove(masterChef, 0);
        IERC20(lpToken).safeApprove(masterChef, lpBalance);
        IMasterChefV2(masterChef).deposit(poolId, lpBalance, address(this));
    }

    function withdraw(address user_, uint256[2] memory rewardsAmount_, uint256 _amount) external {
        if (msg.sender != vault) revert TortleFarmingSushiStrategy__SenderIsNotVault();
        uint256 lpTokenBalance = IERC20(lpToken).balanceOf(address(this));
        if (_amount == 0 || _amount > (balanceOfPool() + lpTokenBalance)) revert TortleFarmingSushiStrategy__InvalidAmount();

        if (lpTokenBalance < _amount) {
            IMasterChefV2(masterChef).withdrawAndHarvest(poolId, _amount - lpTokenBalance, address(this));
        }
        IERC20(lpToken).safeTransfer(vault, _amount);
        if (rewardsAmount_[0] > 0) IERC20(complexRewardToken).safeTransfer(user_, rewardsAmount_[0]);
        if (rewardsAmount_[1] > 0) IERC20(rewardToken).safeTransfer(user_, rewardsAmount_[1]);
    }

    function harvest() external whenNotPaused {
        IMasterChefV2(masterChef).deposit(poolId, 0, address(this));
        convertRewardToLP();
        deposit();
        if (block.timestamp >= harvestLog[harvestLog.length - 1].timestamp + harvestLogCadence) {
            harvestLog.push(Harvest({timestamp: block.timestamp, vaultSharePrice: ITortleVault(vault).getPricePerFullShare()}));
        }
        lastHarvestTimestamp = block.timestamp;
        emit StratHarvest(msg.sender);
    }

    function convertRewardToLP() internal {
        uint256 complexRewardTokenHalf_ = IERC20(complexRewardToken).balanceOf(address(this)) / 2;

        if (lpToken0 != complexRewardToken) swap(complexRewardTokenHalf_, complexRewardTokenToLp0Route);

        if (lpToken1 != complexRewardToken) swap(complexRewardTokenHalf_, complexRewardTokenToLp1Route);

        uint256 rewardsBalance = IERC20(rewardToken).balanceOf(address(this));
        if (rewardsBalance > 0) {
            uint256 rewardTokenHalf_ = IERC20(rewardToken).balanceOf(address(this)) / 2;

            if (lpToken0 != rewardToken) swap(rewardTokenHalf_, rewardTokenToLp0Route);

            if (lpToken1 != rewardToken) swap(rewardTokenHalf_, rewardTokenToLp1Route);
        }

        uint256 lp0Bal_ = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal_ = IERC20(lpToken1).balanceOf(address(this));
        if (lp0Bal_ != 0 && lp1Bal_ != 0) {
            IERC20(lpToken0).safeApprove(uniRouter, 0);
            IERC20(lpToken0).safeApprove(uniRouter, lp0Bal_);
            IERC20(lpToken1).safeApprove(uniRouter, 0);
            IERC20(lpToken1).safeApprove(uniRouter, lp1Bal_);
            IUniswapV2Router02(uniRouter).addLiquidity(lpToken0, lpToken1, lp0Bal_, lp1Bal_, 1, 1, address(this), block.timestamp);
        }

        lastAutocompoundTime = block.timestamp;
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfLpToken() + balanceOfPool();
    }

    function balanceOfLpToken() public view returns (uint256) {
        return IERC20(lpToken).balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterChef).userInfo(poolId, address(this));
        return _amount;
    }

    function retireStrat() external {
        if (msg.sender != vault) revert TortleFarmingSushiStrategy__SenderIsNotVault();

        IMasterChef(masterChef).emergencyWithdraw(poolId);

        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
        IERC20(lpToken).transfer(vault, lpBalance);
    }

    function panic() public onlyOwner {
        pause();
        IMasterChef(masterChef).withdraw(poolId, balanceOfPool());
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
        deposit();
    }

    function swap(
        uint256 _amount,
        address[] memory _path
    ) internal {
        if (_path.length < 2 || _amount == 0) {
            return;
        }
        IERC20(_path[0]).safeApprove(uniRouter, 0);
        IERC20(_path[0]).safeApprove(uniRouter, _amount);
        uint256[] memory amounts = IUniswapV2Router02(uniRouter).getAmountsOut(_amount, _path);
        uint256 amountOut = amounts[amounts.length - 1];

        IUniswapV2Router02(uniRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            (amountOut * slippageFactorMin) / 1000,
            _path,
            address(this),
            block.timestamp
        );
    }

    function updateHarvestLogCadence(uint256 _newCadenceInSeconds)
        external
        onlyOwner
    {
        harvestLogCadence = _newCadenceInSeconds;
    }

    function harvestLogLength() external view returns (uint256) {
        return harvestLog.length;
    }

    function estimateHarvest()
        external
        view
        returns (uint256 profit)
    {
        uint256 pendingReward = IRewarderSushiSwap(complexrewarder).pendingToken(
            poolId,
            address(this)
        );
        uint256 totalRewards = pendingReward +
            IERC20(complexRewardToken).balanceOf(address(this));

        if (totalRewards != 0) {
            profit += IUniswapV2Router02(uniRouter).getAmountsOut(
                totalRewards,
                complexRewardTokenToWethRoute
            )[1];
        }

        profit += IERC20(weth).balanceOf(address(this));
    }

    function toUInt256(int256 a) internal pure returns (uint256) {
        require(a >= 0, "Integer < 0");
        return uint256(a);
    }

    function _pendingSushi() private view returns (uint256 pending) {
        IMiniChef.PoolInfo memory pool = IMiniChef(masterChef).poolInfo(poolId);
        IMasterChef.UserInfo memory user = IMiniChef(masterChef).userInfo(poolId, address(this));
        uint256 accSushiPerShare = pool.accSushiPerShare;
        uint256 lpSupply = IERC20(lpToken).balanceOf(masterChef);

        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 time = block.timestamp - pool.lastRewardTime;
            uint256 sushiReward = time * (IMiniChef(masterChef).sushiPerSecond() * pool.allocPoint) / IMasterChef(masterChef).totalAllocPoint();
            accSushiPerShare = (accSushiPerShare + (sushiReward * ACC_SUSHI_PRECISION)) / lpSupply;
        }

        int256 pendingResult_ = int256((user.amount * accSushiPerShare) / ACC_SUSHI_PRECISION) - int256(user.rewardDebt);
        if (pending > 0) pending = toUInt256(pendingResult_);
        else pending = 0;
    }

    function getRewardsPerFarmNode(uint256 shares_) public view returns(uint256[2] memory rewardsAmount) {
        uint256 totalcomplexRewardAmount_ = IRewarderSushiSwap(complexrewarder).pendingToken(poolId, address(this)) + IERC20(complexRewardToken).balanceOf(address(this));
        rewardsAmount[0] = (totalcomplexRewardAmount_ * shares_) / IERC20(vault).totalSupply();

        uint256 totalRewardAmount_ = _pendingSushi() + IERC20(rewardToken).balanceOf(address(this));
        rewardsAmount[1] = (totalRewardAmount_ * shares_) / IERC20(vault).totalSupply();
    }

    function setSlippageFactorMin(uint256 _slippageFactorMin) public onlyOwner {
        slippageFactorMin = _slippageFactorMin;
        emit SlippageFactorMinUpdated(slippageFactorMin);
    }
}
