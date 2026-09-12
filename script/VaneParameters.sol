// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaneConfig} from "../src/config/VaneConfig.sol";

/// @title VaneParameters
/// @notice The deployment parameter set, in one place.
/// @dev Every value here is a PLACEHOLDER pending the M6 calibration described in
///      section 12 Q4, and is marked as such rather than presented as a default:
///
///        theta   must come from the target pool's observed arbitrage latency, the time
///                from a centralised-venue move to the pool being closed by an
///                arbitrageur. A theta that is too small leaves a standing bias for
///                arbitrageurs to farm; too large and the belief decays before it does
///                any work.
///        K       must come from the horizon at which the pool's own variance ratio is
///                closest to one under the PLAIN curve, measured before VANE is applied.
///        eta,rho set the controller's steady-state loop gain eta/rho and its noise
///                spread; both have closed forms in the controller lesson, but the
///                targets they are solved against are a simulator output.
///        flowUnit must sit well below the pool's median trade so flow does not truncate
///                to zero, and well above the point where the accumulator saturates.
///
///      They are internally consistent and inside every validator bound, which is enough
///      to deploy to a testnet and exercise the mechanism. They are not claimed to be
///      correct for any real pool, and a mainnet deployment that uses them unchanged is
///      using numbers nobody has justified.
library VaneParameters {
    uint256 internal constant ONE_X32 = 1 << 32;
    uint256 internal constant ONE_X64 = 1 << 64;

    function config() internal pure returns (VaneConfig memory c) {
        c = VaneConfig({
            // 0.05 per block: a belief half-life of about 14 blocks, roughly three
            // minutes on Ethereum. Placeholder for measured arbitrage latency.
            thetaX64: uint64(ONE_X64 / 20),
            // 0.99 on both variances, an effective sample of 200 blocks. Equal decays
            // are deliberate: identical effective sample sizes make the log-variance
            // biases cancel exactly in the variance ratio.
            varLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            flowLambdaX32: uint64((uint256(99) * ONE_X32) / 100),
            // 20 blocks. Long enough for arbitrage to drag the pool toward the
            // fundamental, which is what makes the horizon variance see sigma at all.
            horizonK: 20,
            // eta = rho = 0.01 gives a unit steady-state loop gain: a persistent VR
            // error of x moves kappa by x times the anchor, and no further.
            controllerGainX32: uint64(ONE_X32 / 100),
            controllerLeakX32: uint64(ONE_X32 / 100),
            // Off by default. A symmetric band on a right-skewed statistic amplifies the
            // bias it is meant to suppress; enable only with a per-pool justification.
            controllerDeadbandX32: 0,
            kappaMaxX64: uint64(ONE_X64 / 1000),
            // 100 bps, the bound the offset arithmetic is fuzzed against.
            deltaMaxX64: uint64(ONE_X64 / 100),
            // Below 0.0001 bps the offset is not worth the settlement gas.
            deltaDustX64: uint64(ONE_X64 / 1_000_000),
            // 2000 ticks is a 22% move in one block: beyond that the print is a broken
            // market, not a price.
            maxTickDelta: 2000,
            // 1e12 wei per flow unit: a 1 ether trade is 1e6 units, which keeps the
            // squaring far from saturation while resolving trades down to a microether.
            flowUnit: 1e12,
            // 100 tokens at full strength. Absolute and therefore decimals-dependent, so
            // a pool pairing a 6-decimal and an 18-decimal token must override per
            // currency via setReserveTarget.
            reserveTargetDefault: 100e18,
            safetyFactorBps: 20_000,
            // Route A and Route B may differ by half before kappa is shrunk.
            maxEstimatorDivergenceX32: uint64(ONE_X32 / 2),
            // Three standard errors of the covariance EWMA before Route B is trusted.
            routeBZScore: 3
        });
    }
}
