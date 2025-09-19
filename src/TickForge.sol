// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract TickForge is BaseHook, ERC1155, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Events
    event StopCreated(uint256 indexed tokenId, address indexed owner, uint24 percentageThreshold);
    event StopTriggered(uint256 indexed tokenId, int24 triggerTick);
    event StopExecuted(uint256 indexed tokenId, uint256 outputAmount);
    event StopCancelled(uint256 indexed tokenId);
    event ExecutionFailed(uint256 indexed tokenId, string reason);

    // Errors
    error ZeroAmount();
    error InvalidParameters();
    error NotOwner();
    error TransferFailed();
    error InsufficientBalance();
    error InvalidTick();
    error InputTooLarge();

    // Constants
    uint256 public constant MAX_STOPS_PER_SWAP = 5;
    uint256 public constant MAX_STOPS_PER_POOL = 1000;
    uint256 public constant MAX_PERCENTAGE_THRESHOLD = 5000; // 50%

    // Packed structs
    struct StopData {
        address owner;
        uint128 inputAmount;
        uint128 outputAmount;
        bool direction; // true = zeroForOne (sell token0), false = !zeroForOne (sell token1)
        bool triggered;
        bool executed;
    }

    struct StopConfig {
        int24 trailingTick;
        uint24 percentageThreshold; // In basis points
        uint128 minOutputAmount;
        uint64 createdAt;
    }

    // Storage
    mapping(uint256 => StopData) public stopData;
    mapping(uint256 => StopConfig) public stopConfig;
    mapping(uint256 => PoolKey) public stopKeys;
    mapping(PoolId => uint256[]) public poolStopIds;
    mapping(PoolId => mapping(uint256 => uint256)) public stopIndexInPool;
    mapping(PoolId => uint256) public processingOffset;
    mapping(PoolId => bool) public trustedPools;
    mapping(uint256 => bool) private _locks;
    uint256 public nextTokenId;
    address public immutable owner;

    // Reentrancy modifier
    modifier nonReentrant(uint256 tokenId) {
        require(!_locks[tokenId], "Locked");
        _locks[tokenId] = true;
        _;
        _locks[tokenId] = false;
    }

    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {
        owner = msg.sender;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setTrustedPool(PoolId poolId, bool trusted) external {
        require(msg.sender == owner, "Only owner");
        trustedPools[poolId] = trusted;
    }

    function createStop(
        PoolKey calldata key,
        uint24 percentageThreshold,
        bool direction,
        uint256 amount,
        uint256 minOutputAmount
    ) external payable returns (uint256 tokenId) {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert InputTooLarge();
        if (percentageThreshold == 0 || percentageThreshold > MAX_PERCENTAGE_THRESHOLD) revert InvalidParameters();
        if (!trustedPools[key.toId()]) revert InvalidParameters();

        tokenId = nextTokenId++;
        
        PoolId poolId = key.toId();
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);
        require(currentTick >= -887272 && currentTick <= 887272, "Invalid tick");

        stopData[tokenId] = StopData({
            owner: msg.sender,
            inputAmount: uint128(amount),
            outputAmount: 0,
            direction: direction,
            triggered: false,
            executed: false
        });
        
        stopConfig[tokenId] = StopConfig({
            trailingTick: currentTick,
            percentageThreshold: percentageThreshold,
            minOutputAmount: uint128(minOutputAmount),
            createdAt: uint64(block.timestamp)
        });
        
        stopKeys[tokenId] = key;
        
        require(poolStopIds[poolId].length < MAX_STOPS_PER_POOL, "Pool stop limit reached");
        stopIndexInPool[poolId][tokenId] = poolStopIds[poolId].length;
        poolStopIds[poolId].push(tokenId);
        
        _transferAndMint(key, direction, amount, tokenId);
        
        emit StopCreated(tokenId, msg.sender, percentageThreshold);
    }

    function _transferAndMint(PoolKey calldata key, bool direction, uint256 amount, uint256 tokenId) internal {
        address tokenIn = direction ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        bool success = IERC20(tokenIn).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        _mint(msg.sender, tokenId, amount, "");
    }

    function cancelStop(uint256 tokenId) external nonReentrant(tokenId) {
        StopData storage data = stopData[tokenId];
        if (data.owner != msg.sender) revert NotOwner();
        if (data.executed) revert("Already executed");
        if (balanceOf(msg.sender, tokenId) < data.inputAmount) revert InsufficientBalance();
        
        _cancelStopInternal(tokenId);
        emit StopCancelled(tokenId);
    }

    function _cancelStopInternal(uint256 tokenId) internal {
        StopData storage data = stopData[tokenId];
        PoolKey memory key = stopKeys[tokenId];
        
        _removeStopFromPool(key.toId(), tokenId);
        
        uint256 refund = data.inputAmount;
        address tokenIn = data.direction ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        
        data.owner = address(0);
        data.inputAmount = 0;
        
        _burn(msg.sender, tokenId, refund);
        bool success = IERC20(tokenIn).transfer(msg.sender, refund);
        if (!success) revert TransferFailed();
    }

    function claimProceeds(uint256 tokenId) external nonReentrant(tokenId) {
        StopData storage data = stopData[tokenId];
        if (data.owner != msg.sender) revert NotOwner();
        if (!data.executed) revert("Not executed");
        if (data.outputAmount == 0) revert("No proceeds");
        if (balanceOf(msg.sender, tokenId) < data.inputAmount) revert InsufficientBalance();
        
        _claimInternal(tokenId);
    }

    function _claimInternal(uint256 tokenId) internal {
        StopData storage data = stopData[tokenId];
        PoolKey memory key = stopKeys[tokenId];
        
        uint256 claimAmount = data.outputAmount;
        uint256 burnAmount = data.inputAmount;
        address tokenOut = data.direction ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        
        data.outputAmount = 0;
        data.owner = address(0);
        
        _burn(msg.sender, tokenId, burnAmount);
        bool success = IERC20(tokenOut).transfer(msg.sender, claimAmount);
        if (!success) revert TransferFailed();
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        require(trustedPools[poolId], "Invalid pool");
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);
        require(currentTick >= -887272 && currentTick <= 887272, "Invalid tick");
        
        _processStops(poolId, currentTick);
        
        return (BaseHook.afterSwap.selector, 0);
    }

    function _processStops(PoolId poolId, int24 currentTick) internal {
        uint256[] storage stops = poolStopIds[poolId];
        uint256 len = stops.length > MAX_STOPS_PER_SWAP ? MAX_STOPS_PER_SWAP : stops.length;
        
        if (len == 0) return;
        
        uint256 offset = processingOffset[poolId];
        uint256 processed;
        
        for (uint256 i; i < len && processed < MAX_STOPS_PER_SWAP; i++) {
            uint256 idx = (offset + i) % len;
            uint256 tokenId = stops[idx];
            
            if (_shouldExecute(tokenId, currentTick)) {
                _executeStop(tokenId, currentTick);
            }
            
            processed++;
        }
        
        processingOffset[poolId] = (offset + processed) % len;
    }

    function _shouldExecute(uint256 tokenId, int24 currentTick) internal returns (bool) {
        StopData storage data = stopData[tokenId];
        if (data.owner == address(0) || data.executed) return false;
        
        StopConfig storage config = stopConfig[tokenId];
        
        // Use tick-based threshold
        int24 thresholdTicks = int24(config.percentageThreshold); // 500 for 5%, approx 487
        bool tickTriggered;
        
        if (data.direction) { // zeroForOne (sell token0, price falls, ticks decrease)
            if (currentTick > config.trailingTick) {
                config.trailingTick = currentTick;
            } else {
                tickTriggered = (config.trailingTick - currentTick) >= thresholdTicks;
            }
        } else { // !zeroForOne (sell token1, price rises, ticks increase)
            if (currentTick < config.trailingTick) {
                config.trailingTick = currentTick;
            } else {
                tickTriggered = (currentTick - config.trailingTick) >= thresholdTicks;
            }
        }
        
        return tickTriggered;
    }

    function _executeStop(uint256 tokenId, int24 currentTick) internal {
        stopData[tokenId].triggered = true;
        emit StopTriggered(tokenId, currentTick);
        
        try this._performSwap(tokenId) {
            _removeStopFromPool(stopKeys[tokenId].toId(), tokenId);
        } catch Error(string memory reason) {
            emit ExecutionFailed(tokenId, reason);
        }
    }

    function _performSwap(uint256 tokenId) external {
        require(msg.sender == address(this), "Internal only");
        
        StopData storage data = stopData[tokenId];
        PoolKey memory key = stopKeys[tokenId];
        
        SwapParams memory params = SwapParams({
            zeroForOne: data.direction,
            amountSpecified: int256(uint256(data.inputAmount)),
            sqrtPriceLimitX96: data.direction ? 
                TickMath.MIN_SQRT_PRICE + 1 : 
                TickMath.MAX_SQRT_PRICE - 1
        });
        
        poolManager.unlock(abi.encode(key, params, tokenId));
    }

    function executeStop(uint256 tokenId) external nonReentrant(tokenId) {
        StopData storage data = stopData[tokenId];
        if (data.owner != msg.sender) revert NotOwner();
        if (data.executed) revert("Already executed");

        int24 currentTick;
        bool shouldTrigger = false;

        if (!data.triggered) {
            PoolId poolId = stopKeys[tokenId].toId();
            (, currentTick, , ) = poolManager.getSlot0(poolId);
            require(currentTick >= -887272 && currentTick <= 887272, "Invalid tick");
            shouldTrigger = _shouldExecute(tokenId, currentTick);
            if (!shouldTrigger) revert("Not triggered");
            data.triggered = true;
            emit StopTriggered(tokenId, currentTick);
        }

        this._performSwap(tokenId);
        _removeStopFromPool(stopKeys[tokenId].toId(), tokenId);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Not PoolManager");
        
        (PoolKey memory key, SwapParams memory params, uint256 tokenId) = 
            abi.decode(data, (PoolKey, SwapParams, uint256));
        
        _executeSwap(key, params, tokenId);
        return "";
    }

    function _executeSwap(PoolKey memory key, SwapParams memory params, uint256 tokenId) internal {
        StopData storage data = stopData[tokenId];
        StopConfig storage config = stopConfig[tokenId];
        
        BalanceDelta delta = poolManager.swap(key, params, "");
        
        Currency inputCurrency = data.direction ? key.currency0 : key.currency1;
        Currency outputCurrency = data.direction ? key.currency1 : key.currency0;
        
        int128 inputDelta = data.direction ? delta.amount0() : delta.amount1();
        int128 outputDelta = data.direction ? delta.amount1() : delta.amount0();
        
        uint256 inputAmount = uint256(uint128(-inputDelta));
        uint256 outputAmount = uint256(uint128(outputDelta));
        
        require(outputAmount >= config.minOutputAmount, "Slippage");
        
        poolManager.take(inputCurrency, address(poolManager), inputAmount);
        poolManager.settle();
        poolManager.take(outputCurrency, address(this), outputAmount);
        
        data.executed = true;
        data.outputAmount = uint128(outputAmount);
        
        emit StopExecuted(tokenId, outputAmount);
    }

    function _removeStopFromPool(PoolId poolId, uint256 tokenId) internal {
        uint256[] storage stops = poolStopIds[poolId];
        uint256 index = stopIndexInPool[poolId][tokenId];
        uint256 lastIndex = stops.length - 1;
        
        if (index != lastIndex) {
            uint256 lastTokenId = stops[lastIndex];
            stops[index] = lastTokenId;
            stopIndexInPool[poolId][lastTokenId] = index;
        }
        
        stops.pop();
        delete stopIndexInPool[poolId][tokenId];
    }

    function getStopDetails(uint256 tokenId) external view returns (
        address stopOwner,
        uint256 inputAmount,
        uint256 outputAmount,
        bool direction,
        bool triggered,
        bool executed,
        int24 trailingTick,
        uint24 percentageThreshold
    ) {
        StopData memory data = stopData[tokenId];
        StopConfig memory config = stopConfig[tokenId];
        return (
            data.owner,
            data.inputAmount,
            data.outputAmount,
            data.direction,
            data.triggered,
            data.executed,
            config.trailingTick,
            config.percentageThreshold
        );
    }

    function uri(uint256 tokenId) public pure override returns (string memory) {
        return string(abi.encodePacked("https://tickforge.io/metadata/", _toString(tokenId)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    receive() external payable {}
}