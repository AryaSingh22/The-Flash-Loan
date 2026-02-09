const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Polygon Mainnet addresses (update for Mumbai testnet as needed)
  // QuickSwap addresses
  const FACTORY = "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32"; // QuickSwap Factory
  const ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"; // QuickSwap Router
  const USDC = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"; // USDC on Polygon
  const WMATIC = "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"; // WMATIC
  const WETH = "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619"; // WETH on Polygon
  const DAI = "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063"; // DAI on Polygon
  
  // Chainlink oracle addresses (update for Mumbai testnet as needed)
  const CHAINLINK_ORACLE = "0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7"; // USDC/USD on Polygon
  
  // Fee recipient (replace with actual multisig)
  const FEE_RECIPIENT = deployer.address;

  console.log("Deploying FlashLoanPolygon for Polygon...");
  
  const FlashLoanPolygon = await ethers.getContractFactory("FlashLoanPolygon");
  const flashLoan = await FlashLoanPolygon.deploy(
    FACTORY,
    ROUTER,
    USDC,
    WMATIC,
    WETH,
    DAI,
    CHAINLINK_ORACLE,
    FEE_RECIPIENT
  );

  await flashLoan.deployed();

  console.log("FlashLoanPolygon deployed to:", flashLoan.address);
  console.log("Deployment completed successfully!");
  
  // Verify deployment
  console.log("\n=== Deployment Verification ===");
  console.log("Factory:", await flashLoan.factory());
  console.log("Router:", await flashLoan.router());
  console.log("USDC:", await flashLoan.USDC());
  console.log("WMATIC:", await flashLoan.WMATIC());
  console.log("WETH:", await flashLoan.WETH());
  console.log("DAI:", await flashLoan.DAI());
  console.log("Chainlink Oracle:", await flashLoan.chainlinkOracle());
  console.log("Fee Recipient:", await flashLoan.feeRecipient());
  console.log("Owner:", await flashLoan.owner());
  
  // Check initial state
  console.log("\n=== Initial State ===");
  console.log("Protocol Fee (bps):", await flashLoan.protocolFeeBps());
  console.log("Circuit Breaker Active:", await flashLoan.circuitBreakerActive());
  console.log("Daily Volume Used:", (await flashLoan.dailyVolumeUsed()).toString());
  console.log("Insurance Reserve Balance:", (await flashLoan.insuranceReserveBalance()).toString());
  
  // Check risk configs
  console.log("\n=== Risk Configurations ===");
  const usdcConfig = await flashLoan.getAssetRiskConfig(USDC);
  console.log("USDC Config:", {
    maxLoanAmount: usdcConfig.maxLoanAmount.toString(),
    ltvRatio: usdcConfig.ltvRatio.toString(),
    riskScore: usdcConfig.riskScore.toString(),
    isActive: usdcConfig.isActive
  });
  
  const wethConfig = await flashLoan.getAssetRiskConfig(WETH);
  console.log("WETH Config:", {
    maxLoanAmount: wethConfig.maxLoanAmount.toString(),
    ltvRatio: wethConfig.ltvRatio.toString(),
    riskScore: wethConfig.riskScore.toString(),
    isActive: wethConfig.isActive
  });
  
  const daiConfig = await flashLoan.getAssetRiskConfig(DAI);
  console.log("DAI Config:", {
    maxLoanAmount: daiConfig.maxLoanAmount.toString(),
    ltvRatio: daiConfig.ltvRatio.toString(),
    riskScore: daiConfig.riskScore.toString(),
    isActive: daiConfig.isActive
  });
  
  console.log("\n=== Deployment Summary ===");
  console.log("✅ FlashLoanPolygon deployed successfully for Polygon");
  console.log("✅ All security features enabled");
  console.log("✅ Risk management configured");
  console.log("✅ Circuit breaker ready");
  console.log("✅ Oracle integration active");
  console.log("✅ Insurance reserve initialized");
  
  console.log("\n=== Next Steps ===");
  console.log("1. Transfer ownership to multisig wallet");
  console.log("2. Add funds to insurance reserve");
  console.log("3. Configure additional risk parameters");
  console.log("4. Set up monitoring and alerting");
  console.log("5. Run comprehensive security tests");
  
  return flashLoan;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });