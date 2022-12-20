// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IYearn.sol";
import "../interfaces/ICurvePools.sol";

contract Yearn {
    using SafeERC20 for IERC20;
    //TODO: Guardar balances de shares en un mapping para cada user??

    function _addLiquidity(address token_, uint256[3] memory amounts_, bool oldContract_) private returns (uint256 lpAmount) {
        if(oldContract_) {
            uint256 balanceBefore_ = IERC20(token_).balanceOf(address(this));
            ICurvePools(token_).add_liquidity(amounts_, 1);
            lpAmount = IERC20(token_).balanceOf(address(this)) - balanceBefore_;
        } else {
            lpAmount = ICurvePools(token_).add_liquidity(amounts_, 1, true);
        }
    }

    function deposit(address token_, address vaultAddress_, uint256 amount_) external returns (uint256 result) {
        IERC20(token_).safeTransferFrom(msg.sender, address(this), amount_);
        IERC20(token_).safeApprove(vaultAddress_, amount_);

        result = IYearnVyper(vaultAddress_).deposit(amount_, msg.sender);
    }

    function withdraw(address vaultAddress_, uint256 sharesAmount_) external returns (uint256 result) {
        IERC20(vaultAddress_).safeTransferFrom(msg.sender, address(this), sharesAmount_);
        IERC20(vaultAddress_).safeApprove(vaultAddress_, sharesAmount_);

        result = IYearnVyper(vaultAddress_).withdraw(sharesAmount_, msg.sender);
    }
}