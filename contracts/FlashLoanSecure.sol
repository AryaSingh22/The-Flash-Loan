// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Callee.sol";
import "./libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "hardhat/console.sol";

/**
 * @title FlashLoanSecure
 * @dev A secure flash loan arbitrage contract for UniswapV2-compatible DEXes with enhanced security
 * @notice Enables arbitrage opportunities across multiple tokens using flash loans with comprehensive protection
 */
contract FlashLoanSecure is IUniswapV2Callee, ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // Flash loan fee constants
    // PCS v2 = 25 / 9975, Uni v2 = 30 / 997
    uint256 private constant FEE_BPS = 30;  // Using Uni v2 fee structure
    uint256 private constant FEE_DENOM = 997;
    
    // Risk management constants
    uint256 private constant MAX_SLIPPAGE_BPS = 10_000;
    uint256 private constant MIN_LOAN_AMOUNT = 1e15; // 0.001 ETH equivalent minimum
    uint256 private constant MAX_LOAN_AMOUNT = 1000e18; // 1000 token maximum
    uint256 private constant DEADLINE_BUFFER = 300; // 5 minutes

    // Protocol addresses - immutable for gas efficiency
    address public immutable factory;
    address public immutable router;
    address public immutable BUSD;
    address public immutable WBNB;
    address public immutable CROX;
    address public immutable CAKE;

    // Circuit breaker state
    uint256 public maxDailyVolume = 10000e18; // 10K BUSD daily limit
    uint256 public dailyVolumeUsed;
    uint256 public lastVolumeResetTime;

    // Fee collection
    address public feeRecipient;
    uint256 public protocolFeeBps = 100; // 1% protocol fee

    // Enhanced events for monitoring
    event ArbitrageStarted(
        address indexed initiator, 
        address indexed token, 
        uint256 amount, 
        address indexed borrowPair,
        uint256 slippageBps,
        uint256 timestamp
    );
    event ArbitrageCompleted(
        address indexed initiator, 
        uint256 profit, 
        uint256 protocolFee,
        uint256 gasUsed
    );
    event ProfitTransferred(address indexed to, uint256 profit);
    event TokenOrder(address token0, address token1);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event FlashLoanExecuted(
        address indexed pair,
        uint256 amount0,
        uint256 amount1,
        uint256 fee
    );
    event CircuitBreakerTriggered(uint256 dailyVolume, uint256 maxVolume);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);

    // Errors for better gas efficiency and debugging
    error InvalidToken();
    error InvalidAmount();
    error SlippageTooHigh();
    error PairNotFound();
    error ArbitrageNotProfitable();
    error DailyLimitExceeded();
    error UnauthorizedCallback();
    error InvalidFeeRecipient();

    constructor(
        address _factory,
        address _router,
        address _BUSD,
        address _WBNB,
        address _CROX,
        address _CAKE,
        address _feeRecipient
    ) Ownable(msg.sender) {
        // Validate all addresses
        require(_factory != address(0), "Invalid factory");
        require(_router != address(0), "Invalid router");
        require(_BUSD != address(0), "Invalid BUSD");
        require(_WBNB != address(0), "Invalid WBNB");
        require(_CROX != address(0), "Invalid CROX");
        require(_CAKE != address(0), "Invalid CAKE");
        require(_feeRecipient != address(0), "Invalid fee recipient");

        factory = _factory;
        router = _router;
        BUSD = _BUSD;
        WBNB = _WBNB;
        CROX = _CROX;
        CAKE = _CAKE;
        feeRecipient = _feeRecipient;
        
        lastVolumeResetTime = block.timestamp;

        // Enhanced token approvals with proper reset pattern
        _resetAndApproveToken(BUSD);
        _resetAndApproveToken(CROX);
        _resetAndApproveToken(CAKE);
    }

    /**
     * @dev Safely reset and approve tokens to prevent approval race conditions
     * @param token Token to approve
     */
    function _resetAndApproveToken(address token) private {
        IERC20(token).forceApprove(router, 0);
        IERC20(token).forceApprove(router, type(uint256).max);
    }

    /**
     * @dev Check and reset daily volume if needed
     */
    function _checkAndResetDailyVolume() private {
        if (block.timestamp >= lastVolumeResetTime + 1 days) {
            dailyVolumeUsed = 0;
            lastVolumeResetTime = block.timestamp;
        }
    }

    /**
     * @dev Enhanced input validation with comprehensive checks
     * @param _amount Amount to validate
     * @param _slippageBps Slippage to validate
     */
    function _validateInputs(uint256 _amount, uint256 _slippageBps) private view {
        if (_amount == 0) revert InvalidAmount();
        if (_amount < MIN_LOAN_AMOUNT) revert InvalidAmount();
        if (_amount > MAX_LOAN_AMOUNT) revert InvalidAmount();
        if (_slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
    }

    /**
     * @dev Validate all required pairs exist before execution
     */
    function _validatePairs() private view {
        if (IUniswapV2Factory(factory).getPair(BUSD, CROX) == address(0)) revert PairNotFound();
        if (IUniswapV2Factory(factory).getPair(CROX, CAKE) == address(0)) revert PairNotFound();
        if (IUniswapV2Factory(factory).getPair(CAKE, BUSD) == address(0)) revert PairNotFound();
    }

    /**
     * @dev Check if arbitrage is profitable with enhanced validation
     * @param _repayAmount The amount that needs to be repaid
     * @param _acquiredCoin The amount acquired from arbitrage
     * @return bool True if profitable
     */
    function checkResult(uint _repayAmount, uint _acquiredCoin) pure private returns(bool) {
        return _acquiredCoin > _repayAmount;
    }

    /**
     * @dev Get contract's token balance with zero-address protection
     * @param _address Token address
     * @return uint256 Token balance
     */
    function getBalanceOfToken(address _address) public view returns (uint256) {
        require(_address != address(0), "Invalid token address");
        return IERC20(_address).balanceOf(address(this));
    }

    /**
     * @dev Execute trade with enhanced error handling and MEV protection
     * @param _fromToken Token to sell
     * @param _toToken Token to buy
     * @param _amountIn Amount of tokens to sell
     * @param _amountOutMin Minimum amount of tokens to receive
     * @param _deadline Transaction deadline
     * @return uint Amount of tokens received
     */
    function placeTrade(
        address _fromToken, 
        address _toToken, 
        uint _amountIn, 
        uint _amountOutMin, 
        uint _deadline
    ) private returns(uint) {
        address pair = IUniswapV2Factory(factory).getPair(_fromToken, _toToken);
        if (pair == address(0)) revert PairNotFound();

        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;

        // Record balances before trade for fee-on-transfer token support
        uint256 balanceBefore = IERC20(_toToken).balanceOf(address(this));

        uint256[] memory amounts = IUniswapV2Router02(router).swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            path,
            address(this),
            _deadline
        );

        // Calculate actual received amount (handles fee-on-transfer tokens)
        uint256 balanceAfter = IERC20(_toToken).balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;
        
        require(actualReceived > 0, "Transaction failed");
        require(actualReceived >= _amountOutMin, "Insufficient output");
        
        return actualReceived;
    }

    /**
     * @dev Enhanced quoting with price impact protection
     * @param amountIn Amount of input tokens
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param slippageBps Slippage in basis points
     * @return minOut Minimum output amount after slippage
     */
    function _quoteMinOut(
        uint256 amountIn, 
        address tokenIn, 
        address tokenOut, 
        uint256 slippageBps
    ) private view returns (uint256 minOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        uint256[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountIn, path);
        minOut = amounts[1] * (10000 - slippageBps) / 10000;

        // Additional price impact protection
        address pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        
        // Calculate price impact and revert if too high (>10%)
        address token0 = IUniswapV2Pair(pair).token0();
        uint256 reserveIn = token0 == tokenIn ? reserve0 : reserve1;
        uint256 priceImpact = (amountIn * 10000) / reserveIn;
        require(priceImpact <= 1000, "Price impact too high"); // Max 10%
    }

    /**
     * @dev Enhanced arbitrage initiation with comprehensive security checks
     * @param _busdBorrow Token to borrow (must be BUSD)
     * @param _amount Amount to borrow
     * @param _slippageBps Slippage tolerance in basis points
     */
    function initiateArbitrage(
        address _busdBorrow, 
        uint _amount, 
        uint _slippageBps
    ) external nonReentrant whenNotPaused {
        uint256 gasStart = gasleft();
        
        // Enhanced validation
        if (_busdBorrow != BUSD) revert InvalidToken();
        _validateInputs(_amount, _slippageBps);
        _validatePairs();
        
        // Circuit breaker check
        _checkAndResetDailyVolume();
        if (dailyVolumeUsed + _amount > maxDailyVolume) {
            emit CircuitBreakerTriggered(dailyVolumeUsed + _amount, maxDailyVolume);
            revert DailyLimitExceeded();
        }
        
        dailyVolumeUsed += _amount;

        address pair = IUniswapV2Factory(factory).getPair(_busdBorrow, WBNB);
        if (pair == address(0)) revert PairNotFound();

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        emit TokenOrder(token0, token1);
        
        emit ArbitrageStarted(
            msg.sender, 
            _busdBorrow, 
            _amount, 
            pair, 
            _slippageBps,
            block.timestamp
        );

        uint amount0Out = _busdBorrow == token0 ? _amount : 0;
        uint amount1Out = _busdBorrow == token1 ? _amount : 0;
        require(amount0Out > 0 || amount1Out > 0, "Token ordering error");

        bytes memory data = abi.encode(_busdBorrow, _amount, msg.sender, _slippageBps, gasStart);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    /**
     * @dev Enhanced flash loan callback with comprehensive security
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
        // Enhanced callback validation
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(factory).getPair(token0, token1);
        
        if (msg.sender != pair) revert UnauthorizedCallback();
        if (_sender != address(this)) revert UnauthorizedCallback();

        (address busdBorrow, uint256 amount, address initiator, uint256 slippageBps, uint256 gasStart) = 
            abi.decode(_data, (address, uint256, address, uint256, uint256));

        // Enhanced fee calculation with documentation
        uint256 fee = ((amount * FEE_BPS) / FEE_DENOM) + 1;
        uint256 repayAmount = amount + fee;
        uint256 loanAmount = _amount0 > 0 ? _amount0 : _amount1;
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;

        emit FlashLoanExecuted(pair, _amount0, _amount1, fee);

        // Execute arbitrage trades with actual output tracking
        uint256 minOut1 = _quoteMinOut(loanAmount, BUSD, CROX, slippageBps);
        uint256 trade1Coin = placeTrade(BUSD, CROX, loanAmount, minOut1, deadline);
        
        uint256 minOut2 = _quoteMinOut(trade1Coin, CROX, CAKE, slippageBps);
        uint256 trade2Coin = placeTrade(CROX, CAKE, trade1Coin, minOut2, deadline);
        
        uint256 minOut3 = _quoteMinOut(trade2Coin, CAKE, BUSD, slippageBps);
        uint256 trade3Coin = placeTrade(CAKE, BUSD, trade2Coin, minOut3, deadline);

        if (!checkResult(repayAmount, trade3Coin)) revert ArbitrageNotProfitable();

        uint256 grossProfit = trade3Coin - repayAmount;
        uint256 protocolFee = (grossProfit * protocolFeeBps) / 10000;
        uint256 netProfit = grossProfit - protocolFee;

        // Calculate gas used for monitoring
        uint256 gasUsed = gasStart - gasleft();
        
        emit ArbitrageCompleted(initiator, netProfit, protocolFee, gasUsed);

        // Transfer profits and fees
        if (netProfit > 0) {
            IERC20(BUSD).safeTransfer(initiator, netProfit);
            emit ProfitTransferred(initiator, netProfit);
        }
        
        if (protocolFee > 0) {
            IERC20(BUSD).safeTransfer(feeRecipient, protocolFee);
        }

        // Repay flash loan
        IERC20(busdBorrow).safeTransfer(pair, repayAmount);
    }

    /**
     * @dev Enhanced emergency withdraw with better access control
     * @param _token Token address to withdraw
     */
    function emergencyWithdraw(address _token) external onlyOwner whenPaused {
        require(_token != address(0), "Invalid token");
        uint256 bal = IERC20(_token).balanceOf(address(this));
        require(bal > 0, "No balance to withdraw");
        
        IERC20(_token).safeTransfer(owner(), bal);
        emit EmergencyWithdraw(_token, bal);
    }

    /**
     * @dev Enhanced simulation with better validation
     * @param _busdBorrow Token to borrow (must be BUSD)
     * @param _amount Amount to borrow
     * @param _slippageBps Slippage tolerance in basis points
     * @return estimatedProfit Estimated profit from arbitrage
     * @return estimatedRepayAmount Amount that needs to be repaid
     * @return minOuts Array of minimum outputs for each trade
     */
    function simulateArbitrage(
        address _busdBorrow, 
        uint _amount, 
        uint _slippageBps
    ) external view returns (
        uint256 estimatedProfit,
        uint256 estimatedRepayAmount,
        uint256[3] memory minOuts
    ) {
        // Enhanced validation
        if (_busdBorrow != BUSD) return (0, 0, [uint256(0), 0, 0]);
        if (_amount == 0 || _amount < MIN_LOAN_AMOUNT || _amount > MAX_LOAN_AMOUNT) {
            return (0, 0, [uint256(0), 0, 0]);
        }
        if (_slippageBps > MAX_SLIPPAGE_BPS) return (0, 0, [uint256(0), 0, 0]);
        
        address pair = IUniswapV2Factory(factory).getPair(_busdBorrow, WBNB);
        if (pair == address(0)) return (0, 0, [uint256(0), 0, 0]);
        
        // Check all required pairs exist
        if (IUniswapV2Factory(factory).getPair(BUSD, CROX) == address(0) ||
            IUniswapV2Factory(factory).getPair(CROX, CAKE) == address(0) ||
            IUniswapV2Factory(factory).getPair(CAKE, BUSD) == address(0)) {
            return (0, 0, [uint256(0), 0, 0]);
        }

        // Enhanced fee calculation
        uint256 fee = ((_amount * FEE_BPS) / FEE_DENOM) + 1;
        uint256 repayAmount = _amount + fee;

        try this._simulateQuoting(_amount, _slippageBps) returns (uint256[3] memory outputs) {
            uint256 grossProfit = 0;
            if (outputs[2] > repayAmount) {
                grossProfit = outputs[2] - repayAmount;
            }
            
            // Account for protocol fee
            uint256 protocolFee = (grossProfit * protocolFeeBps) / 10000;
            uint256 netProfit = grossProfit > protocolFee ? grossProfit - protocolFee : 0;
            
            return (netProfit, repayAmount, outputs);
        } catch {
            return (0, 0, [uint256(0), 0, 0]);
        }
    }

    /**
     * @dev External function for simulation quoting (for try-catch)
     */
    function _simulateQuoting(uint256 _amount, uint256 _slippageBps) external view returns (uint256[3] memory) {
        uint256 minOut1 = _quoteMinOut(_amount, BUSD, CROX, _slippageBps);
        uint256 minOut2 = _quoteMinOut(minOut1, CROX, CAKE, _slippageBps);
        uint256 minOut3 = _quoteMinOut(minOut2, CAKE, BUSD, _slippageBps);
        return [minOut1, minOut2, minOut3];
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Update protocol fee (only owner)
     */
    function setProtocolFee(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps <= 1000, "Fee too high"); // Max 10%
        uint256 oldFee = protocolFeeBps;
        protocolFeeBps = _newFeeBps;
        emit ProtocolFeeUpdated(oldFee, _newFeeBps);
    }

    /**
     * @dev Update fee recipient (only owner)
     */
    function setFeeRecipient(address _newRecipient) external onlyOwner {
        if (_newRecipient == address(0)) revert InvalidFeeRecipient();
        feeRecipient = _newRecipient;
    }

    /**
     * @dev Update daily volume limit (only owner)
     */
    function setMaxDailyVolume(uint256 _newLimit) external onlyOwner {
        require(_newLimit > 0, "Invalid limit");
        maxDailyVolume = _newLimit;
    }

    /**
     * @dev Pause contract (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Refresh token approvals if needed
     */
    function refreshApprovals() external onlyOwner {
        _resetAndApproveToken(BUSD);
        _resetAndApproveToken(CROX);
        _resetAndApproveToken(CAKE);
    }

    /**
     * @dev Get current daily volume usage
     */
    function getDailyVolumeUsage() external view returns (uint256 used, uint256 max, uint256 resetTime) {
        return (dailyVolumeUsed, maxDailyVolume, lastVolumeResetTime);
    }
}
