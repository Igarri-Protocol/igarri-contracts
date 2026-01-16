require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 800,
        details: {
          yulDetails: {
            optimizerSteps: "u",
          },
        },
      },
      evmVersion: "paris",
      viaIR: true,
    },
  },
  networks: {
    baseSepolia: {
      url: `https://sepolia.base.org`,
      accounts: [PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: {
      baseSepolia: "CPCJJ5KA7CEXQAW6MMEGDWGH7E3CSH1IC5",
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org/",
        },
      },
    ],
  },
};
