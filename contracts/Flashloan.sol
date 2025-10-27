// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; 
 
import "./interfaces/IUniswapV2Factory.sol";   
import "./interfaces/IUniswapV2Pair.sol"; 
import "./interfaces/IUniswapV2Router02.sol";   
import "./interfaces/IUniswapV2Callee.sol";         
import "./libraries/UniswapV2Library.sol";  
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";         

/** 
 * @title FlashLoan
 * @dev A secure flash loan arbitrage contract for UniswapV2-compatible DEXes
 * @notice Enables arbitrage opportunities across multiple tokens using flash loans
 */
contract FlashLoan is IUniswapV2Callee {
    using SafeERC20 for IERC20;

    // Flash loan fee constants
    // PCS v2 = 25 / 9975, Uni v2 = 30 / 997
    uint256 private constant FEE_BPS = 30;  // Using Uni v2 fee structure
    uint256 private constant FEE_DENOM = 997;
    
    // Maximum slippage allowed (100%)
    uint256 private constant MAX_SLIPPAGE_BPS = 10_000;

    // Events
    event ArbitrageStarted(address indexed initiator, address indexed token, uint256 amount, address indexed borrowPair);
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

    /**
     * @dev Check if arbitrage is profitable
     * @param _repayAmount The amount that needs to be repaid
     * @param _acquiredCoin The amount acquired from arbitrage
     * @return bool True if profitable
     */
    function checkResult(uint _repayAmount, uint _acquiredCoin) pure private returns(bool) {
        return _acquiredCoin > _repayAmount;
    }

    /**
     * @dev Get contract's token balance
     * @param _address Token address
     * @return uint256 Token balance
     */
    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
    }

    /**
     * @dev Place a trade on the router
     * @param _fromToken Token to sell
     * @param _toToken Token to buy
     * @param _amountIn Amount of tokens to sell
     * @param _amountOutMin Minimum amount of tokens to receive
     * @param _deadline Transaction deadline
     * @return uint Amount of tokens received
     */
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

    /**
     * @dev Helper function to quote minimum output with slippage protection
     * @param amountIn Amount of input tokens
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param slippageBps Slippage in basis points
     * @return minOut Minimum output amount after slippage
     */
    function _quoteMinOut(uint256 amountIn, address tokenIn, address tokenOut, uint256 slippageBps) private view returns (uint256 minOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        uint256[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountIn, path);
        minOut = amounts[1] * (10000 - slippageBps) / 10000;
    }

    /**
     * @dev Initiate arbitrage with user-specified slippage and dynamic deadline
     * @param _busdBorrow Token to borrow (must be BUSD)
     * @param _amount Amount to borrow
     * @param _slippageBps Slippage tolerance in basis points
     */
    function initiateArbitrage(address _busdBorrow, uint _amount, uint _slippageBps) external nonReentrant {
        // Validation checks
        require(_busdBorrow == BUSD, "Can only borrow BUSD");
        require(_amount > 0, "Amount must be greater than 0");
        require(_slippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        
        // Harden swap path checks - ensure all required pairs exist
        address busdCroxPair = IUniswapV2Factory(factory).getPair(BUSD, CROX);
        address croxCakePair = IUniswapV2Factory(factory).getPair(CROX, CAKE);
        address cakeBusdPair = IUniswapV2Factory(factory).getPair(CAKE, BUSD);
        
        require(busdCroxPair != address(0), "BUSD-CROX pair does not exist");
        require(croxCakePair != address(0), "CROX-CAKE pair does not exist");
        require(cakeBusdPair != address(0), "CAKE-BUSD pair does not exist");

        address pair = IUniswapV2Factory(factory).getPair(_busdBorrow, WBNB);
        require(pair != address(0), "Pool does not exist");

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        emit TokenOrder(token0, token1);
        emit ArbitrageStarted(msg.sender, _busdBorrow, _amount, pair);

        uint amount0Out = _busdBorrow == token0 ? _amount : 0;
        uint amount1Out = _busdBorrow == token1 ? _amount : 0;
        require(amount0Out > 0 || amount1Out > 0, "Token ordering error");

        bytes memory data = abi.encode(_busdBorrow, _amount, msg.sender, _slippageBps);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    /**
     * @dev UniswapV2-compatible flash loan callback
     * @param _sender Address that initiated the swap
     * @param _amount0 Amount of token0 borrowed
     * @param _amount1 Amount of token1 borrowed
     * @param _data Encoded data containing arbitrage parameters
     */
    function uniswapV2Call(
        address _sender,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata _data
    ) external override nonReentrant {
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(factory).getPair(token0, token1);
        require(msg.sender == pair, "The sender needs to match the pair");
        require(_sender == address(this), "Sender should match the contract");

        (address busdBorrow, uint256 amount, address myAddress, uint slippageBps) = abi.decode(_data, (address, uint256, address, uint));

        // Calculate fee using parameterized constants
        uint256 fee = ((amount * FEE_BPS) / FEE_DENOM) + 1;
        uint256 repayAmount = amount + fee;
        uint256 loanAmount = _amount0 > 0 ? _amount0 : _amount1;
        uint256 deadline = block.timestamp + 300; // 5 minutes from now

        // Use safer quoting - each hop quotes based on actual trade input, not minOut chaining
        uint256 minOut1 = _quoteMinOut(loanAmount, BUSD, CROX, slippageBps);
        
        // Execute first trade and use actual output for next quote
        uint256 trade1Coin = placeTrade(BUSD, CROX, loanAmount, minOut1, deadline);
        
        // Quote second trade based on actual output from first trade
        uint256 minOut2 = _quoteMinOut(trade1Coin, CROX, CAKE, slippageBps);
        uint256 trade2Coin = placeTrade(CROX, CAKE, trade1Coin, minOut2, deadline);
        
        // Quote third trade based on actual output from second trade
        uint256 minOut3 = _quoteMinOut(trade2Coin, CAKE, BUSD, slippageBps);
        uint256 trade3Coin = placeTrade(CAKE, BUSD, trade2Coin, minOut3, deadline);

        bool profCheck = checkResult(repayAmount, trade3Coin);
        require(profCheck, "Arbitrage not profitable");

        uint256 profit = trade3Coin - repayAmount;
        emit ArbitrageCompleted(myAddress, profit);

        // Use SafeERC20 for all transfers
        IERC20(BUSD).safeTransfer(myAddress, profit);
        emit ProfitTransferred(myAddress, profit);

        IERC20(busdBorrow).safeTransfer(pair, repayAmount);
    }

    /**
     * @dev Emergency withdraw for owner
     * @param _token Token address to withdraw
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        uint256 bal = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, bal);
        emit EmergencyWithdraw(_token, bal);
    }

    /**
     * @dev Simulate arbitrage path and return estimated profit and slippage
     * @param _busdBorrow Token to borrow (must be BUSD)
     * @param _amount Amount to borrow
     * @param _slippageBps Slippage tolerance in basis points
     * @return estimatedProfit Estimated profit from arbitrage
     * @return estimatedRepayAmount Amount that needs to be repaid
     * @return minOuts Array of minimum outputs for each trade
     */
    function simulateArbitrage(address _busdBorrow, uint _amount, uint _slippageBps) external view returns (
        uint256 estimatedProfit,
        uint256 estimatedRepayAmount,
        uint256[3] memory minOuts
    ) {
        // Validation checks
        if (_busdBorrow != BUSD || _amount == 0 || _slippageBps > MAX_SLIPPAGE_BPS) {
            return (0, 0, [uint256(0), 0, 0]);
        }
        
        address pair = IUniswapV2Factory(factory).getPair(_busdBorrow, WBNB);
        if (pair == address(0)) return (0, 0, [uint256(0), 0, 0]);
        
        // Check all required pairs exist
        if (IUniswapV2Factory(factory).getPair(BUSD, CROX) == address(0) ||
            IUniswapV2Factory(factory).getPair(CROX, CAKE) == address(0) ||
            IUniswapV2Factory(factory).getPair(CAKE, BUSD) == address(0)) {
            return (0, 0, [uint256(0), 0, 0]);
        }

        // Calculate fee using parameterized constants
        uint256 fee = ((_amount * FEE_BPS) / FEE_DENOM) + 1;
        uint256 repayAmount = _amount + fee;
        uint256 loanAmount = _amount;

        // Use safer quoting approach - simulate actual trade flow
        uint256 minOut1 = _quoteMinOut(loanAmount, BUSD, CROX, _slippageBps);
        
        // For simulation, use the minimum output as input for next trade
        // This provides a conservative estimate
        uint256 minOut2 = _quoteMinOut(minOut1, CROX, CAKE, _slippageBps);
        uint256 minOut3 = _quoteMinOut(minOut2, CAKE, BUSD, _slippageBps);

        uint256 profit = 0;
        if (minOut3 > repayAmount) {
            profit = minOut3 - repayAmount;
        }
        minOuts = [minOut1, minOut2, minOut3];
        return (profit, repayAmount, minOuts);
    }

    // Gas usage note: Multi-hop trades can be gas intensive. It is recommended to simulate the trade off-chain and set appropriate gas limits in the front-end or deployment scripts.
}
