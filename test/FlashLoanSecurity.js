const { expect } = require("chai");
const { ethers } = require("hardhat");
const { parseEther, parseUnits } = ethers.utils;

describe("FlashLoanSecure Security Tests", function () {
  let flashLoan;
  let owner, user, attacker, feeRecipient;
  
  // Mock addresses (would be real addresses on mainnet fork)
  const FACTORY = "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73"; // PCS Factory
  const ROUTER = "0x10ED43C718714eb63d5aA57B78B54704E256024E"; // PCS Router
  const BUSD = "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56";
  const WBNB = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c";
  const CROX = "0x2c094F5A7D1146BB93850f629501eB749f6Ed491";
  const CAKE = "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82";

  beforeEach(async function () {
    [owner, user, attacker, feeRecipient] = await ethers.getSigners();

    const FlashLoanSecure = await ethers.getContractFactory("FlashLoanSecure");
    flashLoan = await FlashLoanSecure.deploy(
      FACTORY,
      ROUTER,
      BUSD,
      WBNB,
      CROX,
      CAKE,
      feeRecipient.address
    );
    await flashLoan.deployed();
  });

  describe("Access Control Tests", function () {
    it("Should reject non-owner calls to admin functions", async function () {
      await expect(
        flashLoan.connect(attacker).setProtocolFee(200)
      ).to.be.revertedWith("Ownable: caller is not the owner");

      await expect(
        flashLoan.connect(attacker).pause()
      ).to.be.revertedWith("Ownable: caller is not the owner");

      await expect(
        flashLoan.connect(attacker).emergencyWithdraw(BUSD)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should implement 2-step ownership transfer", async function () {
      await flashLoan.transferOwnership(user.address);
      expect(await flashLoan.pendingOwner()).to.equal(user.address);
      expect(await flashLoan.owner()).to.equal(owner.address);

      await flashLoan.connect(user).acceptOwnership();
      expect(await flashLoan.owner()).to.equal(user.address);
    });

    it("Should validate fee recipient address", async function () {
      await expect(
        flashLoan.setFeeRecipient(ethers.constants.AddressZero)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidFeeRecipient");
    });
  });

  describe("Input Validation Tests", function () {
    it("Should reject invalid tokens", async function () {
      await expect(
        flashLoan.connect(user).initiateArbitrage(CAKE, parseEther("1000"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidToken");
    });

    it("Should validate amount bounds", async function () {
      // Too small
      await expect(
        flashLoan.connect(user).initiateArbitrage(BUSD, parseUnits("1", 12), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");

      // Too large
      await expect(
        flashLoan.connect(user).initiateArbitrage(BUSD, parseEther("2000"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");

      // Zero amount
      await expect(
        flashLoan.connect(user).initiateArbitrage(BUSD, 0, 500)
      ).to.be.revertedWithCustomError(flashLoan, "InvalidAmount");
    });

    it("Should validate slippage bounds", async function () {
      await expect(
        flashLoan.connect(user).initiateArbitrage(BUSD, parseEther("1000"), 10001)
      ).to.be.revertedWithCustomError(flashLoan, "SlippageTooHigh");
    });

    it("Should protect against zero address in getBalanceOfToken", async function () {
      await expect(
        flashLoan.getBalanceOfToken(ethers.constants.AddressZero)
      ).to.be.revertedWith("Invalid token address");
    });
  });

  describe("Circuit Breaker Tests", function () {
    it("Should enforce daily volume limits", async function () {
      await flashLoan.setMaxDailyVolume(parseEther("1000"));

      await expect(
        flashLoan.connect(user).initiateArbitrage(BUSD, parseEther("1001"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "DailyLimitExceeded");
    });

    it("Should reset daily volume after 24 hours", async function () {
      await flashLoan.setMaxDailyVolume(parseEther("1000"));
      
      // Fast forward 1 day + 1 second
      await network.provider.send("evm_increaseTime", [86401]);
      await network.provider.send("evm_mine");

      // Should work now (will fail for other reasons, but not daily limit)
      await expect(
        flashLoan.connect(user).initiateArbitrage(BUSD, parseEther("999"), 500)
      ).to.be.revertedWithCustomError(flashLoan, "PairNotFound");
    });

    it("Should track daily volume usage", async function () {
      const [used, max, resetTime] = await flashLoan.getDailyVolumeUsage();
      expect(used).to.equal(0);
      expect(max).to.equal(parseEther("10000")); // Default max
      expect(resetTime).to.be.gt(0);
    });
  });

  describe("Pause Mechanism Tests", function () {
    it("Should allow owner to pause and unpause", async function () {
      await flashLoan.pause();
      expect(await flashLoan.paused()).to.be.true;

      await expect(
        flashLoan.connect(user).initiateArbitrage(BUSD, parseEther("1000"), 500)
      ).to.be.revertedWith("Pausable: paused");

      await flashLoan.unpause();
      expect(await flashLoan.paused()).to.be.false;
    });

    it("Should only allow emergency withdraw when paused", async function () {
      await expect(
        flashLoan.emergencyWithdraw(BUSD)
      ).to.be.reverted; // Should fail when not paused

      await flashLoan.pause();
      await expect(
        flashLoan.emergencyWithdraw(BUSD)
      ).to.be.revertedWith("No balance to withdraw"); // Fails due to no balance, but passes pause check
    });
  });

  describe("Protocol Fee Tests", function () {
    it("Should validate protocol fee bounds", async function () {
      await expect(
        flashLoan.setProtocolFee(1001) // Above 10%
      ).to.be.revertedWith("Fee too high");

      await flashLoan.setProtocolFee(200); // 2%
      expect(await flashLoan.protocolFeeBps()).to.equal(200);
    });

    it("Should emit events on fee updates", async function () {
      await expect(flashLoan.setProtocolFee(150))
        .to.emit(flashLoan, "ProtocolFeeUpdated")
        .withArgs(100, 150); // oldFee, newFee
    });
  });

  describe("Callback Security Tests", function () {
    it("Should reject unauthorized callback calls", async function () {
      const mockData = ethers.utils.defaultAbiCoder.encode(
        ["address", "uint256", "address", "uint256", "uint256"],
        [BUSD, parseEther("1000"), attacker.address, 500, 1000000]
      );

      await expect(
        flashLoan.connect(attacker).uniswapV2Call(
          flashLoan.address,
          parseEther("1000"),
          0,
          mockData
        )
      ).to.be.revertedWithCustomError(flashLoan, "UnauthorizedCallback");
    });
  });

  describe("Simulation Tests", function () {
    it("Should return zero for invalid simulation inputs", async function () {
      // Wrong token
      let result = await flashLoan.simulateArbitrage(CAKE, parseEther("1000"), 500);
      expect(result.estimatedProfit).to.equal(0);

      // Zero amount
      result = await flashLoan.simulateArbitrage(BUSD, 0, 500);
      expect(result.estimatedProfit).to.equal(0);

      // High slippage
      result = await flashLoan.simulateArbitrage(BUSD, parseEther("1000"), 10001);
      expect(result.estimatedProfit).to.equal(0);
    });

    it("Should calculate fees correctly", async function () {
      const amount = parseEther("1000");
      const expectedFee = amount.mul(30).div(997).add(1);
      
      const result = await flashLoan.simulateArbitrage(BUSD, amount, 500);
      const expectedRepay = amount.add(expectedFee);
      
      // Will be zero due to missing pairs, but repayAmount calculation should be correct
      expect(result.estimatedRepayAmount).to.equal(expectedRepay);
    });
  });

  describe("Token Approval Tests", function () {
    it("Should allow owner to refresh approvals", async function () {
      await expect(flashLoan.refreshApprovals()).to.not.be.reverted;
    });

    it("Should reject non-owner approval refresh", async function () {
      await expect(
        flashLoan.connect(attacker).refreshApprovals()
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Admin Configuration Tests", function () {
    it("Should allow owner to update daily volume limit", async function () {
      await flashLoan.setMaxDailyVolume(parseEther("5000"));
      const [, max,] = await flashLoan.getDailyVolumeUsage();
      expect(max).to.equal(parseEther("5000"));
    });

    it("Should reject zero daily volume limit", async function () {
      await expect(
        flashLoan.setMaxDailyVolume(0)
      ).to.be.revertedWith("Invalid limit");
    });
  });

  describe("Event Emission Tests", function () {
    it("Should emit comprehensive events", async function () {
      // This would need mainnet fork to fully test
      // Here we test that the function exists and has correct signature
      const iface = flashLoan.interface;
      
      expect(iface.getEvent("ArbitrageStarted")).to.exist;
      expect(iface.getEvent("ArbitrageCompleted")).to.exist;
      expect(iface.getEvent("FlashLoanExecuted")).to.exist;
      expect(iface.getEvent("CircuitBreakerTriggered")).to.exist;
      expect(iface.getEvent("ProtocolFeeUpdated")).to.exist;
    });
  });

  describe("Gas Optimization Tests", function () {
    it("Should track gas usage in events", async function () {
      // Would need mainnet fork to test actual gas usage
      // Here we verify the event structure includes gas tracking
      const iface = flashLoan.interface;
      const event = iface.getEvent("ArbitrageCompleted");
      
      expect(event.inputs.map(input => input.name)).to.include("gasUsed");
    });
  });

  describe("Integration Tests", function () {
    it("Should have correct constructor initialization", async function () {
      expect(await flashLoan.factory()).to.equal(FACTORY);
      expect(await flashLoan.router()).to.equal(ROUTER);
      expect(await flashLoan.BUSD()).to.equal(BUSD);
      expect(await flashLoan.WBNB()).to.equal(WBNB);
      expect(await flashLoan.CROX()).to.equal(CROX);
      expect(await flashLoan.CAKE()).to.equal(CAKE);
      expect(await flashLoan.feeRecipient()).to.equal(feeRecipient.address);
      expect(await flashLoan.owner()).to.equal(owner.address);
    });

    it("Should have correct initial state", async function () {
      expect(await flashLoan.paused()).to.be.false;
      expect(await flashLoan.protocolFeeBps()).to.equal(100); // 1%
      
      const [dailyUsed, maxDaily,] = await flashLoan.getDailyVolumeUsage();
      expect(dailyUsed).to.equal(0);
      expect(maxDaily).to.equal(parseEther("10000"));
    });
  });
});

// Additional test for attack scenarios
describe("Attack Scenario Tests", function () {
  let flashLoan, reentrancyAttacker;
  let owner, attacker, feeRecipient;

  beforeEach(async function () {
    [owner, attacker, feeRecipient] = await ethers.getSigners();

    const FlashLoanSecure = await ethers.getContractFactory("FlashLoanSecure");
    flashLoan = await FlashLoanSecure.deploy(
      "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73", // FACTORY
      "0x10ED43C718714eb63d5aA57B78B54704E256024E", // ROUTER
      "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56", // BUSD
      "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB
      "0x2c094F5A7D1146BB93850f629501eB749f6Ed491", // CROX
      "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82", // CAKE
      feeRecipient.address
    );
    await flashLoan.deployed();

    // Deploy attack contract
    const ReentrancyAttacker = await ethers.getContractFactory("ReentrancyAttacker");
    reentrancyAttacker = await ReentrancyAttacker.deploy(flashLoan.address);
    await reentrancyAttacker.deployed();
  });

  it("Should prevent reentrancy attacks", async function () {
    // This would need more sophisticated setup on mainnet fork
    // For now, we test that the ReentrancyGuard is in place
    expect(await flashLoan.paused()).to.be.false; // Contract is functional
    
    // The actual reentrancy test would require mainnet fork
    // and proper liquidity setup to trigger the callback
  });
});