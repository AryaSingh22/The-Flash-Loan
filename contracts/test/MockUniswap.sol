// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IUniswapV2Pair.sol";
import "../MockERC20.sol";

contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        reserve0 = 100000e18;
        reserve1 = 100000e18;
    }

    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external {
        if (amount0Out > 0) MockERC20(token0).mint(to, amount0Out);
        if (amount1Out > 0) MockERC20(token1).mint(to, amount1Out);

        if (data.length > 0) {
             // Mock callback
             (bool success, bytes memory returnData) = to.call(abi.encodeWithSignature("uniswapV2Call(address,uint256,uint256,bytes)", msg.sender, amount0Out, amount1Out, data));
             if (!success) {
                 // Forward the revert reason if possible
                 if (returnData.length > 0) {
                     assembly {
                         let returndata_size := mload(returnData)
                         revert(add(32, returnData), returndata_size)
                     }
                 } else {
                     revert("Callback failed");
                 }
             }
        }
    }
}

contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        MockUniswapV2Pair newPair = new MockUniswapV2Pair(tokenA, tokenB);
        pair = address(newPair);
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract MockUniswapV2Router {
    address public factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function getAmountsOut(uint amountIn, address[] calldata path) external pure returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        uint currentAmount = amountIn;
        for (uint i = 0; i < path.length; i++) {
            amounts[i] = currentAmount;
            // 5% profit per hop to ensure overall profitability
            // 3 hops: 1.05 * 1.05 * 1.05 = 1.15 > 1.003 (fee)
            if (i > 0) {
                currentAmount = currentAmount * 105 / 100;
                amounts[i] = currentAmount;
            }
        }
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        uint currentAmount = amountIn;
        for (uint i = 0; i < path.length; i++) {
            amounts[i] = currentAmount;
            if (i > 0) {
                currentAmount = currentAmount * 105 / 100;
                amounts[i] = currentAmount;
            }
        }

        // Mint the final output to the recipient
        address tokenOut = path[path.length - 1];
        MockERC20(tokenOut).mint(to, amounts[amounts.length - 1]);
    }
}
