const fs = require('fs');
const hre = require("hardhat");

async function recordTxDetails(contract, name) {
  const tx = await hre.ethers.provider.getTransaction(contract.deploymentTransaction().hash);
  const receipt = await hre.ethers.provider.getTransactionReceipt(contract.deploymentTransaction().hash);
  const details = {
    [`${name}`]: {
      "hash": tx.hash,
      "gasPrice": tx.gasPrice,
      "gasLimit": tx.gasLimit,
      "gasUsed": receipt.gasUsed,
      "contractAddress": receipt.contractAddress,
      "chainId": tx.chainId,
    },
  }

  BigInt.prototype.toJSON = function () { return this.toString() };
  let filename = 'depoly_report-' + hre.network.config.chainId + '.json';
  appendJsonToFile(filename, details);
}

function appendJsonToFile(filename, json) {
  const exist = fs.existsSync(filename);
  let data = {};
  let state = {};
  if (exist) {
    data = fs.readFileSync(filename);
    state = JSON.parse(data)
  }
  state = { ...state, ...json }
  fs.writeFileSync(filename, JSON.stringify(state, null, 2))
}

module.exports = { recordTxDetails }