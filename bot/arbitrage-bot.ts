import { ethers } from "ethers";

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

interface ArbitrageOpportunity {
  dexName: string;
  tokenPath: string[];
  expectedProfit: bigint;
  gasCostEstimate: bigint;
  isProfitable: boolean;
}

class ArbitrageBot {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;
  private flashLoanContract: ethers.Contract;
  private priceOracleContract: ethers.Contract;
  private gasPrice: bigint = 0n;
  private lastBlockNumber: number = 0;

  constructor(
    rpcUrl: string,
    privateKey: string,
    flashLoanAddress: string,
    priceOracleAddress: string
  ) {
    this.provider = new ethers.JsonRpcProvider(rpcUrl);
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
    
    // Update gas price periodically
    this.updateGasPrice();
    setInterval(() => this.updateGasPrice(), 30000); // Every 30 seconds
  }

  /**
   * Update current gas price
   */
  private async updateGasPrice(): Promise<void> {
    try {
      const feeData = await this.provider.getFeeData();
      this.gasPrice = feeData.gasPrice ? feeData.gasPrice : 0n;
      console.log(`Current gas price: ${ethers.formatUnits(this.gasPrice, "gwei")} Gwei`);
    } catch (error) {
      console.error("Error updating gas price:", error);
    }
  }

  /**
   * Monitor for arbitrage opportunities
   */
  public async monitorOpportunities(): Promise<void> {
    console.log("Starting arbitrage monitoring...");
    
    // Listen for new blocks
    this.provider.on("block", async (blockNumber: number) => {
      if (blockNumber <= this.lastBlockNumber) return;
      this.lastBlockNumber = blockNumber;
      
      console.log(`Processing block ${blockNumber}`);
      
      try {
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
  private async findArbitrageOpportunities(): Promise<ArbitrageOpportunity[]> {
    const opportunities: ArbitrageOpportunity[] = [];
    
    // Common token paths to check
    const tokenPaths = [
      [TOKEN_ADDRESSES.USDC, TOKEN_ADDRESSES.WETH, TOKEN_ADDRESSES.DAI, TOKEN_ADDRESSES.USDC],
      [TOKEN_ADDRESSES.USDC, TOKEN_ADDRESSES.WMATIC, TOKEN_ADDRESSES.WETH, TOKEN_ADDRESSES.USDC],
      [TOKEN_ADDRESSES.DAI, TOKEN_ADDRESSES.WETH, TOKEN_ADDRESSES.USDC, TOKEN_ADDRESSES.DAI]
    ];
    
    const testAmount = ethers.parseUnits("1000", 6); // 1000 USDC
    
    for (const path of tokenPaths) {
      for (const dexName in DEX_ADDRESSES) {
        try {
          // Get price from DEX
          const price = await this.priceOracleContract.getPrice(
            dexName,
            path[0],
            path[path.length - 1],
            testAmount
          ) as bigint;
          
          // Calculate profit (simplified)
          const expectedProfit = price - testAmount;
          const gasCostEstimate = this.gasPrice * 300000n; // Estimate gas cost
          const isProfitable = expectedProfit > gasCostEstimate;
          
          opportunities.push({
            dexName,
            tokenPath: path.map(addr => this.getTokenSymbol(addr)),
            expectedProfit,
            gasCostEstimate,
            isProfitable
          });
        } catch (error) {
          console.error(`Error checking ${dexName}:`, error);
        }
      }
    }
    
    return opportunities;
  }

  /**
   * Execute arbitrage trade
   */
  private async executeArbitrage(opportunity: ArbitrageOpportunity): Promise<void> {
    try {
      console.log(`Executing arbitrage on ${opportunity.dexName}`);
      
      // Check risk configuration with error handling
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
      
      // Prepare transaction
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC
      const slippageBps = 50; // 0.5%
      
      // Estimate gas with error handling
      try {
        const gasEstimate = await this.flashLoanContract.initiateFlashLoan.estimateGas(
          TOKEN_ADDRESSES.USDC,
          amount,
          slippageBps
        ) as bigint;
        
        // Execute flash loan
        const tx = await this.flashLoanContract.initiateFlashLoan(
          TOKEN_ADDRESSES.USDC,
          amount,
          slippageBps,
          {
            gasLimit: gasEstimate * 120n / 100n, // Add 20% buffer
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
        ]) as ethers.TransactionReceipt;
        
        console.log("Transaction confirmed:", receipt.hash);
        
        // Log results
        console.log(`Gas used: ${receipt.gasUsed.toString()}`);
        console.log(`Effective gas price: ${ethers.formatUnits(receipt.gasPrice, "gwei")} Gwei`);
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
  private getTokenSymbol(address: string): string {
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
  public stop(): void {
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

export { ArbitrageBot };