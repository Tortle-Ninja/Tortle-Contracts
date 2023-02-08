const { ethers } = require('hardhat')
const recoverData = require('./recoverData.json')
// const nodesOldABI = require('./nodesOldABI.json')
const batchOldABI = require('./batchOldABI.json')

const recover = async () => {
    for(let index = 0; index < recoverData.length; index++) {
        const user = recoverData[index].user
        const lpToken = recoverData[index].lpToken
        const tortleVault = recoverData[index].tortleVault
        const token0 = recoverData[index].token0
        const token1 = recoverData[index].token1
        const tokenDesired = recoverData[index].tokenDesired
        const amountTokenDesiredMin = recoverData[index].amountTokenDesiredMin
        const amount = recoverData[index].amount

        // const nodesContract = await ethers.getContractAt(nodesOldABI, "0xEDC8736B9686808964C289E03fFab8aa24c7eb56")
        const batchContract = await ethers.getContractAt(batchOldABI, "0x2d8a07D9aacA94954a7474C389362eECF371971F")

        // const withdrawArgs_ = ["", lpToken, tortleVault, token0, token1, tokenDesired, amountTokenDesiredMin, amount]

        // const functionCall = [{
        //     recipeId: "1",
        //     id: "1",
        //     functionName: "withdrawFromFarm((string,string,string,address,string[],bool))",
        //     user: user,
        //     arguments: args_,
        //     hasNext: false
        // }]

        // const balanceBefore = await nodesContract.getBalance(user, tokenDesired)
        // await batchContract.batchFunctions(functionCall, {gasLimit: 9000000})
        // console.log('Withdraw Successful')
        // const balanceAfter = await nodesContract.getBalance(user, tokenDesired)
        // const amountDesired = balanceAfter - balanceBefore
        // await nodesContract.sendToWallet(user, tokenDesired, amountDesired)
        const sendToWalletArgs_ = [tokenDesired, "541550000000000000000"]
        await batchContract.batchFunctions([{
            recipeId: "1",
            id: "SendToWallet1",
            functionName: "sendToWallet((string,string,string,address,string[],bool))",
            user: user,
            arguments: sendToWalletArgs_,
            hasNext: false
        }])
        console.log('Send To Wallet Successful')
    }
}

recover()