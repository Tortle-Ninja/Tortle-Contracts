// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './Nodes.sol';
import './lib/StringUtils.sol';
import './interfaces/IBeets.sol';

contract Batch {
    address public owner;
    Nodes public nodes;
    uint8 public constant TOTAL_FEE = 150; //1.50%
    uint256[] public auxStack;
    BatchSwapStep[] private batchSwapStep;

    struct Function {
        string recipeId;
        string id;
        string functionName;
        address user;
        bytes arguments;
        bool hasNext;
    }

    struct BatchSwapStruct {
        bytes32[] poolId;
        uint256[] assetInIndex;
        uint256[] assetOutIndex;
        uint256[] amount;
    }

    struct SplitStruct {
        IAsset[] firstTokens;
        IAsset[] secondTokens;
        uint256 amount;
        uint256 percentageFirstToken;
        uint256 amountOutMinFirst;
        uint256 amountOutMinSecond;
        uint8[] providers;
        BatchSwapStruct batchSwapStepFirstToken;
        BatchSwapStruct batchSwapStepSecondToken;
        string firstHasNext;
        string secondHasNext;
    }

    event AddFundsForTokens(string indexed recipeId, string indexed id, address tokenInput, uint256 amount);
    event AddFundsForFTM(string indexed recipeId, string indexed id, uint256 amount);
    event Split(string indexed recipeId, string indexed id, address tokenInput, uint256 amountIn, address tokenOutput1, uint256 amountOutToken1, address tokenOutput2, uint256 amountOutToken2);
    event SwapTokens(string indexed recipeId, string indexed id, address tokenInput, uint256 amountIn, address tokenOutput, uint256 amountOut);
    event Liquidate(string indexed recipeId, string indexed id, address[] tokensInput, uint256[] amountsIn, address tokenOutput, uint256 amountOut);
    event SendToWallet(string indexed recipeId, string indexed id, address tokenOutput, uint256 amountOut);
    event lpDeposited(string indexed recipeId, string indexed id, address lpToken, uint256 amount);
    event ttDeposited(string indexed recipeId, string indexed id, address ttVault, uint256 amount);
    event lpWithdrawed(string indexed recipeId, string indexed id, address lpToken, uint256 amountLp, address tokenDesired, uint256 amountTokenDesired);
    event ttWithdrawed(string indexed recipeId, string indexed id, address ttVault, uint256 amountTt, address tokenDesired, uint256 amountTokenDesired, uint256 rewardAmount);

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'You must be the owner.');
        _;
    }

    function setNodeContract(Nodes _nodes) public onlyOwner {
        nodes = _nodes;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), 'This function is internal');
        _;
    }

    function batchFunctions(Function[] memory _functions) public onlyOwner {
        for (uint256 i = 0; i < _functions.length; i++) {
            (bool success, ) = address(this).call(abi.encodeWithSignature(_functions[i].functionName, _functions[i]));
            if (!success) revert();
        }
        if (auxStack.length > 0) deleteAuxStack();
    }

    function deleteAuxStack() private {
        for (uint8 i = 1; i <= auxStack.length; i++) {
            auxStack.pop();
        }
    }

    function deleteBatchSwapStep() private {
        for (uint8 i; i < batchSwapStep.length; i++) {
            batchSwapStep.pop();
        }
    }

    function createBatchSwapObject(BatchSwapStruct memory batchSwapStruct_) private returns(BatchSwapStep[] memory newBatchSwapStep) {
        for(uint16 x; x < batchSwapStruct_.poolId.length; x++) {
            BatchSwapStep memory batchSwapStep_;
            batchSwapStep_.poolId = batchSwapStruct_.poolId[x];
            batchSwapStep_.assetInIndex = batchSwapStruct_.assetInIndex[x];
            batchSwapStep_.assetOutIndex = batchSwapStruct_.assetOutIndex[x];
            batchSwapStep_.amount = batchSwapStruct_.amount[x];
            batchSwapStep_.userData = bytes("0x");
            batchSwapStep.push(batchSwapStep_);
        }
        newBatchSwapStep = batchSwapStep;
        deleteBatchSwapStep();
    }

    function addFundsForTokens(Function memory args) public onlySelf {
        (address token_,
        uint256 amount_) = abi.decode(args.arguments, (address, uint256));

        uint256 amount = nodes.addFundsForTokens(args.user, token_, amount_);
        if (args.hasNext) {
            auxStack.push(amount);
        }

        emit AddFundsForTokens(args.recipeId, args.id, token_, amount);
    }

    function addFundsForFTM(Function memory args) public onlySelf {
        uint256 amount_ = abi.decode(args.arguments, (uint256));
        uint256 _fee = ((amount_ * TOTAL_FEE) / 10000);
        amount_ -= _fee;
        if (args.hasNext) {
            auxStack.push(amount_);
        }

        emit AddFundsForFTM(args.recipeId, args.id, amount_);
    }

    function swapTokens(Function memory args) public onlySelf {
        (IAsset[] memory tokens_,
        uint256 amount_,
        uint256 amountOutMin_,
        BatchSwapStruct memory batchSwapStruct_,
        uint8 provider_) = abi.decode(args.arguments, (IAsset[], uint256, uint256, BatchSwapStruct, uint8));
        
        if (auxStack.length > 0) {
            amount_ = auxStack[auxStack.length - 1];
            auxStack.pop();
        }

        BatchSwapStep[] memory batchSwapStep_;
        if(provider_ == 1) {
            batchSwapStep_ = createBatchSwapObject(batchSwapStruct_);
        }

        uint256 amountOut = nodes.swapTokens(args.user, provider_, tokens_, amount_, amountOutMin_, batchSwapStep_);
        if (args.hasNext) {
            auxStack.push(amountOut);
        }

        emit SwapTokens(args.recipeId, args.id, address(tokens_[0]), amount_, address(tokens_[tokens_.length - 1]), amountOut);
    }

    function split(Function memory args) public onlySelf {
        (SplitStruct memory splitStruct_) = abi.decode(args.arguments, (SplitStruct));

        if (auxStack.length > 0) {
            splitStruct_.amount = auxStack[auxStack.length - 1];
            auxStack.pop();
        }

        BatchSwapStep[] memory batchSwapStepFirstToken_ = createBatchSwapObject(splitStruct_.batchSwapStepFirstToken);
        BatchSwapStep[] memory batchSwapStepSecondToken_ = createBatchSwapObject(splitStruct_.batchSwapStepSecondToken);

        bytes memory data = abi.encode(args.user, splitStruct_.firstTokens, splitStruct_.secondTokens, splitStruct_.amount, splitStruct_.percentageFirstToken, splitStruct_.amountOutMinFirst, splitStruct_.amountOutMinSecond, splitStruct_.providers, batchSwapStepFirstToken_, batchSwapStepSecondToken_);
        uint256[] memory amountOutTokens = nodes.split(data);
        if (StringUtils.equal(splitStruct_.firstHasNext, 'y')) {
            auxStack.push(amountOutTokens[0]);
        }
        if (StringUtils.equal(splitStruct_.secondHasNext, 'y')) {
            auxStack.push(amountOutTokens[1]);
        }

        emit Split(args.recipeId, args.id, address(splitStruct_.firstTokens[0]), splitStruct_.amount, address(splitStruct_.firstTokens[splitStruct_.firstTokens.length - 1]), amountOutTokens[0], address(splitStruct_.secondTokens[splitStruct_.secondTokens.length - 1]), amountOutTokens[1]);
    }

    function depositOnLp(Function memory args) public onlySelf {
        (bytes32 poolId_,
        address lpToken_,
        address[] memory tokens_,
        uint256[] memory amounts_,
        uint256 amountOutMin0_,
        uint256 amountOutMin1_) = abi.decode(args.arguments, (bytes32, address, address[], uint256[], uint256, uint256));

        if (auxStack.length > 0) {
            amounts_[0] = auxStack[auxStack.length - 2];
            amounts_[1] = auxStack[auxStack.length - 1];
            auxStack.pop();
            auxStack.pop();
        }

        uint256 lpRes = nodes.depositOnLp(
            args.user,
            poolId_,
            lpToken_,
            tokens_,
            amounts_,
            amountOutMin0_,
            amountOutMin1_
        );

        if (args.hasNext) {
            auxStack.push(lpRes);
        }

        emit lpDeposited(args.recipeId, args.id, lpToken_, lpRes);
    }

    function withdrawFromLp(Function memory args) public onlySelf {
        (bytes32 poolId_,
        address lpToken_,
        address[] memory tokens_,
        uint256[] memory amountsOutMin_,
        uint256 amount_) = abi.decode(args.arguments, (bytes32, address, address[], uint256[], uint256));

        if (auxStack.length > 0) {
            amount_ = auxStack[auxStack.length - 1];
            auxStack.pop();
        }

        uint256 amountTokenDesired = nodes.withdrawFromLp(args.user, poolId_, lpToken_, tokens_, amountsOutMin_, amount_);
        
        if (args.hasNext) {
            auxStack.push(amountTokenDesired);
        }

        address tokenOut_;
        if(lpToken_ != address(0)) {
            tokenOut_ = tokens_[3];
        } else {
            tokenOut_ = tokens_[0];
        }

        emit lpWithdrawed(
            args.recipeId,
            args.id,
            lpToken_,
            amount_,
            tokenOut_,
            amountTokenDesired
        );
    }

    function depositOnFarm(Function memory args) public onlySelf {
        (address lpToken_,
        address tortleVault_,
        address[] memory tokens_,
        uint256 amount0_,
        uint256 amount1_) = abi.decode(args.arguments, (address, address, address[], uint256, uint256));

        uint256[] memory result_ = nodes.depositOnFarmTokens(args.user, lpToken_, tortleVault_, tokens_, amount0_, amount1_, auxStack);
        while (result_[0] != 0) {
            auxStack.pop();
            result_[0]--;
        }

        emit ttDeposited(args.recipeId, args.id, tortleVault_, result_[1]); // ttVault address and ttAmount
        if (args.hasNext) {
            auxStack.push(result_[1]);
        }
    }

    function withdrawFromFarm(Function memory args) public onlySelf {
        (address lpToken_,
        address tortleVault_,
        address[] memory tokens_,
        uint256 amountOutMin_,
        uint256 amount_) = abi.decode(args.arguments, (address, address, address[], uint256, uint256));

        if (auxStack.length > 0) {
            amount_ = auxStack[auxStack.length - 1];
            auxStack.pop();
        }

        (uint256 rewardAmount, uint256 amountTokenDesired) = nodes.withdrawFromFarm(args.user, lpToken_, tortleVault_, tokens_, amountOutMin_, amount_);
        
        if (args.hasNext) {
            auxStack.push(amountTokenDesired);
        }

        emit ttWithdrawed(
            args.recipeId,
            args.id,
            tortleVault_,
            amount_,
            tokens_[3],
            amountTokenDesired,
            rewardAmount
        );
    }

    function sendToWallet(Function memory args) public onlySelf {
        (address token_,
        uint256 amount_) = abi.decode(args.arguments, (address, uint256));

        if (auxStack.length > 0) {
            amount_ = auxStack[auxStack.length - 1];
            auxStack.pop();
        }

        uint256 amount = nodes.sendToWallet(args.user, IERC20(token_), amount_);

        emit SendToWallet(args.recipeId, args.id, token_, amount);
    }

    function liquidate(Function memory args) public onlySelf {
        (address[] memory tokens_,
        uint256[] memory amounts_,
        address tokenOutput_,
        uint256 amountOutMin_) = abi.decode(args.arguments, (address[], uint256[], address, uint256));

        for(uint16 x; x < tokens_.length; x++) {
            if(auxStack.length > 0) {
                amounts_[x] = auxStack[auxStack.length - 1];
                auxStack.pop();
            }
        }

        uint256 amountOut = nodes.liquidate(args.user, tokens_, amounts_, tokenOutput_, amountOutMin_);

        emit Liquidate(args.recipeId, args.id, tokens_, amounts_, tokenOutput_, amountOut);
    }

    receive() external payable {}
}
