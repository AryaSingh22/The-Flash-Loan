# FlashLoan Smart Contract (v1.1)

## Author
Arya Singh

## Overview
This project implements a robust, extensible, and secure flash loan arbitrage contract for UniswapV2-compatible DEXes (e.g., PancakeSwap). The contract is designed for the arbitrage route BUSD → CROX → CAKE → BUSD, but is modular for future expansion.

## ✨ Features
- **UniswapV2Router02 Support:** Uses the latest router interface for maximum compatibility (including fee-on-transfer tokens).
- **Safe Approve Pattern:** Ensures reliable token approvals on deployment and upgrades.
- **Generic Callback:** Uses `uniswapV2Call` for cross-DEX compatibility.
- **Token Ordering Validation:** Emits events and checks for correct token0/token1 logic.
- **Emergency Withdraw:** Owner-only function to recover stuck tokens.
- **Arbitrage Simulation:** `simulateArbitrage()` view function estimates profit and slippage before execution.
- **Reentrancy Guard:** Protects critical functions from reentrancy attacks.
- **Event Logging:** Tracks arbitrage actions, profits, and token orderings.

## 🚀 Usage
1. **Deployment:**
   - Deploy the contract with the addresses for the factory, router, and supported tokens (BUSD, WBNB, CROX, CAKE).
2. **Initiate Arbitrage:**
   - Call `initiateArbitrage(_busdBorrow, _amount, _slippageBps)` to start a flash loan arbitrage.
   - `_slippageBps` is the slippage tolerance in basis points (e.g., 100 = 1%).
3. **Simulate Arbitrage:**
   - Use `simulateArbitrage(_busdBorrow, _amount, _slippageBps)` to estimate profit and slippage before executing a trade.
4. **Emergency Withdraw:**
   - The contract owner can call `emergencyWithdraw(_token)` to recover any stuck tokens.

## 🔒 Security
- Uses OpenZeppelin's SafeERC20 for all token transfers and approvals.
- Implements a reentrancy guard on all critical functions.
- Only the contract owner can perform emergency withdrawals.
- Emits events for all major actions for transparency and off-chain monitoring.

## 🛠️ PRD v1.1 Enhancements
- Switched to IUniswapV2Router02 for future extensibility.
- Fixed safeApprove pattern for deployment reliability.
- Renamed callback to `uniswapV2Call` for modularity.
- Added token ordering validation and event logging.
- Implemented owner-only emergencyWithdraw.
- Added `simulateArbitrage()` view function for pre-trade estimation.
- Documented gas usage considerations (see below).

## ⚡ Gas Usage Considerations
Multi-hop trades (BUSD → CROX → CAKE → BUSD) can be gas intensive. It is recommended to:
- Simulate trades off-chain before execution.
- Set appropriate gas limits in front-end or deployment scripts.
- Monitor for out-of-gas errors, especially in volatile markets.

## 📄 License
MIT

---

For more details, see the contract code and the [Product Requirements Document (PRD)](./contracts/Flashloan.sol#L1).
