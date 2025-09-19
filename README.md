# 🪝 TickForge: Uniswap V4 Trailing Stop Hook

## Overview
**TickForge** is a Uniswap V4 hook that introduces **trailing stop orders** for DeFi.  
It allows traders to set dynamic stop-losses that **follow favorable price movements** and automatically trigger swaps if the market reverses by a user-defined percentage (e.g., 5%).  

Stops are represented as **ERC1155 tokens**, giving users transferable ownership and a claim mechanism. Built on the `afterSwap` hook, TickForge executes fully **on-chain risk management**, without the need for bots or constant monitoring.

> Inspired by traditional finance trailing stops, TickForge bridges familiar risk management tools into DeFi while leveraging the flexibility of Uniswap V4.

---
🚀 Impact

TickForge enables DeFi traders and LPs to automate risk management directly on-chain.
By introducing trailing stops into Uniswap V4, the project:

Reduces the need for constant monitoring.

Protects users from sharp reversals.

Improves capital efficiency by letting profits run while capping downside.

Lays groundwork for advanced automated strategies (vaults, managed LP positions, solver integrations).
---

## ✨ Features
- **📈 Trailing Stops:** Define thresholds (in basis points) that track favorable price movements and protect profits.
- **🔗 On-Chain Execution:** Uses Uniswap V4 `afterSwap` hook and `PoolManager.unlock` for atomic swaps.
- **🎟 ERC1155 Representation:** Each stop is minted as an ERC1155 token for easy ownership transfer and tracking.
- **🛑 Cancel & Claim:** Cancel untriggered stops to refund input tokens, or claim proceeds after execution.
- **🔒 Secure by Design:** Input validation, `onlyOwner` restriction for pools, and reentrancy protections.

---

## ⚙️ How It Works
1. **Create Stop:**  
   Call `createStop` with:
   - `PoolKey` (target pool)  
   - `thresholdBps` (basis points, e.g., 500 = 5%)  
   - `zeroForOne` (swap direction)  
   - `amountIn` (input tokens)  
   - `minOutput` (slippage guard)

   👉 Mints an ERC1155 token representing the stop.

2. **Monitor via `afterSwap`:**  
   - Tracks the highest tick (for `zeroForOne`) or lowest tick (for `oneForZero`) as the trailing watermark.  
   - If the price reverses beyond the threshold, the stop is marked for execution.

3. **Execute:**  
   When triggered, `_performSwap` is called:  
   - Executes a swap via `PoolManager.unlock`.  
   - Balances are settled via `BalanceDelta`.  
   - Emits a `StopExecuted` event.

4. **Cancel/Claim:**  
   - `cancelStop`: Refunds the original input tokens.  
   - `claimProceeds`: Releases output tokens after execution.

---

## Demo
🎥 **Video Walkthrough (recorded demo):** https://youtu.be/lQcIWdhaHUM

The demo shows creating and cancelling a trailing stop order (`test_CreateAndCancelStop`), with token balances refunded correctly.

### Generate a demo output file (for screenshot)
Run the focused test and save logs to a file:
```bash
# Runs only the Create & Cancel test and saves verbose output
forge test --match-path test/TickForgeTest.t.sol --match-test test_CreateAndCancelStop -vv > demo_output.txt
