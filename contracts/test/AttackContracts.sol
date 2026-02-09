// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../FlashLoanSecure.sol";

/**
 * @title AttackContract
 * @dev Mock attack contract to test security vulnerabilities
 */
contract ReentrancyAttacker {
    FlashLoanSecure public target;
    uint256 public attackCount;
    
    constructor(address _target) {
        target = FlashLoanSecure(_target);
    }
    
    function attack() external {
        attackCount++;
        // Attempt reentrancy during callback
        if (attackCount < 3) {
            target.initiateArbitrage(
                0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56, // BUSD
                1000e18,
                500
            );
        }
    }
    
    // Mock uniswapV2Call to trigger reentrancy
    function uniswapV2Call(
        address,
        uint256,
        uint256,
        bytes calldata
    ) external {
        this.attack();
    }
}

/**
 * @title FlashLoanCallbackAttacker
 * @dev Attack contract attempting to manipulate flash loan callback
 */
contract FlashLoanCallbackAttacker {
    FlashLoanSecure public target;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    
    constructor(address _target) {
        target = FlashLoanSecure(_target);
    }

    function token0() external pure returns (address) {
        return BUSD;
    }

    function token1() external pure returns (address) {
        return WBNB;
    }
    
    function attackCallback() external {
        // Attempt to call callback directly
        target.uniswapV2Call(
            address(this),
            1000e18,
            0,
            abi.encode(
                BUSD,
                1000e18,
                address(this),
                500,
                gasleft()
            )
        );
    }
}

/**
 * @title PriceManipulationAttacker
 * @dev Contract to test price manipulation resistance
 */
contract PriceManipulationAttacker {
    FlashLoanSecure public target;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    
    constructor(address _target) {
        target = FlashLoanSecure(_target);
    }
    
    function attemptManipulation() external {
        // Attempt large trade to manipulate price
        target.initiateArbitrage(BUSD, 999e18, 500);
    }
}

/**
 * @title FrontRunningBot
 * @dev Simulate MEV bot trying to front-run arbitrage
 */
contract FrontRunningBot {
    FlashLoanSecure public target;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    
    constructor(address _target) {
        target = FlashLoanSecure(_target);
    }
    
    function frontRun(uint256 amount, uint256 slippage) external {
        // Attempt to front-run with higher gas price
        target.initiateArbitrage(BUSD, amount, slippage);
    }
}