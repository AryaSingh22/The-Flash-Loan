const { ethers } = require("hardhat");

async function main() {
  try {
    console.log("Testing contract compilation...");
    
    // Try to get the contract factory
    const FlashLoanPolygon = await ethers.getContractFactory("FlashLoanPolygon");
    console.log("FlashLoanPolygon contract factory created successfully");
    
    // Try to get the PriceOraclePolygon contract factory
    const PriceOraclePolygon = await ethers.getContractFactory("PriceOraclePolygon");
    console.log("PriceOraclePolygon contract factory created successfully");
    
    console.log("All contracts compiled successfully!");
  } catch (error) {
    console.error("Error during compilation test:", error);
  }
}

main().then(() => process.exit(0)).catch((error) => {
  console.error(error);
  process.exit(1);
});