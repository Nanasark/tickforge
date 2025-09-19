// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ITickForge
 * @dev Interface for the TickForge trailing stop hook contract.
 */
interface ITickForge {
    // Events
    event StopCreated(uint256 indexed tokenId, address indexed owner, PoolKey key, bool direction, int24 threshold, uint256 amount);
    event StopCancelled(uint256 indexed tokenId, address indexed owner);
    event StopTriggered(uint256 indexed tokenId, int24 triggerTick);
    event StopRedeemed(uint256 indexed tokenId, address indexed redeemer, uint256 amountOut);

    // Errors
    error NotOwner();
    error StopAlreadyTriggered();
    error StopNotTriggered();
    error StopNotActive();
    error ZeroAmount();
    error TransferFailed();
    error InvalidParameters();

    // External functions
    function createStop(
        PoolKey calldata key,
        int24 threshold,
        bool direction,
        uint256 amount
    ) external returns (uint256 tokenId);

    function cancelStop(uint256 tokenId) external;

    function redeem(uint256 tokenId) external;
}
