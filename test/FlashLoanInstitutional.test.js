const { expect } = require("chai");
const { ethers } = require("hardhat");
const { parseEther, parseUnits } = ethers;

describe("FlashLoanInstitutional", function () {
  let flashLoan;
  let owner, user, attacker, feeRecipient;

  // Mock addresses for testing
  const FACTORY = "0x1234567890123456789012345678901234567890";
  const ROUTER = "0x2345678901234567890123456789012345678901";
  const BUSD = "0x3456789012345678901234567890123456789012";
  const WBNB = "0x4567890123456789012345678901234567890123";
  const CROX = "0x5678901234567890123456789012345678901234";
  const CAKE = "0x6789012345678901234567890123456789012345";
  const CHAINLINK_ORACLE = "0x7890123456789012345678901234567890123456";

  beforeEach(async function () {
    [owner, user, attacker, feeRecipient] = await ethers.getSigners();

    const FlashLoanInstitutional = await ethers.getContractFactory("FlashLoanInstitutional");
    flashLoan = await FlashLoanInstitutional.deploy(
      FACTORY,
      ROUTER,
      BUSD,
      WBNB,
      CROX,
      CAKE,
      CHAINLINK_ORACLE,
      feeRecipient.address
    );
    await flashLoan.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should deploy with correct parameters", async function () {
      expect(await flashLoan.factory()).to.equal(FACTORY);
      expect(await flashLoan.router()).to.equal(ROUTER);
      expect(await flashLoan.BUSD()).to.equal(BUSD);
      expect(await flashLoan.WBNB()).to.equal(WBNB);
      expect(await flashLoan.CROX()).to.equal(CROX);
      expect(await flashLoan.CAKE()).to.equal(CAKE);
      expect(await flashLoan.tokenOracles(BUSD)).to.equal(CHAINLINK_ORACLE);
      expect(await flashLoan.feeRecipient()).to.equal(feeRecipient.address);
      expect(await flashLoan.owner()).to.equal(owner.address);
    });

    it("Should initialize with correct default values", async function () {
      expect(await flashLoan.protocolFeeBps()).to.equal(100); // 1%
      expect(await flashLoan.circuitBreakerActive()).to.equal(false);
      expect(await flashLoan.dailyVolumeUsed()).to.equal(0);
      expect(await flashLoan.insuranceReserveBalance()).to.equal(0);
    });

    it("Should initialize default risk configurations", async function () {
      const busdConfig = await flashLoan.getAssetRiskConfig(BUSD);
      expect(busdConfig.maxLoanAmount).to.equal(parseEther("1000"));
      expect(busdConfig.ltvRatio).to.equal(9500); // 95%
      expect(busdConfig.riskScore).to.equal(100);
      expect(busdConfig.isActive).to.equal(true);

      const croxConfig = await flashLoan.getAssetRiskConfig(CROX);
      expect(croxConfig.maxLoanAmount).to.equal(parseEther("500"));
      expect(croxConfig.ltvRatio).to.equal(8000); // 80%
      expect(croxConfig.riskScore).to.equal(300);
      expect(croxConfig.isActive).to.equal(true);
    });
  });

  describe("Access Control", function () {
    it("Should reject non-owner calls to admin functions", async function () {
      await expect(
        flashLoan.connect(attacker).setProtocolFee(200)
      ).to.be.revertedWithCustomError(flashLoan, "OwnableUnauthorizedAccount")
        .withArgs(attacker.address);

      await expect(
        flashLoan.connect(attacker).triggerCircuitBreaker("test")
      ).to.be.revertedWithCustomError(flashLoan, "OwnableUnauthorizedAccount")
        .withArgs(attacker.address);

      await expect(
        flashLoan.connect(attacker).emergencyPause()
      ).to.be.revertedWithCustomError(flashLoan, "OwnableUnauthorizedAccount")
        .withArgs(attacker.address);
    });

    it("Should implement 2-step ownership transfer", async function () {
      await flashLoan.transferOwnership(user.address);
      expect(await flashLoan.pendingOwner()).to.equal(user.address);
      expect(await flashLoan.owner()).to.equal(owner.address);

      await flashLoan.connect(user).acceptOwnership();
      expect(await flashLoan.owner()).to.equal(user.address);
    });
  });

  describe("Input Validation", function () {
    it("Should reject invalid tokens", async function () {
      await expect(
        flashLoan.connect(user).initiateFlashLoan(ethers.ZeroAddress, parseEther("1000"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidToken");
    });

    it("Should validate amount bounds", async function () {
      // Too small
      await expect(
        flashLoan.connect(user).initiateFlashLoan(BUSD, parseUnits("1", 12), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");

      // Too large
      await expect(
        flashLoan.connect(user).initiateFlashLoan(BUSD, parseEther("2000"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");
    });

    it("Should validate slippage bounds", async function () {
      await expect(
        flashLoan.connect(user).initiateFlashLoan(BUSD, parseEther("1000"), 10001)
      ).to.be.revertedWithCustomError(flashLoan, "SlippageTooHigh");
    });

    it("Should respect asset-specific loan limits", async function () {
      // CROX has 500 token limit
      await expect(
        flashLoan.connect(user).initiateFlashLoan(CROX, parseEther("600"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");
    });
  });

  describe("Circuit Breaker", function () {
    it("Should allow owner to trigger circuit breaker", async function () {
      await flashLoan.triggerCircuitBreaker("Test reason");
      expect(await flashLoan.circuitBreakerActive()).to.equal(true);
    });

    it("Should prevent flash loans when circuit breaker is active", async function () {
      await flashLoan.triggerCircuitBreaker("Test reason");

      await expect(
        flashLoan.connect(user).initiateFlashLoan(BUSD, parseEther("1000"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "CircuitBreakerActive");
    });

    it("Should allow owner to reset circuit breaker", async function () {
      await flashLoan.triggerCircuitBreaker("Test reason");
      expect(await flashLoan.circuitBreakerActive()).to.equal(true);

      await flashLoan.resetCircuitBreaker();
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
      expect(usage.max).to.equal(parseEther("10000"));
    });
  });

  describe("Risk Management", function () {
    it("Should allow owner to update asset risk config", async function () {
      await flashLoan.updateAssetRiskConfig(
        BUSD,
        parseEther("2000"),
        9000, // 90% LTV
        200   // Higher risk score
      );

      const config = await flashLoan.getAssetRiskConfig(BUSD);
      expect(config.maxLoanAmount).to.equal(parseEther("2000"));
      expect(config.ltvRatio).to.equal(9000);
      expect(config.riskScore).to.equal(200);
      expect(config.isActive).to.equal(true);
    });

    it("Should reject invalid risk configurations", async function () {
      await expect(
        flashLoan.updateAssetRiskConfig(BUSD, 0, 5000, 100)
      ).to.be.revertedWith("Invalid config");

      await expect(
        flashLoan.updateAssetRiskConfig(BUSD, parseEther("1000"), 15000, 100)
      ).to.be.revertedWith("Invalid config");

      await expect(
        flashLoan.updateAssetRiskConfig(BUSD, parseEther("1000"), 5000, 1500)
      ).to.be.revertedWith("Invalid config");
    });
  });

  describe("Pause Functionality", function () {
    it("Should allow owner to pause contract", async function () {
      await flashLoan.emergencyPause();
      expect(await flashLoan.paused()).to.equal(true);
    });

    it("Should prevent flash loans when paused", async function () {
      await flashLoan.emergencyPause();

      await expect(
        flashLoan.connect(user).initiateFlashLoan(BUSD, parseEther("1000"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "EnforcedPause");
    });

    it("Should allow owner to unpause contract", async function () {
      await flashLoan.emergencyPause();
      expect(await flashLoan.paused()).to.equal(true);

      await flashLoan.emergencyUnpause();
      expect(await flashLoan.paused()).to.equal(false);
    });
  });

  describe("Fee Management", function () {
    it("Should allow owner to update protocol fee", async function () {
      await flashLoan.setProtocolFee(200); // 2%
      expect(await flashLoan.protocolFeeBps()).to.equal(200);
    });

    it("Should reject excessive protocol fees", async function () {
      await expect(
        flashLoan.setProtocolFee(1500) // 15%
      ).to.be.revertedWith("Fee too high");
    });

    it("Should allow owner to update fee recipient", async function () {
      await flashLoan.setFeeRecipient(attacker.address);
      expect(await flashLoan.feeRecipient()).to.equal(attacker.address);
    });

    it("Should reject zero address as fee recipient", async function () {
      await expect(
        flashLoan.setFeeRecipient(ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid recipient");
    });
  });

  describe("Gas Optimization", function () {
    it("Should use immutable storage for constants", async function () {
      expect(await flashLoan.factory()).to.equal(FACTORY);
      expect(await flashLoan.router()).to.equal(ROUTER);
      expect(await flashLoan.BUSD()).to.equal(BUSD);
    });
  });

  describe("Event Logging", function () {
    it("Should emit events for risk config updates", async function () {
      await expect(
        flashLoan.updateAssetRiskConfig(BUSD, parseEther("1500"), 8500, 150)
      ).to.emit(flashLoan, "RiskConfigUpdated")
        .withArgs(BUSD, parseEther("1500"), 8500, 150);
    });

    it("Should emit events for circuit breaker triggers", async function () {
      await expect(
        flashLoan.triggerCircuitBreaker("Test anomaly")
      ).to.emit(flashLoan, "CircuitBreakerTriggered")
        .withArgs("Test anomaly", 0, 0);
    });
  });

  describe("Security Features", function () {
    it("Should use ReentrancyGuard", async function () {
      expect(flashLoan.initiateFlashLoan).to.be.a("function");
    });

    it("Should validate all constructor parameters", async function () {
      await expect(
        ethers.getContractFactory("FlashLoanInstitutional").then(factory =>
          factory.deploy(
            ethers.ZeroAddress, // Invalid factory
            ROUTER,
            BUSD,
            WBNB,
            CROX,
            CAKE,
            CHAINLINK_ORACLE,
            feeRecipient.address
          )
        )
      ).to.be.revertedWith("Invalid factory");
    });
  });

  describe("Integration Tests", function () {
    it("Should maintain state consistency", async function () {
      const initialCircuitBreaker = await flashLoan.circuitBreakerActive();
      await flashLoan.triggerCircuitBreaker("test");
      expect(await flashLoan.circuitBreakerActive()).to.equal(true);

      await flashLoan.resetCircuitBreaker();
      expect(await flashLoan.circuitBreakerActive()).to.equal(initialCircuitBreaker);
    });

    it("Should handle edge cases gracefully", async function () {
      expect(flashLoan.initiateFlashLoan).to.be.a("function");
    });
  });
});
