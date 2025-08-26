// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious contract for recursion testing
contract RecursionAttacker {
    uint256 public recursionDepth = 0;
    
    function attackRecursion(address target, uint256 amount) external {
        if (recursionDepth < 100) {
            recursionDepth++;
            target.call(
                abi.encodeWithSignature(
                    "initiateArbitrage(address,uint256,uint256)",
                    address(0x9ABC), // BUSD
                    amount,
                    500
                )
            );
        }
    }
}

/// @notice Malicious token with expensive operations
contract GasGriefingToken is ERC20 {
    mapping(address => uint256) public expensiveStorage;
    
    constructor() ERC20("GasGriefing", "GAS") {
        _mint(msg.sender, 1000000e18);
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Expensive operation on every transfer
        for (uint i = 0; i < 1000; i++) {
            expensiveStorage[to] = i;
        }
        return super.transfer(to, amount);
    }
}

/// @notice Token with fake return values
contract FakeReturnToken is ERC20 {
    bool public shouldReturnFalse = false;
    
    constructor() ERC20("FakeReturn", "FAKE") {
        _mint(msg.sender, 1000000e18);
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        return shouldReturnFalse ? false : super.transfer(to, amount);
    }
    
    function setReturnValue(bool value) external {
        shouldReturnFalse = value;
    }
}

/// @notice Cross-chain state simulation
contract CrossChainStateTest {
    mapping(uint256 => uint256) public chainStates;
    
    function simulateStateInconsistency(uint256 chainId, uint256 state) external {
        chainStates[chainId] = state;
    }
    
    function testCrossChainValidation() external view returns (bool) {
        return chainStates[1] != chainStates[137]; // Ethereum vs Polygon
    }
}
