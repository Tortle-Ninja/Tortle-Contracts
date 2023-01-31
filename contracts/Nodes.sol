// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

import '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/Babylonian.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import './lib/AddressToUintIterableMap.sol';
import './interfaces/ITortleVault.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './interfaces/IWETH.sol';
import './SwapsUni.sol';
import './SwapsBeets.sol';
import './DepositsBeets.sol';
import './nestedStrategies/NestedStrategies.sol';
import './farms/FarmsUni.sol';
import './Batch.sol';

error Nodes__InsufficientBalance();
error Nodes__EmptyArray();
error Nodes__InvalidArrayLength();
error Nodes__TransferFailed();
error Nodes__DepositOnLPInvalidLPToken();
error Nodes__DepositOnLPInsufficientT0Funds();
error Nodes__DepositOnLPInsufficientT1Funds();
error Nodes__DepositOnNestedStrategyInsufficientFunds();
error Nodes__WithdrawFromNestedStrategyInsufficientShares();
error Nodes__DepositOnFarmTokensInsufficientT0Funds();
error Nodes__DepositOnFarmTokensInsufficientT1Funds();
error Nodes__WithdrawFromLPInsufficientFunds();
error Nodes__WithdrawFromFarmInsufficientFunds();

contract Nodes is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AddressToUintIterableMap for AddressToUintIterableMap.Map;

    address public owner;
    address public tortleDojos;
    address public tortleTreasury;
    address public tortleDevFund;
    SwapsUni public swapsUni;
    SwapsBeets public swapsBeets;
    DepositsBeets public depositsBeets;
    NestedStrategies public nestedStrategies;
    FarmsUni public farmsUni;
    Batch private batch;
    address private WFTM;
    address public usdc;

    uint8 public constant INITIAL_TOTAL_FEE = 50; // 0.50%
    uint16 public constant PERFORMANCE_TOTAL_FEE = 500; // 5%
    uint16 public constant DOJOS_FEE = 3333; // 33.33%
    uint16 public constant TREASURY_FEE = 4666; // 46.66%
    uint16 public constant DEV_FUND_FEE = 2000; // 20%

    mapping(address => mapping(address => uint256)) public userLp;
    mapping(address => mapping(address => uint256)) public userTt;

    mapping(address => AddressToUintIterableMap.Map) private balance;

    event AddFunds(address tokenInput, uint256 amount);
    event Swap(address tokenInput, uint256 amountIn, address tokenOutput, uint256 amountOut);
    event Split(address tokenOutput1, uint256 amountOutToken1, address tokenOutput2, uint256 amountOutToken2);
    event Liquidate(address tokenOutput, uint256 amountOut);
    event SendToWallet(address tokenOutput, uint256 amountOut);
    event RecoverAll(address tokenOut, uint256 amountOut);

    modifier onlyOwner() {
        require(msg.sender == owner || msg.sender == address(batch) || msg.sender == address(this), 'You must be the owner.');
        _;
    }

    function initializeConstructor(
        address owner_,
        SwapsUni swapsUni_,
        SwapsBeets swapsBeets_,
        DepositsBeets depositsBeets_,
        NestedStrategies nestedStrategies_,
        FarmsUni farmsUni_,
        Batch batch_,
        address tortleDojos_,
        address tortleTrasury_,
        address tortleDevFund_,
        address wftm_,
        address usdc_
    ) public initializer {
        owner = owner_;
        swapsUni = swapsUni_;
        swapsBeets = swapsBeets_;
        depositsBeets = depositsBeets_;
        nestedStrategies = nestedStrategies_;
        farmsUni = farmsUni_;
        batch = batch_;
        tortleDojos = tortleDojos_;
        tortleTreasury = tortleTrasury_;
        tortleDevFund = tortleDevFund_;
        WFTM = wftm_;
        usdc = usdc_;
    }

    function setBatch(Batch batch_) public onlyOwner {
        batch = batch_;
    }

    function setSwapsUni(SwapsUni swapsUni_) public onlyOwner {
        swapsUni = swapsUni_;
    }

    function setSwapsBeets(SwapsBeets swapsBeets_) public onlyOwner {
        swapsBeets = swapsBeets_;
    }

    function setDepositsBeets(DepositsBeets depositsBeets_) public onlyOwner {
        depositsBeets = depositsBeets_;
    }

    function setNestedStrategies(NestedStrategies nestedStrategies_) public onlyOwner {
        nestedStrategies = nestedStrategies_;
    }

    function setFarmsUni(FarmsUni farmsUni_) public onlyOwner {
        farmsUni = farmsUni_;
    }

    function setTortleDojos(address tortleDojos_) public onlyOwner {
        tortleDojos = tortleDojos_;
    }

    function setTortleTreasury(address tortleTreasury_) public onlyOwner {
        tortleTreasury = tortleTreasury_;
    }

    function setTortleDevFund(address tortleDevFund_) public onlyOwner {
        tortleDevFund = tortleDevFund_;
    }

    /**
    * @notice Function used to charge the correspoding fees (returns the amount - fees).
    * @param token_ Address of the token used as fees.
    * @param amount_ Amount of the token that is wanted to calculate its fees.
    * @param feeAmount_ Percentage of fees to be charged.
    */
    function _chargeFees(address token_, uint256 amount_, uint256 feeAmount_) private returns (uint256) {
        uint256 amountFee_ = mulScale(amount_, feeAmount_, 10000);
        uint256 dojosTokens_;
        uint256 treasuryTokens_;
        uint256 devFundTokens_;

        if (token_ == usdc) {
            dojosTokens_ = mulScale(amountFee_, DOJOS_FEE, 10000);
            treasuryTokens_ = mulScale(amountFee_, TREASURY_FEE, 10000);
            devFundTokens_ = mulScale(amountFee_, DEV_FUND_FEE, 10000);
        } else {
            _approve(token_, address(swapsUni), amountFee_);
            uint256 _amountSwap = swapsUni.swapTokens(token_, amountFee_, usdc, 0);
            dojosTokens_ = _amountSwap / 3;
            treasuryTokens_ = mulScale(_amountSwap, 2000, 10000);
            devFundTokens_= _amountSwap - (dojosTokens_ + treasuryTokens_);
        }

        IERC20(usdc).safeTransfer(tortleDojos, dojosTokens_);
        IERC20(usdc).safeTransfer(tortleTreasury, treasuryTokens_);
        IERC20(usdc).safeTransfer(tortleDevFund, devFundTokens_);

        return amount_ - amountFee_;
    }

    /**
     * @notice Function that allows to add funds to the contract to execute the recipes.
     * @param _token Contract of the token to be deposited.
     * @param _user Address of the user who will deposit the tokens.
     * @param _amount Amount of tokens to be deposited.
     */
    function addFundsForTokens(
        address _user,
        address _token,
        uint256 _amount
    ) public nonReentrant returns (uint256 amount) {
        if (_amount <= 0) revert Nodes__InsufficientBalance();

        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(_user, address(this), _amount);
        uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
        if (balanceAfter <= balanceBefore) revert Nodes__TransferFailed();

        amount = _chargeFees(_token, balanceAfter - balanceBefore, INITIAL_TOTAL_FEE);
        increaseBalance(_user, _token, amount);

        emit AddFunds(_token, amount);
    }

    /**
    * @notice Function that allows to add funds to the contract to execute the recipes.
    * @param _user Address of the user who will deposit the tokens.
    */
    function addFundsForFTM(address _user) public payable nonReentrant returns (address token, uint256 amount) {
        if (msg.value <= 0) revert Nodes__InsufficientBalance();

        IWETH(WFTM).deposit{value: msg.value}();

        uint256 _amount = _chargeFees(WFTM, msg.value, INITIAL_TOTAL_FEE);
        increaseBalance(_user, WFTM, _amount);

        emit AddFunds(WFTM, _amount);
        return (WFTM, _amount);
    }

    /**
     * @notice Function that allows to send X amount of tokens and returns the token you want.
     * @param user_ Address of the user running the node.
     * @param provider_ Provider used for swapping tokens.
     * @param tokens_ Array of tokens to be swapped.
     * @param amount_ Amount of Tokens to be swapped.
     * @param amountOutMin_ Minimum amounts you want to use.
     * @param batchSwapStep_ Array of structs required by beets provider.
     */
    function swapTokens(
        address user_,
        uint8 provider_,
        IAsset[] memory tokens_,
        uint256 amount_,
        uint256 amountOutMin_,
        BatchSwapStep[] memory batchSwapStep_
    ) public nonReentrant onlyOwner returns (uint256 amountOut) {
        address tokenIn_ = address(tokens_[0]);
        address tokenOut_ = address(tokens_[tokens_.length - 1]);

        uint256 _userBalance = getBalance(user_, IERC20(tokenIn_));
        if (amount_ > _userBalance) revert Nodes__InsufficientBalance();

        if (tokenIn_ != tokenOut_) {
            if (provider_ == 0) {
                _approve(tokenIn_, address(swapsUni), amount_);
                amountOut = swapsUni.swapTokens(tokenIn_, amount_, tokenOut_, amountOutMin_);
            } else {
                _approve(tokenIn_, address(swapsBeets), amount_);
                batchSwapStep_[0].amount = amount_;
                amountOut = swapsBeets.swapTokens(tokens_, batchSwapStep_);
            }

            decreaseBalance(user_, tokenIn_, amount_);
            increaseBalance(user_, tokenOut_, amountOut);
        } else amountOut = amount_;

        emit Swap(tokenIn_, amount_, tokenOut_, amountOut);
    }

    /**
    * @notice Function that divides the token you send into two tokens according to the percentage you select.
    * @param args_ user, firstTokens, secondTokens, amount, percentageFirstToken, amountOutMinFirst_, amountOutMinSecond_, providers, batchSwapStepFirstToken, batchSwapStepSecondToken.
    */
    function split(
        bytes calldata args_,
        BatchSwapStep[] memory batchSwapStepFirstToken_,
        BatchSwapStep[] memory batchSwapStepSecondToken_
    ) public onlyOwner returns (uint256[] memory amountOutTokens) {
        (address user_, 
        IAsset[] memory firstTokens_, 
        IAsset[] memory secondTokens_, 
        uint256 amount_,
        uint256[] memory percentageAndAmountsOutMin_,
        uint8[] memory providers_
        ) = abi.decode(args_, (address, IAsset[], IAsset[], uint256, uint256[], uint8[]));

        if (amount_ > getBalance(user_, IERC20(address(firstTokens_[0])))) revert Nodes__InsufficientBalance();

        uint256 firstTokenAmount_ = mulScale(amount_, percentageAndAmountsOutMin_[0], 10000);
        
        amountOutTokens = new uint256[](2);
        amountOutTokens[0] = swapTokens(user_, providers_[0], firstTokens_, firstTokenAmount_, percentageAndAmountsOutMin_[1], batchSwapStepFirstToken_);
        amountOutTokens[1] = swapTokens(user_, providers_[1], secondTokens_, (amount_ - firstTokenAmount_), percentageAndAmountsOutMin_[2], batchSwapStepSecondToken_);

        emit Split(address(firstTokens_[firstTokens_.length - 1]), amountOutTokens[0], address(secondTokens_[secondTokens_.length - 1]), amountOutTokens[1]);
    }

    /**
    * @notice Function used to deposit tokens on a lpPool and get lptoken
    * @param user_ Address of the user.
    * @param poolId_ Beets pool id.
    * @param lpToken_ Address of the lpToken.
    * @param tokens_ Addresses of tokens that are going to be deposited.
    * @param amounts_ Amounts of tokens.
    * @param amountOutMin0_ Minimum amount of token0.
    * @param amountOutMin0_ Minimum amount of token1.
    */
    function depositOnLp(
        address user_,
        bytes32 poolId_,
        address lpToken_,
        uint8 provider_,
        address[] memory tokens_,
        uint256[] memory amounts_,
        uint256 amountOutMin0_,
        uint256 amountOutMin1_
    ) external nonReentrant onlyOwner returns (uint256) {
       if(provider_ == 0) {
            IUniswapV2Router02 router = swapsUni.getRouter(tokens_[0], tokens_[1]);

            if (lpToken_ != IUniswapV2Factory(IUniswapV2Router02(router).factory()).getPair(tokens_[0], tokens_[1])) revert  Nodes__DepositOnLPInvalidLPToken();
            if (amounts_[0] > getBalance(user_, IERC20(tokens_[0]))) revert Nodes__DepositOnLPInsufficientT0Funds();
            if (amounts_[1] > getBalance(user_, IERC20(tokens_[1]))) revert Nodes__DepositOnLPInsufficientT1Funds();

            _approve(tokens_[0], address(farmsUni), amounts_[0]);
            _approve(tokens_[1], address(farmsUni), amounts_[1]);
            (uint256 amount0f, uint256 amount1f, uint256 lpRes) = farmsUni.addLiquidity(router, tokens_[0], tokens_[1], amounts_[0], amounts_[1], amountOutMin0_, amountOutMin1_);
            userLp[lpToken_][user_] += lpRes;

            decreaseBalance(user_, tokens_[0], amount0f);
            decreaseBalance(user_, tokens_[1], amount1f);

            return lpRes;
        } else {
            if (amounts_[0] > getBalance(user_, IERC20(tokens_[0]))) revert Nodes__DepositOnLPInsufficientT0Funds();
            
            _approve(tokens_[0], address(depositsBeets), amounts_[0]);
            (address bptAddress_, uint256 bptAmount_) = depositsBeets.joinPool(poolId_, tokens_, amounts_);

            decreaseBalance(user_, tokens_[0], amounts_[0]);
            increaseBalance(user_, bptAddress_, bptAmount_);

            return bptAmount_;
        }
    }

    /**
    * @notice Function used to withdraw tokens from a LPfarm
    * @param user_ Address of the user.
    * @param poolId_ Beets pool id.
    * @param lpToken_ Address of the lpToken.
    * @param tokens_ Addresses of tokens that are going to be deposited.
    * @param amountsOutMin_ Minimum amounts to be withdrawed.
    * @param amount_ Amount of LPTokens desired to withdraw.
    */
    function withdrawFromLp(
        address user_,
        bytes32 poolId_,
        address lpToken_,
        uint8 provider_,
        address[] memory tokens_,
        uint256[] memory amountsOutMin_,
        uint256 amount_
    ) external nonReentrant onlyOwner returns (uint256 amountTokenDesired) {
        if(provider_ == 0) {
            if (amount_ > userLp[lpToken_][user_]) revert Nodes__WithdrawFromLPInsufficientFunds();

            _approve(lpToken_, address(farmsUni), amount_);
            amountTokenDesired = farmsUni.withdrawLpAndSwap(address(swapsUni), lpToken_, tokens_, amountsOutMin_[0], amount_);

            userLp[lpToken_][user_] -= amount_;
            increaseBalance(user_, tokens_[2], amountTokenDesired);
        } else {
            address bptToken_ = depositsBeets.getBptAddress(poolId_);
            if (amount_ > getBalance(user_, IERC20(bptToken_))) revert Nodes__WithdrawFromLPInsufficientFunds();
            
            _approve(bptToken_, address(depositsBeets), amount_);
            amountTokenDesired = depositsBeets.exitPool(poolId_, bptToken_, tokens_, amountsOutMin_, amount_);

            decreaseBalance(user_, bptToken_, amount_);
            increaseBalance(user_, tokens_[0], amountTokenDesired);
        }
    }

    function depositOnNestedStrategy(
        address user_,
        address token_, 
        address vaultAddress_, 
        uint256 amount_
    ) external nonReentrant onlyOwner returns (uint256 sharesAmount) {
        if (amount_ > getBalance(user_, IERC20(token_))) revert Nodes__DepositOnNestedStrategyInsufficientFunds();

        _approve(token_, address(nestedStrategies), amount_);
        sharesAmount = nestedStrategies.deposit(user_, token_, vaultAddress_, amount_);

        decreaseBalance(user_, token_, amount_);
        increaseBalance(user_, vaultAddress_, sharesAmount);
    }

    function withdrawFromNestedStrategy(
        address user_,
        address tokenOut_, 
        address vaultAddress_, 
        uint256 sharesAmount_
    ) external nonReentrant onlyOwner returns (uint256 amountTokenDesired) {
        if (sharesAmount_ > getBalance(user_, IERC20(vaultAddress_))) revert Nodes__WithdrawFromNestedStrategyInsufficientShares();
    
        _approve(vaultAddress_, address(nestedStrategies), sharesAmount_);
        amountTokenDesired = nestedStrategies.withdraw(user_, tokenOut_, vaultAddress_, sharesAmount_);

        decreaseBalance(user_, vaultAddress_, sharesAmount_);
        increaseBalance(user_, tokenOut_, amountTokenDesired);
    }

    /**
    * @notice Function used to deposit tokens on a farm
    * @param user Address of the user.
    * @param lpToken_ Address of the LP Token.
    * @param tortleVault_ Address of the tortle vault where we are going to deposit.
    * @param tokens_ Addresses of tokens that are going to be deposited.
    * @param amount0_ Amount of token 0.
    * @param amount1_ Amount of token 1.
    * @param auxStack Contains information of the amounts that are going to be deposited.
    */
    function depositOnFarmTokens(
        address user,
        address lpToken_,
        address tortleVault_,
        address[] memory tokens_,
        uint256 amount0_,
        uint256 amount1_,
        uint256[] memory auxStack
    ) external nonReentrant onlyOwner returns (uint256[] memory result) {
        result = new uint256[](3);
        if (auxStack.length > 0) {
            amount0_ = auxStack[auxStack.length - 2];
            amount1_ = auxStack[auxStack.length - 1];
            result[0] = 2;
        }

        if (amount0_ > getBalance(user, IERC20(tokens_[0]))) revert Nodes__DepositOnFarmTokensInsufficientT0Funds();
        if (amount1_ > getBalance(user, IERC20(tokens_[1]))) revert Nodes__DepositOnFarmTokensInsufficientT1Funds();

        IUniswapV2Router02 router = ISwapsUni(address(swapsUni)).getRouter(tokens_[0], tokens_[1]);
        _approve(tokens_[0], address(farmsUni), amount0_);
        _approve(tokens_[1], address(farmsUni), amount1_);
        (uint256 amount0f_, uint256 amount1f_, uint256 lpBal_) = farmsUni.addLiquidity(router, tokens_[0], tokens_[1], amount0_, amount1_, 0, 0);
        
        _approve(lpToken_, tortleVault_, lpBal_);
        uint256 ttAmount = ITortleVault(tortleVault_).deposit(user, lpBal_);
        userTt[tortleVault_][user] += ttAmount;
        
        decreaseBalance(user, tokens_[0], amount0f_);
        decreaseBalance(user, tokens_[1], amount1f_);
        
        result[1] = ttAmount;
        result[2] = lpBal_;
    }

    /**
    * @notice Function used to withdraw tokens from a farm
    * @param user Address of the user.
    * @param lpToken_ Address of the LP Token.
    * @param tortleVault_ Address of the tortle vault where we are going to deposit.
    * @param tokens_ Addresses of tokens that are going to be deposited.
    * @param amountOutMin_ Minimum amount to be withdrawed.
    * @param amount Amount of tokens desired to withdraw.
    */
    function withdrawFromFarm(
        address user,
        address lpToken_,
        address tortleVault_,
        address[] memory tokens_,
        uint256 amountOutMin_,
        uint256 amount
    ) external nonReentrant onlyOwner returns (uint256 amountLp, uint256 rewardAmount, uint256 amountTokenDesired) {
        if (amount > userTt[tortleVault_][user]) revert Nodes__WithdrawFromFarmInsufficientFunds();

        (uint256 rewardAmount_, uint256 amountLp_) = ITortleVault(tortleVault_).withdraw(user, amount);
        rewardAmount = rewardAmount_;
        amountLp = amountLp_;
        userTt[tortleVault_][user] -= amount;
        
        _approve(lpToken_, address(farmsUni), amountLp_);
        amountTokenDesired = farmsUni.withdrawLpAndSwap(address(swapsUni), lpToken_, tokens_, amountOutMin_, amountLp_);
        
        increaseBalance(user, tokens_[2], amountTokenDesired);
    }

    /**
    * @notice Function that allows to liquidate all tokens in your account by swapping them to a specific token.
    * @param user_ Address of the user whose tokens are to be liquidated.
    * @param tokens_ Array of tokens input.
    * @param amount_ Array of amounts.
    * @param amountOutMin_ Minimum amount you wish to receive.
    * @param liquidateAmountWPercentage_ AddFunds amount with percentage.
     */
    function liquidate(
        address user_,
        IAsset[] memory tokens_,
        uint256 amount_,
        uint256 amountOutMin_,
        uint256 liquidateAmountWPercentage_,
        uint8 provider_,
        BatchSwapStep[] memory batchSwapStep_
    ) public onlyOwner returns (uint256 amountOut) {
        address tokenIn_ = address(tokens_[0]);
        address tokenOut_ = address(tokens_[tokens_.length - 1]);

        uint256 userBalance_ = getBalance(user_, IERC20(tokenIn_));
        if (userBalance_ < amount_) revert Nodes__InsufficientBalance();

        int256 profitAmount = int256(amount_) - int256(liquidateAmountWPercentage_);

        if (profitAmount > 0) amount_ = _chargeFees(tokenIn_, uint256(profitAmount), PERFORMANCE_TOTAL_FEE);

        amountOut = swapTokens(user_, provider_, tokens_, amount_, amountOutMin_, batchSwapStep_);

        decreaseBalance(user_, tokenOut_, amountOut);

        if(tokenOut_ == WFTM) {
            IWETH(WFTM).withdraw(amountOut);
            payable(user_).transfer(amountOut);
        } else {
            IERC20(tokenOut_).safeTransfer(user_, amountOut); 
        }

        emit Liquidate(tokenOut_, amountOut);
    }

    /**
    * @notice Function that allows to withdraw tokens to the user's wallet.
    * @param user_ Address of the user who wishes to remove the tokens.
    * @param token_ Token to be withdrawn.
    * @param amount_ Amount of tokens to be withdrawn.
    * @param addFundsAmountWPercentage_ AddFunds amount with percentage.
    */
    function sendToWallet(
        address user_,
        address token_,
        uint256 amount_,
        uint256 addFundsAmountWPercentage_
    ) public nonReentrant onlyOwner returns (uint256) {
        uint256 _userBalance = getBalance(user_, IERC20(token_));
        if (_userBalance < amount_) revert Nodes__InsufficientBalance();

        int256 profitAmount = int256(amount_) - int256(addFundsAmountWPercentage_);

        if (profitAmount > 0) amount_ = _chargeFees(token_, uint256(profitAmount), PERFORMANCE_TOTAL_FEE);

        if (token_ == WFTM) {
            IWETH(WFTM).withdraw(amount_);
            payable(user_).transfer(amount_);
        } else IERC20(token_).safeTransfer(user_, amount_);

        decreaseBalance(user_, token_, amount_);

        emit SendToWallet(token_, amount_);
        return amount_;
    }

    /**
     * @notice Emergency function that allows to recover all tokens in the state they are in.
     * @param _tokens Array of the tokens to be withdrawn.
     * @param _amounts Array of the amounts to be withdrawn.
     */
    function recoverAll(IERC20[] memory _tokens, uint256[] memory _amounts) public nonReentrant {
        if (_tokens.length <= 0) revert Nodes__EmptyArray();
        if (_tokens.length != _amounts.length) revert Nodes__InvalidArrayLength();

        for (uint256 _i = 0; _i < _tokens.length; _i++) {
            IERC20 _tokenAddress = _tokens[_i];

            uint256 _userBalance = getBalance(msg.sender, _tokenAddress);
            if (_userBalance < _amounts[_i]) revert Nodes__InsufficientBalance();

            if(address(_tokenAddress) == WFTM) {
                IWETH(WFTM).withdraw(_amounts[_i]);
                payable(msg.sender).transfer(_amounts[_i]);
            } else _tokenAddress.safeTransfer(msg.sender, _amounts[_i]);
            
            decreaseBalance(msg.sender, address(_tokenAddress), _amounts[_i]);

            emit RecoverAll(address(_tokenAddress), _amounts[_i]);
        }
    }

    /**
     * @notice Approve of a token
     * @param token Address of the token wanted to be approved
     * @param spender Address that is wanted to be approved to spend the token
     * @param amount Amount of the token that is wanted to be approved.
     */
    function _approve(
        address token,
        address spender,
        uint256 amount
    ) internal {
        IERC20(token).safeApprove(spender, 0);
        IERC20(token).safeApprove(spender, amount);
    }

    /**
     * @notice Calculate the percentage of a number.
     * @param x Number.
     * @param y Percentage of number.
     * @param scale Division.
     */
    function mulScale(
        uint256 x,
        uint256 y,
        uint128 scale
    ) internal pure returns (uint256) {
        uint256 a = x / scale;
        uint256 b = x % scale;
        uint256 c = y / scale;
        uint256 d = y % scale;

        return a * c * scale + a * d + b * c + (b * d) / scale;
    }

    /**
    * @notice Function that allows you to see the balance you have in the contract of a specific token.
    * @param _user Address of the user who will deposit the tokens.
    * @param _token Contract of the token from which the balance is to be obtained.
    */
    function getBalance(address _user, IERC20 _token) public view returns (uint256) {
        return balance[_user].get(address(_token));
    }

    /**
     * @notice Increase balance of a token for a user
     * @param _user Address of the user that is wanted to increase its balance of a token
     * @param _token Address of the token that is wanted to be increased
     * @param _amount Amount of the token that is wanted to be increased
     */
    function increaseBalance(
        address _user,
        address _token,
        uint256 _amount
    ) private {
        uint256 _userBalance = getBalance(_user, IERC20(_token));
        _userBalance += _amount;
        balance[_user].set(address(_token), _userBalance);
    }

    /**
     * @notice Decrease balance of a token for a user
     * @param _user Address of the user that is wanted to decrease its balance of a token
     * @param _token Address of the token that is wanted to be decreased
     * @param _amount Amount of the token that is wanted to be decreased
     */
    function decreaseBalance(
        address _user,
        address _token,
        uint256 _amount
    ) private {
        uint256 _userBalance = getBalance(_user, IERC20(_token));
        if (_userBalance < _amount) revert Nodes__InsufficientBalance();

        _userBalance -= _amount;
        balance[_user].set(address(_token), _userBalance);
    }

    
    receive() external payable {}
}
