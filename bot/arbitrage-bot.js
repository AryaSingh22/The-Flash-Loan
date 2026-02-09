const { ethers } = require("ethers");
require("dotenv").config();

// Token addresses on Polygon
const TOKEN_ADDRESSES = {
  USDC: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
  WMATIC: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
  WETH: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
  DAI: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063"
};

// DEX addresses on Polygon
const DEX_ADDRESSES = {
  QuickSwap: {
    factory: "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32",
    router: "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"
  },
  SushiSwap: {
    factory: "0xc35DADB65012eC5796536bD9864eD8773aBc74C4",
    router: "0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506"
  }
};

// FlashLoanPolygon ABI (simplified)
const FLASH_LOAN_ABI = [
  "function initiateFlashLoan(address _token, uint256 _amount, uint256 _slippageBps) external",
  "function executeMultiDexArbitrage(address _token, uint256 _amount, uint256 _slippageBps, address[] calldata _routers, address[][] calldata _paths) external returns (uint256)",
  "function getAssetRiskConfig(address asset) external view returns (uint256 maxLoanAmount, uint256 ltvRatio, uint256 riskScore, bool isActive)",
  "function circuitBreakerActive() public view returns (bool)"
];

// PriceOraclePolygon ABI (simplified)
const PRICE_ORACLE_ABI = [
  "function getPrice(string memory dexName, address tokenA, address tokenB, uint256 amountIn) public view returns (uint256 amountOut)",
  "function getArbitrageOpportunity(address tokenA, address tokenB, uint256 amountIn) public view returns (string memory dexWithBestPrice, uint256 bestPrice, uint256 priceDifference)",
  "function addChainlinkOracle(address token, address oracle) external",
  "function addDex(string memory name, address factory, address router) external"
];

class ArbitrageBot {
  constructor(rpcUrl, privateKey, flashLoanAddress, priceOracleAddress) {
    this.provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(privateKey, this.provider);
    
    // Initialize contracts with proper ABIs
    this.flashLoanContract = new ethers.Contract(
      flashLoanAddress,
      FLASH_LOAN_ABI,
      this.wallet
    );
    
    this.priceOracleContract = new ethers.Contract(
      priceOracleAddress,
      PRICE_ORACLE_ABI,
      this.wallet
    );
    
    this.gasPrice = ethers.BigNumber.from(0);
    this.lastBlockNumber = 0;
    
    // Update gas price periodically
    this.updateGasPrice();
    setInterval(() => this.updateGasPrice(), 30000); // Every 30 seconds
  }

  /**
   * Update current gas price
   */
  async updateGasPrice() {
    try {
      const feeData = await this.provider.getFeeData();
      this.gasPrice = feeData.gasPrice || ethers.BigNumber.from(0);
      console.log(`Current gas price: ${ethers.utils.formatUnits(this.gasPrice, "gwei")} Gwei`);
    } catch (error) {
      console.error("Error updating gas price:", error);
    }
  }

  /**
   * Monitor for arbitrage opportunities
   */
  async monitorOpportunities() {
    console.log("Starting arbitrage monitoring...");
    
    // Listen for new blocks
    this.provider.on("block", async (blockNumber) => {
      if (blockNumber <= this.lastBlockNumber) return;
      this.lastBlockNumber = blockNumber;
      
      console.log(`Processing block ${blockNumber}`);
      
      try {
        // Check if circuit breaker is active
        const circuitBreakerActive = await this.flashLoanContract.circuitBreakerActive();
        if (circuitBreakerActive) {
          console.log("Circuit breaker is active, skipping arbitrage check");
          return;
        }
        
        // Check for opportunities
        const opportunities = await this.findArbitrageOpportunities();
        
        for (const opportunity of opportunities) {
          if (opportunity.isProfitable) {
            console.log("Found profitable opportunity:", opportunity);
            await this.executeArbitrage(opportunity);
          }
        }
      } catch (error) {
        console.error("Error in monitoring loop:", error);
      }
    });
  }

