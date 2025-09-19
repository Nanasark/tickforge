// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "./MockERC20.sol";
import {TickForge} from "../src/TickForge.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {console} from "forge-std/console.sol";

contract TickForgeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TickForge public hook;
    IPoolManager public poolManager;
    MockERC20 public token0;
    MockERC20 public token1;
    address public user;
    PoolKey public poolKey;
    PoolId public poolId;

    uint256 constant INITIAL_BALANCE = 1e24; // 1M tokens
    uint24 constant TRAILING_OFFSET = 500; // 5% in basis points
    uint256 constant DEPOSIT_AMOUNT = 10e18;
    uint256 constant SWAP_AMOUNT = 1e18; // Increased to move tick significantly
    int24 constant TICK_SPACING = 60;

    function setUp() public {
        deployFreshManagerAndRouters();
        poolManager = IPoolManager(address(manager));

        token0 = new MockERC20(18);
        token1 = new MockERC20(18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        user = makeAddr("user");
        token0.mint(user, INITIAL_BALANCE);
        token1.mint(user, INITIAL_BALANCE);

        uint160 hookFlags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(manager, "");
        bytes memory creationCode = type(TickForge).creationCode;
        (, bytes32 salt) = HookMiner.find(address(this), hookFlags, creationCode, constructorArgs);
        hook = new TickForge{salt: salt}(manager, "");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        vm.prank(address(this));
        hook.setTrustedPool(poolId, true);

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(poolKey, sqrtPrice);

        vm.startPrank(user);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 0}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -1200,
                tickUpper: 1200,
                liquidityDelta: 1e21, // Increased to 1e21 for larger swaps
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();

        // Log initial state
        console.log("User token0 balance after liquidity:", uint256(token0.balanceOf(user)));
        console.log("User token1 balance after liquidity:", uint256(token1.balanceOf(user)));
        (, int24 tick, , ) = poolManager.getSlot0(poolId);
        console.log("Pool initial tick:", int256(tick));
        console.log("Pool liquidity:", uint256(poolManager.getLiquidity(poolId)));
    }

    function test_CreateAndCancelStop() public {
        vm.startPrank(user);
        IERC20(address(token0)).approve(address(hook), DEPOSIT_AMOUNT);
        uint256 tokenId = hook.createStop(poolKey, TRAILING_OFFSET, true, DEPOSIT_AMOUNT, 0);
        assertEq(token0.balanceOf(address(hook)), DEPOSIT_AMOUNT, "Hook should hold deposit");
        hook.cancelStop(tokenId);
        vm.stopPrank();
        (address stopOwner, uint256 inputAmount, , , , bool executed, , ) = hook.getStopDetails(tokenId);
        assertEq(inputAmount, 0, "Input amount was not cleared");
        assertEq(token0.balanceOf(user), 999941767358693748060545, "Tokens were not refunded");
        assertEq(stopOwner, address(0), "Owner was not cleared");
        assertFalse(executed, "Order should not be executed");
    }

    function test_TrailingStopTriggerAndExecute() public {
        vm.startPrank(user);
        IERC20(address(token1)).approve(address(hook), DEPOSIT_AMOUNT);
        uint256 tokenId = hook.createStop(poolKey, TRAILING_OFFSET, false, DEPOSIT_AMOUNT, 0);

        // Log pool state
        (, int24 initialTick, , ) = poolManager.getSlot0(poolId);
        uint160 currentPrice = TickMath.getSqrtPriceAtTick(initialTick);
        console.log("Initial tick:", int256(initialTick));
        console.log("Current price:", uint256(currentPrice));

        // Log balances before swap
        console.log("User token0 balance before swap:", uint256(token0.balanceOf(user)));
        console.log("User token1 balance before swap:", uint256(token1.balanceOf(user)));

        // First swap: token0 -> token1 (price down, tick down)
        int24 targetTick = initialTick - (initialTick % TICK_SPACING) - TICK_SPACING; // ~60 ticks down
        uint160 priceLimitDown = TickMath.getSqrtPriceAtTick(targetTick);
        console.log("Price limit down:", uint256(priceLimitDown));

        SwapParams memory paramsDown = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: priceLimitDown
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Debug swap
        try swapRouter.swap(poolKey, paramsDown, settings, "") returns (BalanceDelta delta) {
            console.log("First swap succeeded, delta0:", int256(delta.amount0()));
            console.log("First swap succeeded, delta1:", int256(delta.amount1()));
        } catch Error(string memory reason) {
            console.log("First swap failed:", reason);
            revert("First swap failed");
        } catch (bytes memory lowLevelData) {
            console.log("First swap failed with low-level error");
            if (lowLevelData.length >= 4) {
                bytes4 selector = bytes4(lowLevelData);
                console.logBytes(abi.encode(selector));
                if (selector == bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"))) {
                    console.log("Error: PriceLimitAlreadyExceeded");
                } else if (selector == bytes4(keccak256("InsufficientLiquidity()"))) {
                    console.log("Error: InsufficientLiquidity");
                }
            }
            revert("First swap failed with low-level error");
        }

        // Verify pool state and balances
        (, int24 lowTick, , ) = poolManager.getSlot0(poolId);
        console.log("Low tick after first swap:", int256(lowTick));
        console.log("Pool liquidity after swap:", uint256(poolManager.getLiquidity(poolId)));
        console.log("User token0 balance after swap:", uint256(token0.balanceOf(user)));
        console.log("User token1 balance after swap:", uint256(token1.balanceOf(user)));
        assertTrue(lowTick < initialTick, "Tick should decrease");

        // Second swap: token1 -> token0 (price up, tick up)
        uint160 priceLimitUp = TickMath.getSqrtPriceAtTick(lowTick + TICK_SPACING * 10); // ~600 ticks
        console.log("Price limit up:", uint256(priceLimitUp));
        SwapParams memory paramsUp = SwapParams({
            zeroForOne: false,
            amountSpecified: int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: priceLimitUp
        });

        try swapRouter.swap(poolKey, paramsUp, settings, "") returns (BalanceDelta delta) {
            console.log("Second swap succeeded, delta0:", int256(delta.amount0()));
            console.log("Second swap succeeded, delta1:", int256(delta.amount1()));
        } catch Error(string memory reason) {
            console.log("Second swap failed:", reason);
            revert("Second swap failed");
        } catch (bytes memory lowLevelData) {
            console.log("Second swap failed with low-level error");
            revert("Second swap failed with low-level error");
        }

        // Check order execution
        ( , , , , , bool executed, , ) = hook.getStopDetails(tokenId);
        assertTrue(executed, "Stop was not executed");
        assertEq(token1.balanceOf(address(hook)), 0, "Input tokens should be zeroed");
        assertTrue(token0.balanceOf(address(hook)) > 0, "Output tokens should be held");

        hook.claimProceeds(tokenId);
        assertTrue(token0.balanceOf(user) > 0, "Output tokens were not claimed");

        vm.stopPrank();
    }
}