// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAggregatorV3.sol";

/**
 * @title MockOracle
 * @dev Mock Chainlink oracle for testing purposes
 */
contract MockOracle is IAggregatorV3 {
    int256 private _price = 1e8; // 1 USD with 8 decimals
    uint80 private _roundId = 1;
    uint256 private _updatedAt = block.timestamp;
    uint80 private _answeredInRound = 1;

    function setPrice(int256 price) external {
        _price = price;
        _roundId++;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (
            _roundId,
            _price,
            block.timestamp,
            _updatedAt,
            _answeredInRound
        );
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Oracle";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (
            _roundId,
            _price,
            block.timestamp,
            _updatedAt,
            _answeredInRound
        );
    }
}