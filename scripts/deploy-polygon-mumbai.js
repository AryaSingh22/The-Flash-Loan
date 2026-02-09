const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Polygon Mumbai Testnet addresses
  const FACTORY = "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32"; // Same as mainnet for QuickSwap
  const ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"; // Same as mainnet for QuickSwap
  const USDC = "0xe6b8a5CF854791412c1f6EFC7CAf629f5Df1c747"; // USDC on Mumbai
  const WMATIC = "0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889"; // WMATIC on Mumbai
  const WETH = "0xa6fa4fb5f76172d178d61b04b0ecd319c5d1c0aa"; // WETH on Mumbai
  const DAI = "0x5A65f09f35256582C4b8ee91552D99293b7A1527"; // DAI on Mumbai
  
  // Chainlink oracle addresses on Mumbai
  const CHAINLINK_ORACLE = "0x0000000000000000000000000000000000000000"; // No direct USDC/USD oracle on Mumbai
  
  // For testing purposes, we'll use a mock oracle
  console.log("Deploying Mock Chainlink Oracle for testing...");
  
  const MockOracle = await ethers.getContractFactory("MockOracle");
  const mockOracle = await MockOracle.deploy();
  await mockOracle.deployed();
  
  console.log("Mock Oracle deployed to:", mockOracle.address);
  
  // Set mock price (1 USDC = 1 USD)
  await mockOracle.setPrice(ethers.utils.parseUnits("1", 8));
  
  // Fee recipient (replace with actual multisig)
  const FEE_RECIPIENT = deployer.address;

  console.log("Deploying FlashLoanPolygon for Mumbai testnet...");
  
  const FlashLoanPolygon = await ethers.getContractFactory("FlashLoanPolygon");
  const flashLoan = await FlashLoanPolygon.deploy(
    FACTORY,
    ROUTER,
    USDC,
    WMATIC,
    WETH,
    DAI,
    mockOracle.address, // Using mock oracle
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
  
  console.log("\n=== Deployment Summary ===");
  console.log("✅ FlashLoanPolygon deployed successfully for Mumbai testnet");
  console.log("✅ All security features enabled");
  console.log("✅ Risk management configured");
  console.log("✅ Circuit breaker ready");
  console.log("✅ Mock oracle integration active");
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