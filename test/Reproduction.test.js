const { expect } = require("chai");
const { ethers } = require("hardhat");
const { parseEther } = ethers;

describe("Vulnerability Reproduction", function () {
    let owner, user, feeRecipient;
    let BUSD, WBNB, CROX, CAKE;
    let mockFactory, mockRouter;

    beforeEach(async function () {
        [owner, user, feeRecipient] = await ethers.getSigners();

        // Deploy Mocks
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        BUSD = await MockERC20.deploy("BUSD", "BUSD");
        WBNB = await MockERC20.deploy("WBNB", "WBNB");
        CROX = await MockERC20.deploy("CROX", "CROX");
        CAKE = await MockERC20.deploy("CAKE", "CAKE");

        const MockFactory = await ethers.getContractFactory("MockUniswapV2Factory");
        mockFactory = await MockFactory.deploy();

        const MockRouter = await ethers.getContractFactory("MockUniswapV2Router");
        mockRouter = await MockRouter.deploy(mockFactory.target);

        // Create Pairs
        await mockFactory.createPair(BUSD.target, WBNB.target);
        await mockFactory.createPair(BUSD.target, CROX.target);
        await mockFactory.createPair(CROX.target, CAKE.target);
        await mockFactory.createPair(CAKE.target, BUSD.target);
    });

    describe("CRITICAL-1: FlashLoan.sol DoS", function () {
        it("Should execute arbitrage without reentrancy revert", async function () {
            const FlashLoan = await ethers.getContractFactory("FlashLoan");
            const flashLoan = await FlashLoan.deploy(
                mockFactory.target,
                mockRouter.target,
                BUSD.target,
                WBNB.target,
                CROX.target,
                CAKE.target
            );

            // Mint tokens to pair for swap
            // The MockPair is created in factory, we need to get its address to fund it if needed
            // But MockUniswapV2Pair mints tokens on swap, so maybe not needed for the *loan* part?
            // Wait, FlashLoan calls swap on pair. Pair calls uniswapV2Call.

            // We need to ensure the user can call initiateArbitrage
            // It acts as a "borrower".

            // NOTE: The current implementation of MockUniswapV2Router ensures profitability (1.05 multiplier).
            // So logic-wise it should pass if not for the ReentrancyGuard.

            await expect(
                flashLoan.connect(user).initiateArbitrage(BUSD.target, parseEther("100"), 500)
            ).to.not.be.revertedWith("ReentrancyGuard: reentrant call");
        });
    });

    describe("CRITICAL-2: FlashLoanInstitutional.sol Profit Loss", function () {
        it("Should send profit to the user (initiator), NOT the pair", async function () {
            const FlashLoanInstitutional = await ethers.getContractFactory("FlashLoanInstitutional");
            // Use a mock oracle
            const MockOracle = await ethers.getContractFactory("MockOracle");
            const mockOracle = await MockOracle.deploy();

            const flashLoan = await FlashLoanInstitutional.deploy(
                mockFactory.target,
                mockRouter.target,
                BUSD.target,
                WBNB.target,
                CROX.target,
                CAKE.target,
                mockOracle.target,
                feeRecipient.address
            );

            // Setup: Valid Oracle Price
            await mockOracle.setPrice(parseEther("1")); // $1

            // Execute Arbitrage
            // We expect the USER (initiator) to receive the profit.
            // Currently, the contract sends it to msg.sender (the pair).

            const initialUserBalance = await BUSD.balanceOf(user.address);

            await flashLoan.connect(user).initiateFlashLoan(BUSD.target, parseEther("100"), 500);

            const finalUserBalance = await BUSD.balanceOf(user.address);

            // Profit should be positive. Logic: 100 * 1.05^3 = ~115. Repay ~100.3. Profit ~15.
            expect(finalUserBalance).to.be.gt(initialUserBalance, "User did not receive profit");
        });
    });

    describe("CRITICAL-3: FlashLoanPolygon.sol Owner & Profit", function () {
        it("Should set the correct owner (deployer) instead of fee recipient", async function () {
            const FlashLoanPolygon = await ethers.getContractFactory("FlashLoanPolygon");
            const MockOracle = await ethers.getContractFactory("MockOracle");
            const mockOracle = await MockOracle.deploy();

            // Deploy with owner != feeRecipient
            const flashLoan = await FlashLoanPolygon.deploy(
                mockFactory.target,
                mockRouter.target,
                BUSD.target, // USDC mock
                WBNB.target, // WMATIC mock
                CROX.target, // WETH mock
                CAKE.target, // DAI mock
                mockOracle.target,
                feeRecipient.address
            );

            // The owner should be the deployer (owner signer), NOT feeRecipient
            expect(await flashLoan.owner()).to.equal(owner.address);
        });
    });
});