  /**
   * Find arbitrage opportunities across DEXs
   */
  async findArbitrageOpportunities() {
    const opportunities = [];
    
    // Common token paths to check
    const tokenPaths = [
      [TOKEN_ADDRESSES.USDC, TOKEN_ADDRESSES.WETH, TOKEN_ADDRESSES.DAI, TOKEN_ADDRESSES.USDC],
      [TOKEN_ADDRESSES.USDC, TOKEN_ADDRESSES.WMATIC, TOKEN_ADDRESSES.WETH, TOKEN_ADDRESSES.USDC],
      [TOKEN_ADDRESSES.DAI, TOKEN_ADDRESSES.WETH, TOKEN_ADDRESSES.USDC, TOKEN_ADDRESSES.DAI]
    ];
    
    const testAmount = ethers.utils.parseUnits("1000", 6); // 1000 USDC
    
    for (const path of tokenPaths) {
      try {
        // Get arbitrage opportunity from price oracle
        const result = await this.priceOracleContract.getArbitrageOpportunity(
          path[0], 
          path[path.length - 1], 
          testAmount
        );
        
        if (result.dexWithBestPrice && result.bestPrice.gt(0)) {
          // Calculate profit
          const expectedProfit = result.bestPrice.sub(testAmount);
          const gasCostEstimate = this.gasPrice.mul(500000); // Estimate gas cost for flash loan
          const isProfitable = expectedProfit.gt(gasCostEstimate) && expectedProfit.gt(0);
          
          opportunities.push({
            dexName: result.dexWithBestPrice,
            tokenPath: path.map(addr => this.getTokenSymbol(addr)),
            expectedProfit: ethers.utils.formatUnits(expectedProfit, 6),
            gasCostEstimate: ethers.utils.formatUnits(gasCostEstimate, 18),
            isProfitable: isProfitable,
            rawProfit: expectedProfit,
            rawGasCost: gasCostEstimate
          });
        }
      } catch (error) {
        console.error(`Error checking arbitrage opportunity:`, error);
      }
    }
    
    return opportunities;
  }

  /**
   * Execute arbitrage trade
   */
  async executeArbitrage(opportunity) {
    try {
      console.log(`Executing arbitrage on ${opportunity.dexName}`);
      
      // Check risk configuration
      try {
        const usdcConfig = await this.flashLoanContract.getAssetRiskConfig(TOKEN_ADDRESSES.USDC);
        if (!usdcConfig.isActive) {
          console.log("USDC is not active for flash loans, skipping execution");
          return;
        }
      } catch (error) {
        console.error("Error checking risk configuration:", error);
        return;
      }
      
      // Prepare parameters
      const amount = ethers.utils.parseUnits("1000", 6); // 1000 USDC
      const slippageBps = 50; // 0.5% slippage
      
      // Estimate gas
      try {
        const gasEstimate = await this.flashLoanContract.estimateGas.initiateFlashLoan(
          TOKEN_ADDRESSES.USDC,
          amount,
          slippageBps
        );
        
        console.log(`Gas estimate: ${gasEstimate.toString()}`);
        
        // Execute flash loan with proper gas settings
        const tx = await this.flashLoanContract.initiateFlashLoan(
          TOKEN_ADDRESSES.USDC,
          amount,
          slippageBps,
          {
            gasLimit: gasEstimate.mul(120).div(100), // Add 20% buffer
            gasPrice: this.gasPrice
          }
        );
        
        console.log("Transaction sent:", tx.hash);
        
        // Wait for confirmation with timeout
        const receipt = await Promise.race([
          tx.wait(),
          new Promise((_, reject) => 
            setTimeout(() => reject(new Error("Transaction confirmation timeout")), 60000)
          )
        ]);
        
        console.log("Transaction confirmed:", receipt.transactionHash);
        
        // Log results
        console.log(`Gas used: ${receipt.gasUsed.toString()}`);
        console.log(`Effective gas price: ${ethers.utils.formatUnits(receipt.effectiveGasPrice, "gwei")} Gwei`);
      } catch (error) {
        console.error("Error estimating or executing transaction:", error);
      }
    } catch (error) {
      console.error("Error executing arbitrage:", error);
    }
  }

  /**
   * Get token symbol from address
   */
  getTokenSymbol(address) {
    for (const [symbol, addr] of Object.entries(TOKEN_ADDRESSES)) {
      if (addr.toLowerCase() === address.toLowerCase()) {
        return symbol;
      }
    }
    return address;
  }

  /**
   * Stop monitoring
   */
  stop() {
    this.provider.removeAllListeners("block");
    console.log("Stopped arbitrage monitoring");
  }
}

// Configuration
const CONFIG = {
  RPC_URL: process.env.POLYGON_RPC_URL || "https://polygon-rpc.com/",
  PRIVATE_KEY: process.env.PRIVATE_KEY || "",
  FLASH_LOAN_ADDRESS: process.env.FLASH_LOAN_ADDRESS || "",
  PRICE_ORACLE_ADDRESS: process.env.PRICE_ORACLE_ADDRESS || ""
};

// Main execution
async function main() {
  if (!CONFIG.PRIVATE_KEY || !CONFIG.FLASH_LOAN_ADDRESS || !CONFIG.PRICE_ORACLE_ADDRESS) {
    console.error("Missing required environment variables");
    process.exit(1);
  }

  const bot = new ArbitrageBot(
    CONFIG.RPC_URL,
    CONFIG.PRIVATE_KEY,
    CONFIG.FLASH_LOAN_ADDRESS,
    CONFIG.PRICE_ORACLE_ADDRESS
  );

  // Handle graceful shutdown
  process.on("SIGINT", () => {
    console.log("Shutting down...");
    bot.stop();
    process.exit(0);
  });

  // Start monitoring
  await bot.monitorOpportunities();
}

// Run the bot
if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

module.exports = { ArbitrageBot };