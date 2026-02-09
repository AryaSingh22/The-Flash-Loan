// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IAggregatorV3.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PriceOraclePolygon
 * @dev Price oracle for Polygon DEXs with TWAP and Chainlink integration
 */
contract PriceOraclePolygon {
    using SafeERC20 for IERC20;

    // ============ STRUCTS ============
    struct DexInfo {
        address factory;
        address router;
        string name;
        bool isActive;
    }
    
    struct PriceInfo {
        uint256 price;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 twapPrice;
    }
    
    struct TwapObservation {
        uint256 priceCumulative;
        uint256 timestamp;
    }

    // ============ CONSTANTS ============
    uint256 private constant TWAP_PERIOD = 10 minutes;
    uint256 private constant MAX_OBSERVATIONS = 100;
    uint256 private constant BASIS_POINTS = 10000;

    // ============ IMMUTABLE STORAGE ============
    address public owner;
    mapping(address => mapping(address => address)) public pairAddresses; // tokenA => tokenB => pair
    
    // ============ MUTABLE STORAGE ============
    mapping(string => DexInfo) public dexInfos;
    mapping(address => mapping(address => TwapObservation[])) public twapObservations; // tokenA => tokenB => observations
    mapping(address => address) public chainlinkOracles; // token => oracle
    
    // ============ EVENTS ============
    event DexAdded(string name, address factory, address router);
    event DexRemoved(string name);
    event PriceUpdated(address tokenA, address tokenB, uint256 price, uint256 twapPrice);
    event OracleAdded(address token, address oracle);
    
    // ============ MODIFIERS ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        
        // Initialize with common Polygon DEXs
        _addDex("QuickSwap", 0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32, 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
        _addDex("SushiSwap", 0xc35DADB65012eC5796536bD9864eD8773aBc74C4, 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);
    }

    // ============ PUBLIC FUNCTIONS ============
    
    /**
     * @dev Get price between two tokens from a specific DEX
     * @param dexName Name of the DEX
     * @param tokenA First token
     * @param tokenB Second token
     * @param amountIn Amount of tokenA
     * @return amountOut Amount of tokenB
     */
    function getPrice(
        string memory dexName,
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) public view returns (uint256 amountOut) {
        DexInfo memory dex = dexInfos[dexName];
        require(dex.isActive, "DEX not active");
        
        address pair = IUniswapV2Factory(dex.factory).getPair(tokenA, tokenB);
        require(pair != address(0), "Pair does not exist");
        
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountIn;
        
        // Simplified price calculation - in practice, use getAmountsOut
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        
        if (tokenA < tokenB) {
            amounts[1] = _getAmount(amountIn, reserve0, reserve1);
        } else {
            amounts[1] = _getAmount(amountIn, reserve1, reserve0);
        }
        
        return amounts[1];
    }
    
    /**
     * @dev Get TWAP price between two tokens
     * @param tokenA First token
     * @param tokenB Second token
     * @return twapPrice TWAP price
     */
    function getTwapPrice(
        address tokenA,
        address tokenB
    ) public view returns (uint256 twapPrice) {
        TwapObservation[] memory observations = twapObservations[tokenA][tokenB];
        if (observations.length < 2) {
            return 0;
        }
        
        uint256 oldestIndex = observations.length - 1;
        TwapObservation memory newest = observations[0];
        TwapObservation memory oldest = observations[oldestIndex];
        
        uint256 timeElapsed = newest.timestamp - oldest.timestamp;
        if (timeElapsed < TWAP_PERIOD / 2) {
            return 0;
        }
        
        uint256 priceCumulativeDiff = newest.priceCumulative - oldest.priceCumulative;
        return priceCumulativeDiff / timeElapsed;
    }
    
    /**
     * @dev Get Chainlink oracle price
     * @param token Token address
     * @return price Oracle price
     */
    function getChainlinkPrice(address token) public view returns (uint256 price) {
        address oracle = chainlinkOracles[token];
        require(oracle != address(0), "Oracle not set");
        
        try IAggregatorV3(oracle).latestRoundData() returns (
            uint80 roundId,
            int256 priceInt,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (priceInt <= 0 || updatedAt == 0 || answeredInRound < roundId) {
                revert("Invalid oracle data");
            }
            return uint256(priceInt);
        } catch {
            revert("Oracle call failed");
        }
    }
    
    /**
     * @dev Get arbitrage opportunity between DEXs
     * @param tokenA First token
     * @param tokenB Second token
     * @param amountIn Amount to trade
     * @return dexWithBestPrice Name of DEX with best price
     * @return bestPrice Best price available
     * @return priceDifference Price difference
     */
    function getArbitrageOpportunity(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) public view returns (
        string memory dexWithBestPrice,
        uint256 bestPrice,
        uint256 priceDifference
    ) {
        uint256 bestDexPrice = 0;
        string memory bestDexName = "";
        
        // Check all active DEXs
        for (uint256 i = 0; i < 10; i++) {
            // This is a simplified approach - in practice, you'd iterate through all DEXs
            string[10] memory dexNames = ["QuickSwap", "SushiSwap", "ApeSwap", "DFYN", "Cometh", "JetSwap", "Polydex", "WaultSwap", "Polycat", "HyperJump"];
            
            if (i >= dexNames.length) break;
            
            string memory dexName = dexNames[i];
            DexInfo memory dex = dexInfos[dexName];
            
            if (dex.isActive) {
                try this.getPrice(dexName, tokenA, tokenB, amountIn) returns (uint256 price) {
                    if (price > bestDexPrice) {
                        bestDexPrice = price;
                        bestDexName = dexName;
                    }
                } catch {
                    // Skip DEX if price calculation fails
                }
            }
        }
        
        return (bestDexName, bestDexPrice, 0); // Simplified - would calculate price difference in full implementation
    }

    // ============ OWNER FUNCTIONS ============
    
    /**
     * @dev Add a new DEX
     * @param name DEX name
     * @param factory Factory address
     * @param router Router address
     */
    function addDex(
        string memory name,
        address factory,
        address router
    ) external onlyOwner {
        _addDex(name, factory, router);
    }
    
    /**
     * @dev Remove a DEX
     * @param name DEX name
     */
    function removeDex(string memory name) external onlyOwner {
        delete dexInfos[name];
        emit DexRemoved(name);
    }
    
    /**
     * @dev Add Chainlink oracle for a token
     * @param token Token address
     * @param oracle Oracle address
     */
    function addChainlinkOracle(address token, address oracle) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(oracle != address(0), "Invalid oracle");
        chainlinkOracles[token] = oracle;
        emit OracleAdded(token, oracle);
    }
    
    /**
     * @dev Update pair address
     * @param tokenA First token
     * @param tokenB Second token
     * @param pair Pair address
     */
    function updatePairAddress(
        address tokenA,
        address tokenB,
        address pair
    ) external onlyOwner {
        require(tokenA != address(0), "Invalid tokenA");
        require(tokenB != address(0), "Invalid tokenB");
        require(pair != address(0), "Invalid pair");
        pairAddresses[tokenA][tokenB] = pair;
        pairAddresses[tokenB][tokenA] = pair;
    }

    // ============ INTERNAL FUNCTIONS ============
    
    /**
     * @dev Add a new DEX internally
     * @param name DEX name
     * @param factory Factory address
     * @param router Router address
     */
    function _addDex(
        string memory name,
        address factory,
        address router
    ) internal {
        require(factory != address(0), "Invalid factory");
        require(router != address(0), "Invalid router");
        
        dexInfos[name] = DexInfo({
            factory: factory,
            router: router,
            name: name,
            isActive: true
        });
        
        emit DexAdded(name, factory, router);
    }
    
    /**
     * @dev Get amount out given reserves
     * @param amountIn Amount in
     * @param reserveIn Reserve in
     * @param reserveOut Reserve out
     * @return amountOut Amount out
     */
    function _getAmount(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
    /**
     * @dev Update TWAP observations
     * @param tokenA First token
     * @param tokenB Second token
     * @param priceCumulative Price cumulative
     */
    function _updateTwapObservations(
        address tokenA,
        address tokenB,
        uint256 priceCumulative
    ) internal {
        TwapObservation[] storage observations = twapObservations[tokenA][tokenB];
        
        // Add new observation
        observations.push(TwapObservation({
            priceCumulative: priceCumulative,
            timestamp: block.timestamp
        }));
        
        // Keep only MAX_OBSERVATIONS
        if (observations.length > MAX_OBSERVATIONS) {
            for (uint256 i = 0; i < observations.length - 1; i++) {
                observations[i] = observations[i + 1];
            }
            observations.pop();
        }
    }
}