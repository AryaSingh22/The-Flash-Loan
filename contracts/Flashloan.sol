// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IERC20.sol";
import "./libraries/UniswapV2Library.sol";
import "./libraries/SafeERC20.sol";
import "hardhat/console.sol";

contract FlashLoan {
    using SafeERC20 for IERC20;

    // Events
    event ArbitrageStarted(address indexed initiator, address indexed token, uint256 amount);
    event ArbitrageCompleted(address indexed initiator, uint256 profit);
    event ProfitTransferred(address indexed to, uint256 profit);
    event TokenOrder(address token0, address token1);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // Ownership
    address public owner;
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // Addresses
    address public immutable factory;
    address public immutable router;
    address public immutable BUSD;
    address public immutable WBNB;
    address public immutable CROX;
    address public immutable CAKE;

    uint256 private constant MAX_INT = type(uint256).max;
    bool private locked;

    // Reentrancy guard
    modifier nonReentrant() {
        require(!locked, "ReentrancyGuard: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    constructor(
        address _factory,
        address _router,
        address _BUSD,
        address _WBNB,
        address _CROX,
        address _CAKE
    ) {
        owner = msg.sender;
        factory = _factory;
        router = _router;
        BUSD = _BUSD;
        WBNB = _WBNB;
        CROX = _CROX;
        CAKE = _CAKE;

        // Approve tokens once, using safe approve pattern
        IERC20(BUSD).approve(router, 0);
        IERC20(BUSD).approve(router, MAX_INT);
        IERC20(CROX).approve(router, 0);
        IERC20(CROX).approve(router, MAX_INT);
        IERC20(CAKE).approve(router, 0);
        IERC20(CAKE).approve(router, MAX_INT);
    }

    // Utility: Check if arbitrage is profitable
    function checkResult(uint _repayAmount, uint _acquiredCoin) pure private returns(bool) {
        return _acquiredCoin > _repayAmount;
    }

    // Utility: Get contract's token balance
    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
    }

    // Utility: Place a trade on the router
    function placeTrade(address _fromToken, address _toToken, uint _amountIn, uint _amountOutMin, uint _deadline) private returns(uint) {
        address pair = IUniswapV2Factory(factory).getPair(_fromToken, _toToken);
        require(pair != address(0), "Pool does not exist");

        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;

        uint256 amountReceived = IUniswapV2Router02(router).swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            path,
            address(this),
            _deadline
        )[1];

        require(amountReceived > 0, "Transaction Abort");
        return amountReceived;
    }

    // Initiate arbitrage with user-specified slippage and dynamic deadline
    function initiateArbitrage(address _busdBorrow, uint _amount, uint _slippageBps) external nonReentrant {
        emit ArbitrageStarted(msg.sender, _busdBorrow, _amount);

        address pair = IUniswapV2Factory(factory).getPair(_busdBorrow, WBNB);
        require(pair != address(0), "Pool does not exist");

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        emit TokenOrder(token0, token1);

        uint amount0Out = _busdBorrow == token0 ? _amount : 0;
        uint amount1Out = _busdBorrow == token1 ? _amount : 0;
        require(amount0Out > 0 || amount1Out > 0, "Token ordering error");

        bytes memory data = abi.encode(_busdBorrow, _amount, msg.sender, _slippageBps);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    // UniswapV2-compatible flash loan callback
    function uniswapV2Call(
        address _sender,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata _data
    ) external nonReentrant {
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(factory).getPair(token0, token1);
        require(msg.sender == pair, "The sender needs to match the pair");
        require(_sender == address(this), "Sender should match the contract");

        (address busdBorrow, uint256 amount, address myAddress, uint slippageBps) = abi.decode(_data, (address, uint256, address, uint));

        uint256 fee = ((amount * 3) / 997) + 1;
        uint256 repayAmount = amount + fee;
        uint256 loanAmount = _amount0 > 0 ? _amount0 : _amount1;
        uint256 deadline = block.timestamp + 300; // 5 minutes from now

        // Calculate minimum amounts out for slippage protection
        address[] memory path1 = new address[](2);
        path1[0] = BUSD;
        path1[1] = CROX;
        uint256[] memory amounts1 = IUniswapV2Router02(router).getAmountsOut(loanAmount, path1);
        uint256 minOut1 = amounts1[1] * (10000 - slippageBps) / 10000;

        address[] memory path2 = new address[](2);
        path2[0] = CROX;
        path2[1] = CAKE;
        uint256[] memory amounts2 = IUniswapV2Router02(router).getAmountsOut(minOut1, path2);
        uint256 minOut2 = amounts2[1] * (10000 - slippageBps) / 10000;

        address[] memory path3 = new address[](2);
        path3[0] = CAKE;
        path3[1] = BUSD;
        uint256[] memory amounts3 = IUniswapV2Router02(router).getAmountsOut(minOut2, path3);
        uint256 minOut3 = amounts3[1] * (10000 - slippageBps) / 10000;

        // Execute trades with slippage protection
        uint256 trade1Coin = placeTrade(BUSD, CROX, loanAmount, minOut1, deadline);
        uint256 trade2Coin = placeTrade(CROX, CAKE, trade1Coin, minOut2, deadline);
        uint256 trade3Coin = placeTrade(CAKE, BUSD, trade2Coin, minOut3, deadline);

        bool profCheck = checkResult(repayAmount, trade3Coin);
        require(profCheck, "Arbitrage not profitable");

        uint256 profit = trade3Coin - repayAmount;
        emit ArbitrageCompleted(myAddress, profit);

        IERC20(BUSD).transfer(myAddress, profit);
        emit ProfitTransferred(myAddress, profit);

        IERC20(busdBorrow).transfer(pair, repayAmount);
    }

    // Emergency withdraw for owner
    function emergencyWithdraw(address _token) external onlyOwner {
        uint256 bal = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(msg.sender, bal);
        emit EmergencyWithdraw(_token, bal);
    }

    // (Optional) Simulate arbitrage path and return estimated profit and slippage
    function simulateArbitrage(address _busdBorrow, uint _amount, uint _slippageBps) external view returns (
        uint256 estimatedProfit,
        uint256 estimatedRepayAmount,
        uint256[3] memory minOuts
    ) {
        address pair = IUniswapV2Factory(factory).getPair(_busdBorrow, WBNB);
        if (pair == address(0)) return (0, 0, [uint256(0), 0, 0]);

        uint256 fee = ((_amount * 3) / 997) + 1;
        uint256 repayAmount = _amount + fee;
        uint256 loanAmount = _amount;
        uint256 deadline = block.timestamp + 300;

        address[] memory path1 = new address[](2);
        path1[0] = BUSD;
        path1[1] = CROX;
        uint256[] memory amounts1 = IUniswapV2Router02(router).getAmountsOut(loanAmount, path1);
        uint256 minOut1 = amounts1[1] * (10000 - _slippageBps) / 10000;

        address[] memory path2 = new address[](2);
        path2[0] = CROX;
        path2[1] = CAKE;
        uint256[] memory amounts2 = IUniswapV2Router02(router).getAmountsOut(minOut1, path2);
        uint256 minOut2 = amounts2[1] * (10000 - _slippageBps) / 10000;

        address[] memory path3 = new address[](2);
        path3[0] = CAKE;
        path3[1] = BUSD;
        uint256[] memory amounts3 = IUniswapV2Router02(router).getAmountsOut(minOut2, path3);
        uint256 minOut3 = amounts3[1] * (10000 - _slippageBps) / 10000;

        uint256 profit = 0;
        if (minOut3 > repayAmount) {
            profit = minOut3 - repayAmount;
        }
        minOuts = [minOut1, minOut2, minOut3];
        return (profit, repayAmount, minOuts);
    }

    // Gas usage note: Multi-hop trades can be gas intensive. It is recommended to simulate the trade off-chain and set appropriate gas limits in the front-end or deployment scripts.
}
