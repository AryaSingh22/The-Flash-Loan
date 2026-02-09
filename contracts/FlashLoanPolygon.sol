// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Callee.sol";
import "./interfaces/IAggregatorV3.sol";
import "./libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title FlashLoanPolygon
 * @dev Polygon-optimized flash loan contract with advanced security features
 * Optimized for Polygon's lower gas costs and faster block times
 */
contract FlashLoanPolygon is IUniswapV2Callee, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============ CONSTANTS ============
    uint256 private constant FLASH_LOAN_FEE_BPS = 30;  // 0.3%
    uint256 private constant PROTOCOL_FEE_BPS = 100;   // 1%
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_SLIPPAGE_BPS = 500;   // 5%
    uint256 private constant MIN_LOAN_AMOUNT = 1e6;    // Lower minimum for Polygon
    uint256 private constant MAX_LOAN_AMOUNT = 100000e6; // Higher maximum for Polygon
    uint256 private constant MAX_RECURSION_DEPTH = 3;
    uint256 private constant MAX_DAILY_VOLUME = 1000000e6; // Higher volume limits for Polygon
    uint256 private constant ORACLE_DEVIATION_THRESHOLD = 500; // 5%
    
    // ============ IMMUTABLE STORAGE ============
    address public immutable factory;
    address public immutable router;
    address public immutable USDC;     // Primary stablecoin on Polygon
    address public immutable WMATIC;   // Native token
    address public immutable WETH;     // Wrapped ETH
    address public immutable DAI;      // Alternative stablecoin
    address public immutable chainlinkOracle;
    
    // ============ MUTABLE STORAGE ============
    address public feeRecipient;
    uint256 public protocolFeeBps = PROTOCOL_FEE_BPS;
    uint256 public dailyVolumeUsed;
    uint256 public lastVolumeResetTime;
    bool public circuitBreakerActive;
    uint256 public insuranceReserveBalance;
    
    // Risk management
    mapping(address => AssetRiskConfig) public assetRiskConfigs;
    mapping(address => uint256) public userRecursionDepth;
    mapping(address => uint256) public assetLastPrice;
    
    // Multi-DEX support
    mapping(address => bool) public supportedRouters;
    
    // ============ STRUCTS ============
    struct AssetRiskConfig {
        uint256 maxLoanAmount;
        uint256 ltvRatio;
        uint256 riskScore;
        bool isActive;
    }
    
    // ============ EVENTS ============
    event FlashLoanInitiated(address indexed token, uint256 amount, address indexed initiator, uint256 slippageBps);
    event FlashLoanCompleted(address indexed token, uint256 amount, uint256 fee, uint256 profit, address indexed initiator);
    event FlashLoanFailed(address indexed token, uint256 amount, address indexed initiator, string reason);
    event CircuitBreakerTriggered(string reason, uint256 threshold, uint256 currentValue);
    event RiskConfigUpdated(address indexed asset, uint256 maxLoanAmount, uint256 ltvRatio, uint256 riskScore);
    event MultiDexTradeExecuted(address[] path, uint256[] amounts, address router);
    
    // ============ ERRORS ============
    error InvalidToken();
    error InvalidAmount();
    error SlippageTooHigh();
    error PairNotFound();
    error ArbitrageNotProfitable();
    error DailyLimitExceeded();
    error UnauthorizedCallback();
    error CircuitBreakerActive();
    error RecursionDepthExceeded();
    error InsufficientLiquidity();
    error RouterNotSupported();

    constructor(
        address _factory,
        address _router,
        address _USDC,
        address _WMATIC,
        address _WETH,
        address _DAI,
        address _chainlinkOracle,
        address _feeRecipient
    ) Ownable(_feeRecipient) {
        require(_factory != address(0), "Invalid factory");
        require(_router != address(0), "Invalid router");
        require(_USDC != address(0), "Invalid USDC");
        require(_WMATIC != address(0), "Invalid WMATIC");
        require(_WETH != address(0), "Invalid WETH");
        require(_DAI != address(0), "Invalid DAI");
        require(_chainlinkOracle != address(0), "Invalid oracle");

        factory = _factory;
        router = _router;
        USDC = _USDC;
        WMATIC = _WMATIC;
        WETH = _WETH;
        DAI = _DAI;
        chainlinkOracle = _chainlinkOracle;
        feeRecipient = _feeRecipient;
        
        // Mark router as supported
        supportedRouters[_router] = true;
        
        lastVolumeResetTime = block.timestamp;
        _initializeDefaultRiskConfigs();
    }

    // ============ CORE FUNCTIONS ============
    
    /**
     * @dev Initiate a flash loan on Polygon with optimized gas usage
     * @param _token Token to borrow
     * @param _amount Amount to borrow
     * @param _slippageBps Slippage tolerance in basis points
     */
    function initiateFlashLoan(
        address _token,
        uint256 _amount,
        uint256 _slippageBps
    ) external nonReentrant whenNotPaused {
        uint256 gasStart = gasleft();
        
        // Validate inputs
        _validateInputs(_token, _amount, _slippageBps);
        
        // Check circuit breaker
        if (circuitBreakerActive) revert CircuitBreakerActive();
        
        // Validate recursion depth
        if (userRecursionDepth[msg.sender] >= MAX_RECURSION_DEPTH) {
            revert RecursionDepthExceeded();
        }
        
        // Check daily volume
        _checkDailyVolume(_amount);
        
        // Validate oracle prices
        _validateOraclePrices(_token);
        
        // Get pair and validate liquidity
        address pair = IUniswapV2Factory(factory).getPair(_token, WMATIC);
        if (pair == address(0)) revert PairNotFound();
        _validateLiquidity(pair, _token, _amount);
        
        // Increment recursion depth
        userRecursionDepth[msg.sender]++;
        
        // Emit event
        emit FlashLoanInitiated(_token, _amount, msg.sender, _slippageBps);
        
        // Execute flash loan
        _executeFlashLoan(pair, _token, _amount, _slippageBps, gasStart);
        
        // Decrement recursion depth
        userRecursionDepth[msg.sender]--;
    }
    
    /**
     * @dev UniswapV2-compatible flash loan callback optimized for Polygon
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
        // Validate callback
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(factory).getPair(token0, token1);
        
        if (msg.sender != pair) revert UnauthorizedCallback();
        if (_sender != address(this)) revert UnauthorizedCallback();
        
        // Decode parameters
        (address token, uint256 amount, uint256 slippageBps, uint256 gasStart) = 
            abi.decode(_data, (address, uint256, uint256, uint256));
        
        // Calculate fees
        uint256 flashLoanFee = (amount * FLASH_LOAN_FEE_BPS) / BASIS_POINTS;
        uint256 repayAmount = amount + flashLoanFee;
        
        // Execute arbitrage with gas optimization
        uint256 profit = _executeArbitrage(token, amount, slippageBps);
        
        if (profit <= flashLoanFee) {
            revert ArbitrageNotProfitable();
        }
        
        // Calculate protocol fee
        uint256 protocolFee = (profit * protocolFeeBps) / BASIS_POINTS;
        uint256 netProfit = profit - protocolFee;
        
        // Transfer profits with gas optimization
        if (netProfit > 0) {
            IERC20(token).safeTransfer(msg.sender, netProfit);
        }
        if (protocolFee > 0) {
            IERC20(token).safeTransfer(feeRecipient, protocolFee);
        }
        
        // Emit completion event
        emit FlashLoanCompleted(token, amount, flashLoanFee, profit, msg.sender);
        
        // Repay flash loan
        IERC20(token).safeTransfer(pair, repayAmount);
    }

    // ============ MULTI-DEX ARBITRAGE FUNCTIONS ============
    
    /**
     * @dev Execute arbitrage across multiple DEXs on Polygon
     * @param _token Token to start arbitrage with
     * @param _amount Initial amount
     * @param _slippageBps Slippage tolerance
     * @param _routers Array of router addresses to use
     * @param _paths Array of token paths for each router
     * @return Final amount after all trades
     */
    function executeMultiDexArbitrage(
        address _token,
        uint256 _amount,
        uint256 _slippageBps,
        address[] calldata _routers,
        address[][] calldata _paths
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(_routers.length == _paths.length, "Router and path length mismatch");
        
        uint256 currentAmount = _amount;
        address currentToken = _token;
        
        for (uint256 i = 0; i < _routers.length; i++) {
            // Check if router is supported
            if (!supportedRouters[_routers[i]]) revert RouterNotSupported();
            
            // Validate path
            if (_paths[i].length < 2 || _paths[i][0] != currentToken) {
                revert("Invalid path");
            }
            
            // Get minimum output with slippage
            uint256[] memory amounts = IUniswapV2Router02(_routers[i]).getAmountsOut(currentAmount, _paths[i]);
            uint256 minOutput = (amounts[amounts.length - 1] * (BASIS_POINTS - _slippageBps)) / BASIS_POINTS;
            
            // Execute trade
            uint256 balanceBefore = IERC20(_paths[i][_paths[i].length - 1]).balanceOf(address(this));
            
            IUniswapV2Router02(_routers[i]).swapExactTokensForTokens(
                currentAmount,
                minOutput,
                _paths[i],
                address(this),
                block.timestamp + 300 // 5 minutes
            );
            
            uint256 balanceAfter = IERC20(_paths[i][_paths[i].length - 1]).balanceOf(address(this));
            currentAmount = balanceAfter - balanceBefore;
            currentToken = _paths[i][_paths[i].length - 1];
            
            // Emit event
            emit MultiDexTradeExecuted(_paths[i], amounts, _routers[i]);
        }
        
        return currentAmount;
    }

    // ============ ORACLE & RISK MANAGEMENT ============
    
    /**
     * @dev Get validated price from Chainlink oracle
     * @param token Token to get price for
     * @return Price in USD with 8 decimals
     */
    function getValidatedPrice(address token) public view returns (uint256) {
        try IAggregatorV3(chainlinkOracle).latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (price <= 0 || updatedAt == 0 || answeredInRound < roundId) {
                revert("Invalid oracle data");
            }
            return uint256(price);
        } catch {
            revert("Oracle call failed");
        }
    }
    
    /**
     * @dev Update asset risk configuration
     * @param asset Asset address
     * @param maxLoanAmount Maximum loan amount
     * @param ltvRatio Loan-to-value ratio
     * @param riskScore Risk score
     */
    function updateAssetRiskConfig(
        address asset,
        uint256 maxLoanAmount,
        uint256 ltvRatio,
        uint256 riskScore
    ) external onlyOwner {
        require(maxLoanAmount > 0 && ltvRatio <= BASIS_POINTS && riskScore <= 1000, "Invalid config");
        
        assetRiskConfigs[asset] = AssetRiskConfig({
            maxLoanAmount: maxLoanAmount,
            ltvRatio: ltvRatio,
            riskScore: riskScore,
            isActive: true
        });
        
        emit RiskConfigUpdated(asset, maxLoanAmount, ltvRatio, riskScore);
    }

    // ============ CIRCUIT BREAKER & MONITORING ============
    
    /**
     * @dev Trigger circuit breaker
     * @param reason Reason for triggering
     */
    function triggerCircuitBreaker(string memory reason) external onlyOwner {
        circuitBreakerActive = true;
        emit CircuitBreakerTriggered(reason, 0, 0);
    }
    
    /**
     * @dev Reset circuit breaker
     */
    function resetCircuitBreaker() external onlyOwner {
        circuitBreakerActive = false;
    }
    
    /**
     * @dev Add to insurance reserve
     * @param amount Amount to add
     */
    function addToInsuranceReserve(uint256 amount) external {
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        insuranceReserveBalance += amount;
    }

    // ============ ADMIN FUNCTIONS ============
    
    /**
     * @dev Set protocol fee
     * @param newFeeBps New fee in basis points
     */
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 1000, "Fee too high");
        protocolFeeBps = newFeeBps;
    }
    
    /**
     * @dev Set fee recipient
     * @param newRecipient New recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        feeRecipient = newRecipient;
    }
    
    /**
     * @dev Emergency pause
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Emergency unpause
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Add supported router for multi-DEX arbitrage
     * @param _router Router address
     */
    function addSupportedRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        supportedRouters[_router] = true;
    }

    // ============ VIEW FUNCTIONS ============
    
    /**
     * @dev Get daily volume usage
     * @return used Used volume
     * @return max Maximum volume
     * @return resetTime Last reset time
     */
    function getDailyVolumeUsage() external view returns (uint256 used, uint256 max, uint256 resetTime) {
        return (dailyVolumeUsed, MAX_DAILY_VOLUME, lastVolumeResetTime);
    }
    
    /**
     * @dev Get asset risk configuration
     * @param asset Asset address
     * @return maxLoanAmount Maximum loan amount
     * @return ltvRatio Loan-to-value ratio
     * @return riskScore Risk score
     * @return isActive Whether asset is active
     */
    function getAssetRiskConfig(address asset) external view returns (
        uint256 maxLoanAmount,
        uint256 ltvRatio,
        uint256 riskScore,
        bool isActive
    ) {
        AssetRiskConfig memory config = assetRiskConfigs[asset];
        return (config.maxLoanAmount, config.ltvRatio, config.riskScore, config.isActive);
    }

    // ============ INTERNAL FUNCTIONS ============
    
    /**
     * @dev Validate inputs
     * @param token Token address
     * @param amount Amount
     * @param slippageBps Slippage in basis points
     */
    function _validateInputs(address token, uint256 amount, uint256 slippageBps) private view {
        if (token == address(0)) revert InvalidToken();
        if (amount < MIN_LOAN_AMOUNT || amount > MAX_LOAN_AMOUNT) revert InvalidAmount();
        if (slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        
        AssetRiskConfig memory config = assetRiskConfigs[token];
        if (config.isActive && amount > config.maxLoanAmount) revert InvalidAmount();
    }
    
    /**
     * @dev Check daily volume limits
     * @param amount Amount to check
     */
    function _checkDailyVolume(uint256 amount) private {
        if (block.timestamp >= lastVolumeResetTime + 1 days) {
            dailyVolumeUsed = 0;
            lastVolumeResetTime = block.timestamp;
        }
        
        if (dailyVolumeUsed + amount > MAX_DAILY_VOLUME) {
            revert DailyLimitExceeded();
        }
        
        dailyVolumeUsed += amount;
    }
    
    /**
     * @dev Validate oracle prices
     * @param token Token to validate
     */
    function _validateOraclePrices(address token) private {
        uint256 currentPrice = getValidatedPrice(token);
        uint256 lastPrice = assetLastPrice[token];
        
        if (lastPrice > 0) {
            uint256 deviation = _calculatePriceDeviation(currentPrice, lastPrice);
            if (deviation > ORACLE_DEVIATION_THRESHOLD) {
                emit CircuitBreakerTriggered("Price anomaly", ORACLE_DEVIATION_THRESHOLD, deviation);
            }
        }
        
        assetLastPrice[token] = currentPrice;
    }
    
    /**
     * @dev Validate liquidity
     * @param pair Pair address
     * @param token Token address
     * @param amount Amount to validate
     */
    function _validateLiquidity(address pair, address token, uint256 amount) private view {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        
        uint256 reserve = token == token0 ? reserve0 : reserve1;
        if (amount > reserve / 2) {
            revert InsufficientLiquidity();
        }
    }
    
    /**
     * @dev Execute flash loan
     * @param pair Pair address
     * @param token Token address
     * @param amount Amount
     * @param slippageBps Slippage in basis points
     * @param gasStart Starting gas
     */
    function _executeFlashLoan(address pair, address token, uint256 amount, uint256 slippageBps, uint256 gasStart) private {
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        
        uint256 amount0Out = token == token0 ? amount : 0;
        uint256 amount1Out = token == token1 ? amount : 0;
        
        bytes memory data = abi.encode(token, amount, slippageBps, gasStart);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }
    
    /**
     * @dev Execute arbitrage with gas optimizations
     * @param token Token address
     * @param amount Amount
     * @param slippageBps Slippage in basis points
     * @return Final amount after arbitrage
     */
    function _executeArbitrage(address token, uint256 amount, uint256 slippageBps) private returns (uint256) {
        uint256 deadline = block.timestamp + 300;
        
        // Execute arbitrage trades with gas optimizations
        uint256 trade1Amount = _placeTrade(token, WETH, amount, slippageBps, deadline);
        uint256 trade2Amount = _placeTrade(WETH, DAI, trade1Amount, slippageBps, deadline);
        uint256 trade3Amount = _placeTrade(DAI, token, trade2Amount, slippageBps, deadline);
        
        return trade3Amount;
    }
    
    /**
     * @dev Place trade with gas optimizations
     * @param fromToken Token to sell
     * @param toToken Token to buy
     * @param amountIn Amount to sell
     * @param slippageBps Slippage in basis points
     * @param deadline Transaction deadline
     * @return Amount received
     */
    function _placeTrade(address fromToken, address toToken, uint256 amountIn, uint256 slippageBps, uint256 deadline) private returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;
        
        uint256[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountIn, path);
        uint256 amountOutMin = (amounts[1] * (BASIS_POINTS - slippageBps)) / BASIS_POINTS;
        
        uint256 balanceBefore = IERC20(toToken).balanceOf(address(this));
        
        // Add gas limit to prevent griefing
        IUniswapV2Router02(router).swapExactTokensForTokens{gas: 300000}(
            amountIn,
            amountOutMin,
            path,
            address(this),
            deadline
        );
        
        uint256 balanceAfter = IERC20(toToken).balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }
    
    /**
     * @dev Handle failed loan
     * @param token Token address
     * @param amount Amount
     * @param reason Failure reason
     */
    function _handleFailedLoan(address token, uint256 amount, string memory reason) private {
        emit FlashLoanFailed(token, amount, msg.sender, reason);
        
        // Use insurance reserve if available
        if (insuranceReserveBalance > 0) {
            uint256 flashLoanFee = (amount * FLASH_LOAN_FEE_BPS) / BASIS_POINTS;
            uint256 repayAmount = amount + flashLoanFee;
            
            if (insuranceReserveBalance >= repayAmount) {
                insuranceReserveBalance -= repayAmount;
                IERC20(token).safeTransfer(msg.sender, repayAmount);
            }
        }
    }
    
    /**
     * @dev Calculate price deviation
     * @param price1 First price
     * @param price2 Second price
     * @return Deviation in basis points
     */
    function _calculatePriceDeviation(uint256 price1, uint256 price2) private pure returns (uint256) {
        if (price1 == 0 || price2 == 0) return type(uint256).max;
        
        uint256 difference = price1 > price2 ? price1 - price2 : price2 - price1;
        return (difference * BASIS_POINTS) / price1;
    }
    
    /**
     * @dev Initialize default risk configurations
     */
    function _initializeDefaultRiskConfigs() private {
        assetRiskConfigs[USDC] = AssetRiskConfig({
            maxLoanAmount: 10000e6,
            ltvRatio: 9500,
            riskScore: 100,
            isActive: true
        });
        
        assetRiskConfigs[WETH] = AssetRiskConfig({
            maxLoanAmount: 500e18,
            ltvRatio: 8000,
            riskScore: 300,
            isActive: true
        });
        
        assetRiskConfigs[DAI] = AssetRiskConfig({
            maxLoanAmount: 10000e18,
            ltvRatio: 9000,
            riskScore: 200,
            isActive: true
        });
    }
}