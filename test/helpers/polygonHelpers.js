const { ethers } = require("hardhat");

// Polygon Mainnet addresses
const POLYGON_ADDRESSES = {
  // QuickSwap
  QUICKSWAP_FACTORY: "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32",
  QUICKSWAP_ROUTER: "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff",
  
  // SushiSwap
  SUSHISWAP_FACTORY: "0xc35DADB65012eC5796536bD9864eD8773aBc74C4",
  SUSHISWAP_ROUTER: "0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506",
  
  // Tokens
  USDC: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
  WMATIC: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
  WETH: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
  DAI: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063",
  
  // Oracles
  USDC_USD_ORACLE: "0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7",
  MATIC_USD_ORACLE: "0xAB594600376Ec9fD91F8e885dADF0CE036862dE0",
  ETH_USD_ORACLE: "0xF9680D99D6C9589e2a93a78A04A279e509205945"
};

/**
 * Impersonate an account with sufficient token balance
 * @param {string} tokenAddress - Token contract address
 * @param {string} holderAddress - Address of account with token balance
 * @returns {Promise<ethers.Signer>} Impersonated signer
 */
async function impersonateTokenHolder(tokenAddress, holderAddress) {
  await hre.network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [holderAddress],
  });
  
  return await ethers.getSigner(holderAddress);
}

/**
 * Get token balance for an address
 * @param {string} tokenAddress - Token contract address
 * @param {string} accountAddress - Account address
 * @returns {Promise<ethers.BigNumber>} Token balance
 */
async function getTokenBalance(tokenAddress, accountAddress) {
  const ERC20ABI = [
    "function balanceOf(address) view returns (uint256)",
    "function decimals() view returns (uint8)"
  ];
  
  const token = new ethers.Contract(tokenAddress, ERC20ABI, ethers.provider);
  const balance = await token.balanceOf(accountAddress);
  const decimals = await token.decimals();
  
  return { balance, decimals };
}

/**
 * Create a test environment with sufficient token balances
 * @param {ethers.Signer} signer - Signer to fund
 * @param {Array} tokenAddresses - Array of token addresses to fund
 * @param {Array} holderAddresses - Array of holder addresses with balances
 */
async function setupTestEnvironment(signer, tokenAddresses, holderAddresses) {
  const signerAddress = await signer.getAddress();
  
  for (let i = 0; i < tokenAddresses.length; i++) {
    const tokenAddress = tokenAddresses[i];
    const holderAddress = holderAddresses[i];
    
    // Impersonate holder
    const holder = await impersonateTokenHolder(tokenAddress, holderAddress);
    
    // Get token contract
    const ERC20ABI = [
      "function balanceOf(address) view returns (uint256)",
      "function transfer(address, uint256) returns (bool)",
      "function decimals() view returns (uint8)"
    ];
    
    const token = new ethers.Contract(tokenAddress, ERC20ABI, holder);
    
    // Get holder balance
    const balance = await token.balanceOf(holderAddress);
    const decimals = await token.decimals();
    
    console.log(`Holder ${holderAddress} has ${ethers.utils.formatUnits(balance, decimals)} tokens`);
    
    // Transfer some tokens to signer (if holder has enough)
    if (balance.gt(ethers.utils.parseUnits("1000", decimals))) {
      const transferAmount = ethers.utils.parseUnits("1000", decimals);
      await token.connect(holder).transfer(signerAddress, transferAmount);
      console.log(`Transferred ${ethers.utils.formatUnits(transferAmount, decimals)} tokens to ${signerAddress}`);
    }
  }
}

/**
 * Get pair address for two tokens
 * @param {string} factoryAddress - Factory contract address
 * @param {string} tokenA - First token address
 * @param {string} tokenB - Second token address
 * @returns {Promise<string>} Pair address
 */
async function getPairAddress(factoryAddress, tokenA, tokenB) {
  const factoryABI = [
    "function getPair(address, address) view returns (address)"
  ];
  
  const factory = new ethers.Contract(factoryAddress, factoryABI, ethers.provider);
  return await factory.getPair(tokenA, tokenB);
}

module.exports = {
  POLYGON_ADDRESSES,
  impersonateTokenHolder,
  getTokenBalance,
  setupTestEnvironment,
  getPairAddress
};