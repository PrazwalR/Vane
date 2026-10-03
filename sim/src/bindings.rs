//! ABI surface the replay engine touches.
//!
//! These must match `src/` field for field, because the engine decodes through the
//! generated types rather than by byte offset. A hand-mirrored layout that has drifted
//! decodes successfully and returns the wrong field, which is the worst failure mode
//! available to a measuring instrument — `PoolState.saturated` was missing here while the
//! trace claimed to report the hook's state.

use alloy_sol_types::sol;

sol! {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(
        PoolKey key,
        SwapParams params,
        TestSettings testSettings,
        bytes hookData
    ) external payable returns (int256 delta);

    function reserveOf(address currency) external view returns (uint256);
    function beliefOf(bytes32 id) external view returns (int256);
    function kappaOf(bytes32 id) external view returns (uint256);

    struct PoolState {
        int24 lastTick;
        uint32 lastBlock;
        uint64 varOneX32;
        uint64 flowVarUnitsSq;
        int64 deltaX64;
        bool saturated;
    }
    function poolState(bytes32 id) external view returns (PoolState);

    struct FlowCovState {
        int64 prevFlow1;
        int64 prevFlow2;
        int64 cov1;
        int64 cov2;
    }
    function flowCovOf(bytes32 id) external view returns (FlowCovState);
    function extsload(bytes32 slot) external view returns (bytes32);
}
