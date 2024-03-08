require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");

const accounts = require("./accounts.json")

function getAccountByNetworkName(name) {
  return accounts[name]
}


module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    localhost: {
      chainId: 31337,
      url: "http://127.0.0.1:8545/",
      accounts: getAccountByNetworkName('localhost')
    },
    holesky: {
      url: "https://rpc.holesky.ethpandaops.io",
      chainId: 17000,
      accounts: getAccountByNetworkName('holesky'),
    }
  },
  solidity: {
    compilers: [
      {
        version: "0.6.11",
      },
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
    ],
    overrides: {
      'contracts/0.6.11/deposit_contract.sol': {
        version: '0.6.11',
        settings: {
          optimizer: {
            enabled: true,
            runs: 5000000, // https://etherscan.io/address/0x00000000219ab540356cbb839cbe05303d7705fa#code
          },
        },
      },
    }
  },
  etherscan: {
    
  },
};
