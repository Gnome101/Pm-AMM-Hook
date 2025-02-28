import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";
import "@nomicfoundation/hardhat-foundry";

import dotenv from "dotenv";
dotenv.config();

module.exports = {
  solidity: "0.8.26",
  networks: {
    hardhat: {
      forking: {
        url: process.env.BASE_RPC_URL,
      },
    },
    basesep: {
      url: process.env.BASE_RPC_URL,
      accounts: [process.env.PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
};
