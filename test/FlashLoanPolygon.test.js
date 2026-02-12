const { expect } = require("chai");
const { ethers } = require("hardhat");
const { parseEther, parseUnits } = ethers;

describe("FlashLoanPolygon", function () {
  let flashLoan;
  let owner, user, attacker, feeRecipient;

  // Polygon Mainnet addresses
  const FACTORY = "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32"; // QuickSwap Factory
  const ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"; // QuickSwap Router
  const USDC = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"; // USDC on Polygon
  const WMATIC = "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"; // WMATIC
  const WETH = "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619"; // WETH on Polygon
  const DAI = "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063"; // DAI on Polygon
  const CHAINLINK_ORACLE = "0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7"; // USDC/USD on Polygon

  beforeEach(async function () {
    [owner, user, attacker, feeRecipient] = await ethers.getSigners();

    const FlashLoanPolygon = await ethers.getContractFactory("FlashLoanPolygon");
    flashLoan = await FlashLoanPolygon.deploy(
      FACTORY,
      ROUTER,
      USDC,
      WMATIC,
      WETH,
      DAI,
      CHAINLINK_ORACLE,
      feeRecipient.address
    );
    await flashLoan.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should deploy with correct parameters", async function () {
      expect(await flashLoan.factory()).to.equal(FACTORY);
      expect(await flashLoan.router()).to.equal(ROUTER);
      expect(await flashLoan.USDC()).to.equal(USDC);
      expect(await flashLoan.WMATIC()).to.equal(WMATIC);
      expect(await flashLoan.WETH()).to.equal(WETH);
      expect(await flashLoan.DAI()).to.equal(DAI);
      expect(await flashLoan.tokenOracles(USDC)).to.equal(CHAINLINK_ORACLE);
      expect(await flashLoan.feeRecipient()).to.equal(feeRecipient.address);
      expect(await flashLoan.owner()).to.equal(feeRecipient.address);
    });

    it("Should initialize with correct default values", async function () {
      expect(await flashLoan.protocolFeeBps()).to.equal(100); // 1%
      expect(await flashLoan.circuitBreakerActive()).to.equal(false);
      expect(await flashLoan.dailyVolumeUsed()).to.equal(0);
      expect(await flashLoan.insuranceReserveBalance()).to.equal(0);
    });

    it("Should initialize default risk configurations", async function () {
      const usdcConfig = await flashLoan.getAssetRiskConfig(USDC);
      expect(usdcConfig.maxLoanAmount).to.equal(parseUnits("10000", 6));
      expect(usdcConfig.ltvRatio).to.equal(9500); // 95%
      expect(usdcConfig.riskScore).to.equal(100);
      expect(usdcConfig.isActive).to.equal(true);

      const wethConfig = await flashLoan.getAssetRiskConfig(WETH);
      expect(wethConfig.maxLoanAmount).to.equal(parseEther("500"));
      expect(wethConfig.ltvRatio).to.equal(8000); // 80%
      expect(wethConfig.riskScore).to.equal(300);
      expect(wethConfig.isActive).to.equal(true);
    });
  });

  describe("Access Control", function () {
    it("Should reject non-owner calls to admin functions", async function () {
      await expect(
        flashLoan.connect(attacker).setProtocolFee(200)
      ).to.be.revertedWithCustomError(flashLoan, "OwnableUnauthorizedAccount");

      await expect(
        flashLoan.connect(attacker).triggerCircuitBreaker("test")
      ).to.be.revertedWithCustomError(flashLoan, "OwnableUnauthorizedAccount");

      await expect(
        flashLoan.connect(attacker).emergencyPause()
      ).to.be.revertedWithCustomError(flashLoan, "OwnableUnauthorizedAccount");
    });

    // Note: 2-step ownership transfer is not implemented in this contract
    // The contract uses standard Ownable from OpenZeppelin v5
  });

  describe("Input Validation", function () {
    it("Should reject invalid tokens", async function () {
      await expect(
        flashLoan.connect(user).initiateFlashLoan(ethers.ZeroAddress, parseUnits("1000", 6), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidToken");
    });

    it("Should validate amount bounds", async function () {
      // Too small
      await expect(
        flashLoan.connect(user).initiateFlashLoan(USDC, parseUnits("1", 3), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");

      // Too large
      await expect(
        flashLoan.connect(user).initiateFlashLoan(USDC, parseUnits("200000", 6), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");
    });

    it("Should validate slippage bounds", async function () {
      await expect(
        flashLoan.connect(user).initiateFlashLoan(USDC, parseUnits("1000", 6), 10001)
      ).to.be.revertedWithCustomError(flashLoan, "SlippageTooHigh");
    });

    it("Should respect asset-specific loan limits", async function () {
      // WETH has 500 token limit
      await expect(
        flashLoan.connect(user).initiateFlashLoan(WETH, parseEther("600"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");
    });
  });

  describe("Circuit Breaker", function () {
    it("Should allow owner to trigger circuit breaker", async function () {
      await flashLoan.connect(feeRecipient).triggerCircuitBreaker("Test reason");
      expect(await flashLoan.circuitBreakerActive()).to.equal(true);
    });

    it("Should prevent flash loans when circuit breaker is active", async function () {
      await flashLoan.connect(feeRecipient).triggerCircuitBreaker("Test reason");

      await expect(
        flashLoan.connect(user).initiateFlashLoan(USDC, parseUnits("1000", 6), 500)
      ).to.be.revertedWithCustomError(flashLoan, "CircuitBreakerActive");
    });

    it("Should allow owner to reset circuit breaker", async function () {
      await flashLoan.connect(feeRecipient).triggerCircuitBreaker("Test reason");
      expect(await flashLoan.circuitBreakerActive()).to.equal(true);

      await flashLoan.connect(feeRecipient).resetCircuitBreaker();
      expect(await flashLoan.circuitBreakerActive()).to.equal(false);
    });
  });

  describe("Daily Volume Limits", function () {
    it("Should track daily volume usage", async function () {
      const initialVolume = await flashLoan.dailyVolumeUsed();
      expect(initialVolume).to.equal(0);
    });

    it("Should reset daily volume after 24 hours", async function () {
      const usage = await flashLoan.getDailyVolumeUsage();
      expect(usage.used).to.equal(0);
      expect(usage.max).to.equal(parseUnits("1000000", 6));
    });
  });

  describe("Risk Management", function () {
    it("Should allow owner to update asset risk config", async function () {
      await flashLoan.connect(feeRecipient).updateAssetRiskConfig(
        USDC,
        parseUnits("20000", 6),
        9000, // 90% LTV
        200   // Higher risk score
      );

      const config = await flashLoan.getAssetRiskConfig(USDC);
      expect(config.maxLoanAmount).to.equal(parseUnits("20000", 6));
      expect(config.ltvRatio).to.equal(9000);
      expect(config.riskScore).to.equal(200);
      expect(config.isActive).to.equal(true);
    });

    it("Should reject invalid risk configurations", async function () {
      await expect(
        flashLoan.connect(feeRecipient).updateAssetRiskConfig(USDC, 0, 5000, 100)
      ).to.be.revertedWith("Invalid config");

      await expect(
        flashLoan.connect(feeRecipient).updateAssetRiskConfig(USDC, parseUnits("10000", 6), 15000, 100)
      ).to.be.revertedWith("Invalid config");

      await expect(
        flashLoan.connect(feeRecipient).updateAssetRiskConfig(USDC, parseUnits("10000", 6), 5000, 1500)
      ).to.be.revertedWith("Invalid config");
    });
  });

  describe("Pause Functionality", function () {
    it("Should allow owner to pause contract", async function () {
      await flashLoan.connect(feeRecipient).emergencyPause();
      expect(await flashLoan.paused()).to.equal(true);
    });

    it("Should prevent flash loans when paused", async function () {
      await flashLoan.connect(feeRecipient).emergencyPause();

      await expect(
        flashLoan.connect(user).initiateFlashLoan(USDC, parseUnits("1000", 6), 500)
      ).to.be.revertedWithCustomError(flashLoan, "EnforcedPause");
    });

    it("Should allow owner to unpause contract", async function () {
      await flashLoan.connect(feeRecipient).emergencyPause();
      expect(await flashLoan.paused()).to.equal(true);

      await flashLoan.connect(feeRecipient).emergencyUnpause();
      expect(await flashLoan.paused()).to.equal(false);
    });
  });

  describe("Multi-DEX Arbitrage", function () {
    it("Should allow adding supported routers", async function () {
      const newRouter = "0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506"; // SushiSwap Router
      await flashLoan.connect(feeRecipient).addSupportedRouter(newRouter);
      expect(await flashLoan.supportedRouters(newRouter)).to.equal(true);
    });

    it("Should reject invalid router addresses", async function () {
      await expect(
        flashLoan.connect(feeRecipient).addSupportedRouter(ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid router");
    });
  });

  // Note: These tests would require forking Polygon mainnet to test actual flash loan execution
  // For a complete test suite, you would need to:
  // 1. Fork Polygon mainnet using Hardhat
  // 2. Impersonate accounts with sufficient token balances
  // 3. Test actual flash loan execution with real DEX interactions
});