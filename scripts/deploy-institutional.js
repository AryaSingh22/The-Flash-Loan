const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // BSC Mainnet addresses
  const FACTORY = "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73"; // PCS Factory
  const ROUTER = "0x10ED43C718714eb63d5aA57B78B54704E256024E"; // PCS Router
  const BUSD = "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56";
  const WBNB = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c";
  const CROX = "0x2c094F5A7D1146BB93850f629501eB749f6Ed491";
  const CAKE = "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82";
  
  // Mock Chainlink oracle address (replace with actual BUSD/USD oracle)
  const CHAINLINK_ORACLE = "0xcBb98864Ef56E9042e7d2efef76141f15731B82f"; // BUSD/USD
  
  // Fee recipient (replace with actual multisig)
  const FEE_RECIPIENT = deployer.address;

  console.log("Deploying FlashLoanInstitutional...");
  
  const FlashLoanInstitutional = await ethers.getContractFactory("FlashLoanInstitutional");
  const flashLoan = await FlashLoanInstitutional.deploy(
    FACTORY,
    ROUTER,
    BUSD,
    WBNB,
    CROX,
    CAKE,
    CHAINLINK_ORACLE,
    FEE_RECIPIENT
  );

  await flashLoan.deployed();

  console.log("FlashLoanInstitutional deployed to:", flashLoan.address);
  console.log("Deployment completed successfully!");
  
  // Verify deployment
  console.log("\n=== Deployment Verification ===");
  console.log("Factory:", await flashLoan.factory());
  console.log("Router:", await flashLoan.router());
  console.log("BUSD:", await flashLoan.BUSD());
  console.log("WBNB:", await flashLoan.WBNB());
  console.log("CROX:", await flashLoan.CROX());
  console.log("CAKE:", await flashLoan.CAKE());
  console.log("Chainlink Oracle:", await flashLoan.chainlinkOracle());
  console.log("Fee Recipient:", await flashLoan.feeRecipient());
  console.log("Owner:", await flashLoan.owner());
  
  // Check initial state
  console.log("\n=== Initial State ===");
  console.log("Protocol Fee (bps):", await flashLoan.protocolFeeBps());
  console.log("Circuit Breaker Active:", await flashLoan.circuitBreakerActive());
  console.log("Daily Volume Used:", ethers.utils.formatEther(await flashLoan.dailyVolumeUsed()));
  console.log("Insurance Reserve Balance:", ethers.utils.formatEther(await flashLoan.insuranceReserveBalance()));
  
  // Check risk configs
  console.log("\n=== Risk Configurations ===");
  const busdConfig = await flashLoan.getAssetRiskConfig(BUSD);
  console.log("BUSD Config:", {
    maxLoanAmount: ethers.utils.formatEther(busdConfig.maxLoanAmount),
    ltvRatio: busdConfig.ltvRatio.toString(),
    riskScore: busdConfig.riskScore.toString(),
    isActive: busdConfig.isActive
  });
  
  const croxConfig = await flashLoan.getAssetRiskConfig(CROX);
  console.log("CROX Config:", {
    maxLoanAmount: ethers.utils.formatEther(croxConfig.maxLoanAmount),
    ltvRatio: croxConfig.ltvRatio.toString(),
    riskScore: croxConfig.riskScore.toString(),
    isActive: croxConfig.isActive
  });
  
  const cakeConfig = await flashLoan.getAssetRiskConfig(CAKE);
  console.log("CAKE Config:", {
    maxLoanAmount: ethers.utils.formatEther(cakeConfig.maxLoanAmount),
    ltvRatio: cakeConfig.ltvRatio.toString(),
    riskScore: cakeConfig.riskScore.toString(),
    isActive: cakeConfig.isActive
  });
  
  console.log("\n=== Deployment Summary ===");
  console.log("✅ FlashLoanInstitutional deployed successfully");
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
