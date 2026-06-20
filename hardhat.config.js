require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.20",        // ← changed from 0.8.19 to 0.8.20
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {},
    amoy: {
      url: process.env.POLYGON_AMOY_RPC,
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      chainId: 80002,
    },
  },
};