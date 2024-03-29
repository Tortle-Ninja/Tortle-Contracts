// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "../../interfaces/IMasterChef.sol";
import "../../interfaces/ITortleVault.sol";

error TortleFarmingStrategy__SenderIsNotVault();
error TortleFarmingStrategy__InvalidAmount();
error TortleFarmingStrategy__InsufficientLPAmount();

contract TortleFarmingSushiStrategy is Ownable, Pausable {
    using SafeERC20 for IERC20;

    address public immutable weth;
    address public immutable rewardToken;
    address public immutable lpToken;
    address public immutable lpToken0;
    address public immutable lpToken1;

    address public immutable uniRouter;
    address public immutable masterChef;
    uint8 public immutable poolId;
    uint256 public lastAutocompoundTime;

    address public immutable treasury;
    address public immutable vault;

    uint256 public slippageFactorMin = 950;

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
        address _rewardToken,
        address _weth
    ) {
        uniRouter = _uniRouter;
        masterChef = _masterChef;
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
            rewardTokenToLp0Route = [rewardToken, weth];
        } else if (lpToken0 != rewardToken) {
            rewardTokenToLp0Route = [rewardToken, weth, lpToken0];
        }

        if (lpToken1 == weth) {
            rewardTokenToLp1Route = [rewardToken, weth];
        } else if (lpToken1 != rewardToken) {
            rewardTokenToLp1Route = [rewardToken, weth, lpToken1];
        }

        rewardTokenToWethRoute = [rewardToken, weth];

        harvestLog.push(
            Harvest({
                timestamp: block.timestamp,
                vaultSharePrice: ITortleVault(_vault).getPricePerFullShare()
            })
        );
    }

    function deposit() public whenNotPaused {
        if(IERC20(rewardToken).balanceOf(address(this)) >= 10**15) convertRewardToLP();
        
        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
        if(lpBalance <= 0) revert TortleFarmingStrategy__InsufficientLPAmount();
        
        IERC20(lpToken).safeApprove(masterChef, 0);
        IERC20(lpToken).safeApprove(masterChef, lpBalance);
        IMasterChefV2(masterChef).deposit(poolId, lpBalance, address(this));
    }

    function withdraw(address user_, uint256[2] memory rewardsAmount_, uint256 _amount) external {
        if (msg.sender != vault) revert TortleFarmingStrategy__SenderIsNotVault();
        uint256 lpTokenBalance = IERC20(lpToken).balanceOf(address(this));
        if (_amount == 0 || _amount > (balanceOfPool() + lpTokenBalance)) revert TortleFarmingStrategy__InvalidAmount();

        if (lpTokenBalance < _amount) {
            IMasterChefV2(masterChef).withdraw(poolId, _amount - lpTokenBalance, address(this));
            IMasterChefV2(masterChef).harvest(poolId, address(this));
        }
        IERC20(lpToken).safeTransfer(vault, _amount);
        IERC20(rewardToken).safeTransfer(user_, rewardsAmount_[0]);
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
        uint256 rewardTokenHalf_ = IERC20(rewardToken).balanceOf(address(this)) / 2;

        if (lpToken0 != rewardToken) {
            swap(rewardTokenHalf_, rewardTokenToLp0Route);
        }

        if (lpToken1 != rewardToken) {
            swap(rewardTokenHalf_, rewardTokenToLp1Route);
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
        if (msg.sender != vault) revert TortleFarmingStrategy__SenderIsNotVault();

        IMasterChefV2(masterChef).emergencyWithdraw(poolId, address(this));

        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
        IERC20(lpToken).transfer(vault, lpBalance);
    }

    function panic() public onlyOwner {
        pause();
        IMasterChefV2(masterChef).withdraw(poolId, balanceOfPool(), address(this));
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
        uint256 pendingReward = IMiniChef(masterChef).pendingSushi(
            poolId,
            address(this)
        );
        uint256 totalRewards = pendingReward +
            IERC20(rewardToken).balanceOf(address(this));

        if (totalRewards != 0) {
            profit += IUniswapV2Router02(uniRouter).getAmountsOut(
                totalRewards,
                rewardTokenToWethRoute
            )[1];
        }

        profit += IERC20(weth).balanceOf(address(this));
    }

    function getRewardsPerFarmNode(uint256 shares_) public view returns(uint256[2] memory rewardsAmount) {
        uint256 totalRewardAmount_ = IMiniChef(masterChef).pendingSushi(poolId, address(this)) + IERC20(rewardToken).balanceOf(address(this));
        rewardsAmount[0] = (totalRewardAmount_ * shares_) / IERC20(vault).totalSupply();
    }

    function setSlippageFactorMin(uint256 _slippageFactorMin) public onlyOwner {
        slippageFactorMin = _slippageFactorMin;
        emit SlippageFactorMinUpdated(slippageFactorMin);
    }
}
