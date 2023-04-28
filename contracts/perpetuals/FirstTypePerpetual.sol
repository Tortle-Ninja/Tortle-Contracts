// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/ReentrancyGuard.sol";
import "../interfaces/IFirstTypePerpetual.sol";
import "../interfaces/IGmx.sol";
import '../interfaces/IWETH.sol';
import "hardhat/console.sol";

contract FirstTypePerpetual is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public owner;
    address immutable mummyFinanceContract;
    address public selectPerpRoute;

    mapping(address => uint256) public wftBalance;

    modifier onlyAllowed() {
        require(msg.sender == owner || msg.sender == selectPerpRoute, 'You must be the owner.');
        _;
    }

    constructor(address owner_, address mummyFinanceContract_) {
        owner = owner_;
        mummyFinanceContract = mummyFinanceContract_;
    }

    function setSelectPerpRoute(address selectPerpRoute_) public onlyAllowed {
        selectPerpRoute = selectPerpRoute_;
    }

    function _approve(address token_, address spender_, uint256 amount_) internal {
        IERC20(token_).safeApprove(spender_, 0);
        IERC20(token_).safeApprove(spender_, amount_);
    }

    function openPerpPosition(bytes memory args_, uint256 amount_) external onlyAllowed payable returns (bytes32 data, uint256 sizeDelta, uint256 acceptablePrice) {
        (address[] memory path_,
        address indexToken_,
        bool isLong_,,
        uint256 indexTokenPrice_,,,) = abi.decode(args_, (address[], address, bool, uint256, uint256, uint256, uint256, uint8));

        _approve(indexToken_, address(mummyFinanceContract), amount_);

        acceptablePrice = indexTokenPrice_;
        sizeDelta = acceptablePrice * amount_ / 1e18;

        uint256 executionFee = IFirstTypePerpetual(mummyFinanceContract).minExecutionFee();
        uint256 depositAmount = amount_ - executionFee;
        IWETH(indexToken_).withdraw(depositAmount);

        data = IGmx(mummyFinanceContract).createIncreasePositionETH{value: depositAmount}(path_, indexToken_, 0, sizeDelta, isLong_, acceptablePrice, executionFee, bytes32(0), address(0));
    }

    function closePerpPosition(
        address[] memory path_,
        address indexToken_,
        uint256 collateralDelta_,
        uint256 sizeDelta_,
        bool isLong_,
        uint256 acceptablePrice_,
        uint256 amountOutMin_,
        address nodesContract_
    ) public onlyAllowed payable returns (bytes32 data, uint256 amount) {

        uint256 balanceBefore = address(this).balance;
        uint256 fee = IFirstTypePerpetual(mummyFinanceContract).minExecutionFee();
        IWETH(indexToken_).withdraw(fee);

        (data) = IGmx(mummyFinanceContract).createDecreasePosition{value: fee}(path_, indexToken_, collateralDelta_, sizeDelta_, isLong_, address(this), acceptablePrice_, amountOutMin_, fee, true, address(0));

        uint256 balanceAfter = address(this).balance;
        amount = balanceAfter - balanceBefore;

        IWETH(indexToken_).deposit{value: amount}();
        IERC20(indexToken_).safeTransfer(nodesContract_, amount);
    }

    receive() external payable {}
}