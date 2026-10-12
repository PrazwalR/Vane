// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {Fixtures} from "./utils/Fixtures.sol";

/// Who owns the reserve?
///
/// `fundReserve` used to be permissionless while `withdrawReserve` was owner-only with an
/// arbitrary amount and recipient, and there is no per-funder ledger anywhere — `reserveOf`
/// is one pooled number per currency. A third party who collateralised the hook therefore
/// had no claim on their capital and no way to retrieve it: it was a donation, and nothing
/// in the interface said so. The owner could move all of it to any address.
///
/// Funding is now owner-only, so the trust model matches the withdrawal semantics that
/// already existed: the reserve is operator capital. These tests pin that, and pin the
/// absence of a per-funder ledger as the reason a pro-rata claim could not be honoured
/// even in principle.
contract ReserveOwnershipTest is Test, Deployers {
    VaneHook internal hook;
    address internal hookOwner = address(0x00E9E6);
    address internal funder = address(0xF00D);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0x0E5E << 144));
        deployCodeTo("VaneHook.sol:VaneHook", abi.encode(manager, Fixtures.config(), hookOwner), hookAddr);
        hook = VaneHook(payable(hookAddr));

        // A third party with their own tokens, who is not the owner.
        MockERC20(Currency.unwrap(currency0)).mint(funder, 10_000 ether);
        vm.prank(funder);
        MockERC20(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
    }

    /// A non-owner must not be able to put capital somewhere they cannot retrieve it.
    function test_Revert_NonOwnerCannotFund() public {
        vm.prank(funder);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.fundReserve(currency0, 5_000 ether);

        assertEq(hook.reserveOf(currency0), 0, "no third-party capital can enter the reserve");
    }

    /// The operator funds it, which is the supported path.
    function test_OwnerCanFund() public {
        MockERC20(Currency.unwrap(currency0)).mint(hookOwner, 5_000 ether);
        vm.startPrank(hookOwner);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 5_000 ether);
        vm.stopPrank();

        assertEq(hook.reserveOf(currency0), 5_000 ether, "the operator collateralises the hook");
    }

    /// The owner retains unbounded withdrawal of their OWN capital, to any address. That
    /// is the documented trust model, and it is only acceptable because the capital at
    /// risk is now necessarily the operator's.
    function test_OwnerWithdrawalIsUnboundedByDesign() public {
        MockERC20(Currency.unwrap(currency0)).mint(hookOwner, 5_000 ether);
        vm.startPrank(hookOwner);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 5_000 ether);

        address anywhere = address(0xBEEF);
        hook.withdrawReserve(currency0, 5_000 ether, anywhere);
        vm.stopPrank();

        assertEq(hook.reserveOf(currency0), 0, "the operator may empty their own reserve");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(anywhere), 5_000 ether, "to any recipient");
    }

    /// There is no per-funder accounting, which is WHY funding had to become owner-only:
    /// a pro-rata claim could not have been honoured even in principle. Pinning it here so
    /// that anyone who later reopens funding has to add the ledger first.
    function test_ReserveIsOnePooledNumberPerCurrency() public {
        MockERC20(Currency.unwrap(currency0)).mint(hookOwner, 6_000 ether);
        vm.startPrank(hookOwner);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 5_000 ether);
        hook.fundReserve(currency0, 1_000 ether);
        vm.stopPrank();

        assertEq(hook.reserveOf(currency0), 6_000 ether, "deposits are pooled, with no record of origin");
    }

    /// Withdrawal stays owner-only, so both sides of the reserve are now consistent.
    function test_Revert_NonOwnerCannotWithdraw() public {
        MockERC20(Currency.unwrap(currency0)).mint(hookOwner, 5_000 ether);
        vm.startPrank(hookOwner);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 5_000 ether);
        vm.stopPrank();

        vm.prank(funder);
        vm.expectRevert(VaneHook.Vane__NotOwner.selector);
        hook.withdrawReserve(currency0, 5_000 ether, funder);
    }
}
