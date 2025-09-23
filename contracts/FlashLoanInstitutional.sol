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
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";     
   
/**
 * @title FlashLoanInstitutional
 * @dev Institutional-grade flash loan contract with advanced security features
 */
contract FlashLoanInstitutional is IUniswapV2Callee, ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ============ CONSTANTS ============
    uint256 private constant FLASH_LOAN_FEE_BPS = 30;  // 0.3%
    uint256 private constant PROTOCOL_FEE_BPS = 100;   // 1%
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_SLIPPAGE_BPS = 500;   // 5%
    uint256 private constant MIN_LOAN_AMOUNT = 1e15;
    uint256 private constant MAX_LOAN_AMOUNT = 1000e18;
    uint256 private constant MAX_RECURSION_DEPTH = 3;
    uint256 private constant MAX_DAILY_VOLUME = 10000e18;
    uint256 private constant ORACLE_DEVIATION_THRESHOLD = 500; // 5%
    
    // ============ IMMUTABLE STORAGE ============
    address public immutable factory;
    address public immutable router;
    address public immutable BUSD;
    address public immutable WBNB;
    address public immutable CROX;
    address public immutable CAKE;
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

    constructor(
        address _factory,
        address _router,
        address _BUSD,
        address _WBNB,
        address _CROX,
        address _CAKE,
        address _chainlinkOracle,
        address _feeRecipient
    ) Ownable(msg.sender) {
        require(_factory != address(0), "Invalid factory");
        require(_router != address(0), "Invalid router");
        require(_BUSD != address(0), "Invalid BUSD");
        require(_WBNB != address(0), "Invalid WBNB");
        require(_CROX != address(0), "Invalid CROX");
        require(_CAKE != address(0), "Invalid CAKE");
        require(_chainlinkOracle != address(0), "Invalid oracle");
        require(_feeRecipient != address(0), "Invalid fee recipient");

        factory = _factory;
        router = _router;
        BUSD = _BUSD;
        WBNB = _WBNB;
        CROX = _CROX;
        CAKE = _CAKE;
        chainlinkOracle = _chainlinkOracle;
        feeRecipient = _feeRecipient;
        
        lastVolumeResetTime = block.timestamp;
        _initializeDefaultRiskConfigs();
        // Token approvals will be set up when needed
    }

    // ============ CORE FUNCTIONS ============
    
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
        address pair = IUniswapV2Factory(factory).getPair(_token, WBNB);
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
        
        // Execute arbitrage
        uint256 profit = _executeArbitrage(token, amount, slippageBps);
        
        if (profit <= flashLoanFee) {
            _handleFailedLoan(token, amount, "Insufficient profit");
            return;
        }
        
        // Calculate protocol fee
        uint256 protocolFee = (profit * protocolFeeBps) / BASIS_POINTS;
        uint256 netProfit = profit - protocolFee;
        
        // Transfer profits
        if (netProfit > 0) {
            IERC20(token).safeTransfer(msg.sender, netProfit);
        }
        if (protocolFee > 0) {
            IERC20(token).safeTransfer(feeRecipient, protocolFee);
        }
        
        // Emit completion event
        emit FlashLoanCompleted(token, amount, flashLoanFee, profit, msg.sender);
        
        // Repay flash loan
        IERC20(token).safeTransfer(msg.sender, repayAmount);
    }

    // ============ ORACLE & RISK MANAGEMENT ============
    
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
    
    function triggerCircuitBreaker(string memory reason) external onlyOwner {
        circuitBreakerActive = true;
        emit CircuitBreakerTriggered(reason, 0, 0);
    }
    
    function resetCircuitBreaker() external onlyOwner {
        circuitBreakerActive = false;
    }
    
    function addToInsuranceReserve(uint256 amount) external {
        IERC20(BUSD).safeTransferFrom(msg.sender, address(this), amount);
        insuranceReserveBalance += amount;
    }

    // ============ ADMIN FUNCTIONS ============
    
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 1000, "Fee too high");
        protocolFeeBps = newFeeBps;
    }
    
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        feeRecipient = newRecipient;
    }
    
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    function emergencyUnpause() external onlyOwner {
        _unpause();
    }

    // ============ VIEW FUNCTIONS ============
    
    function getDailyVolumeUsage() external view returns (uint256 used, uint256 max, uint256 resetTime) {
        return (dailyVolumeUsed, MAX_DAILY_VOLUME, lastVolumeResetTime);
    }
    
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
    
    function _validateInputs(address token, uint256 amount, uint256 slippageBps) private view {
        if (token == address(0)) revert InvalidToken();
        if (amount < MIN_LOAN_AMOUNT || amount > MAX_LOAN_AMOUNT) revert InvalidAmount();
        if (slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        
        AssetRiskConfig memory config = assetRiskConfigs[token];
        if (config.isActive && amount > config.maxLoanAmount) revert InvalidAmount();
    }
    
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
    
    function _validateLiquidity(address pair, address token, uint256 amount) private view {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        
        uint256 reserve = token == token0 ? reserve0 : reserve1;
        if (amount > reserve / 2) {
            revert InsufficientLiquidity();
        }
    }
    
    function _executeFlashLoan(address pair, address token, uint256 amount, uint256 slippageBps, uint256 gasStart) private {
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        
        uint256 amount0Out = token == token0 ? amount : 0;
        uint256 amount1Out = token == token1 ? amount : 0;
        
        bytes memory data = abi.encode(token, amount, slippageBps, gasStart);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }
    
    function _executeArbitrage(address token, uint256 amount, uint256 slippageBps) private returns (uint256) {
        uint256 deadline = block.timestamp + 300;
        
        // Execute arbitrage trades
        uint256 trade1Amount = _placeTrade(token, CROX, amount, slippageBps, deadline);
        uint256 trade2Amount = _placeTrade(CROX, CAKE, trade1Amount, slippageBps, deadline);
        uint256 trade3Amount = _placeTrade(CAKE, token, trade2Amount, slippageBps, deadline);
        
        return trade3Amount;
    }
    
    function _placeTrade(address fromToken, address toToken, uint256 amountIn, uint256 slippageBps, uint256 deadline) private returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;
        
        uint256[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountIn, path);
        uint256 amountOutMin = amounts[1] * (BASIS_POINTS - slippageBps) / BASIS_POINTS;
        
        uint256 balanceBefore = IERC20(toToken).balanceOf(address(this));
        
        IUniswapV2Router02(router).swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            deadline
        );
        
        uint256 balanceAfter = IERC20(toToken).balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }
    
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
    
    function _calculatePriceDeviation(uint256 price1, uint256 price2) private pure returns (uint256) {
        if (price1 == 0 || price2 == 0) return type(uint256).max;
        
        uint256 difference = price1 > price2 ? price1 - price2 : price2 - price1;
        return (difference * BASIS_POINTS) / price1;
    }
    
    function _initializeDefaultRiskConfigs() private {
        assetRiskConfigs[BUSD] = AssetRiskConfig({
            maxLoanAmount: 1000e18,
            ltvRatio: 9500,
            riskScore: 100,
            isActive: true
        });
        
        assetRiskConfigs[CROX] = AssetRiskConfig({
            maxLoanAmount: 500e18,
            ltvRatio: 8000,
            riskScore: 300,
            isActive: true
        });
        
        assetRiskConfigs[CAKE] = AssetRiskConfig({
            maxLoanAmount: 500e18,
            ltvRatio: 8000,
            riskScore: 300,
            isActive: true
        });
    }
    

}
