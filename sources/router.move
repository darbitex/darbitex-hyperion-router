/// Darbitex Hyperion Router — smart routing across Hyperion's 6 fee tiers
/// (+ 2-hop), with optional surplus-fee capture on user-facing entries and a
/// flash-arb entry for active cross-tier imbalance exploitation by keepers.
///
/// Both entry paths are permissionless. Caller provides all pool objects +
/// direction flags (a_to_b per pool) off-chain, eliminating the need for
/// on-chain token metadata lookups and keeping gas low.

module darbitex_hyperion_router::router {
    use std::signer;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use dex_contract::pool_v3;
    use hyperion_adapter::adapter as hyperion;
    use aave_pool::flashloan_logic;

    // ===== Events (v0.2) =====

    #[event]
    struct UserSwapExecuted has drop, store {
        caller: address,
        token_in: address,
        amount_in: u64,
        amount_out_to_user: u64,
        baseline_out: u64,
        surplus_fee: u64,
        route_kind: u8,   // 0 = best_of_two, 1 = 2hop
        timestamp: u64,
    }

    #[event]
    struct FlashArbExecuted has drop, store {
        caller: address,
        borrow_asset: address,
        borrow_amount: u64,
        profit: u64,
        pool_buy: address,
        pool_sell: address,
        timestamp: u64,
    }

    // ===== Errors =====

    const E_ZERO_AMOUNT: u64 = 1;
    const E_DEADLINE: u64 = 2;
    const E_MIN_OUT: u64 = 3;
    const E_INSUFFICIENT_PROFIT: u64 = 4;
    const E_CANT_REPAY: u64 = 5;

    // ===== Constants =====

    // Surplus fee: 10% of (actual_out - baseline_out) goes to treasury; rest to user.
    const SURPLUS_FEE_BPS: u64 = 1000;
    const BPS_DENOM: u64 = 10_000;
    const TREASURY: address = @0xdbce89113a975826028236f910668c3ff99c8db8981be6a448caa2f8836f9576;

    // ===== Views =====

    #[view]
    public fun quote_pool(
        pool: Object<pool_v3::LiquidityPoolV3>,
        token_in: Object<Metadata>,
        amount_in: u64,
    ): u64 {
        let (amount_out, _fee) = hyperion::get_amount_out(pool, token_in, amount_in);
        amount_out
    }

    #[view]
    public fun quote_2hop(
        pool_1: Object<pool_v3::LiquidityPoolV3>,
        pool_2: Object<pool_v3::LiquidityPoolV3>,
        token_in: Object<Metadata>,
        token_mid: Object<Metadata>,
        amount_in: u64,
    ): u64 {
        let (mid_out, _) = hyperion::get_amount_out(pool_1, token_in, amount_in);
        if (mid_out == 0) { return 0 };
        let (final_out, _) = hyperion::get_amount_out(pool_2, token_mid, mid_out);
        final_out
    }

    // ===== User-facing: best-of-two single-hop =====

    /// Smart 1-hop swap across two candidate pools. Router picks the better
    /// output, splits any surplus vs baseline as 10% treasury / 90% user bonus.
    /// Caller provides canonical-sorted a_to_b flag per pool off-chain.
    public entry fun user_swap_best_of_two(
        caller: &signer,
        pool_a: Object<pool_v3::LiquidityPoolV3>,
        a_to_b_a: bool,
        pool_b: Object<pool_v3::LiquidityPoolV3>,
        a_to_b_b: bool,
        baseline_pool: Object<pool_v3::LiquidityPoolV3>,
        token_in: Object<Metadata>,
        amount_in: u64,
        min_out_to_user: u64,
        deadline: u64,
    ) {
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE);

        let caller_addr = signer::address_of(caller);

        // Baseline quote (view-only, no state change)
        let (baseline_out, _) = hyperion::get_amount_out(baseline_pool, token_in, amount_in);

        // Quote both candidates
        let (quote_a, _) = hyperion::get_amount_out(pool_a, token_in, amount_in);
        let (quote_b, _) = hyperion::get_amount_out(pool_b, token_in, amount_in);

        let fa_in = primary_fungible_store::withdraw(caller, token_in, amount_in);

        let fa_out = if (quote_a >= quote_b) {
            hyperion::swap(pool_a, a_to_b_a, fa_in, 0)
        } else {
            hyperion::swap(pool_b, a_to_b_b, fa_in, 0)
        };

        let total_out = fungible_asset::amount(&fa_out);

        // Surplus fee: if routed output > baseline, 10% of surplus → treasury.
        // Baseline sanity: require baseline > 0 so a dead/empty pool can't be
        // gamed to extract fee on the full output.
        let fee_amount = 0u64;
        if (baseline_out > 0 && total_out > baseline_out) {
            let surplus = total_out - baseline_out;
            let fee = surplus * SURPLUS_FEE_BPS / BPS_DENOM;
            if (fee > 0) {
                let fa_fee = fungible_asset::extract(&mut fa_out, fee);
                primary_fungible_store::deposit(TREASURY, fa_fee);
                fee_amount = fee;
            };
        };

        // Slippage check AFTER fee extraction — what user actually receives.
        let user_out = fungible_asset::amount(&fa_out);
        assert!(user_out >= min_out_to_user, E_MIN_OUT);

        primary_fungible_store::deposit(caller_addr, fa_out);

        event::emit(UserSwapExecuted {
            caller: caller_addr,
            token_in: object::object_address(&token_in),
            amount_in,
            amount_out_to_user: user_out,
            baseline_out,
            surplus_fee: fee_amount,
            route_kind: 0,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ===== User-facing: 2-hop =====

    /// 2-hop swap through two Hyperion pools (token_in → token_mid → token_out).
    /// Surplus fee vs single-hop baseline quote.
    public entry fun user_swap_2hop(
        caller: &signer,
        pool_1: Object<pool_v3::LiquidityPoolV3>,
        a_to_b_1: bool,
        pool_2: Object<pool_v3::LiquidityPoolV3>,
        a_to_b_2: bool,
        baseline_pool: Object<pool_v3::LiquidityPoolV3>,
        token_in: Object<Metadata>,
        amount_in: u64,
        min_out_to_user: u64,
        deadline: u64,
    ) {
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE);

        let caller_addr = signer::address_of(caller);

        let (baseline_out, _) = hyperion::get_amount_out(baseline_pool, token_in, amount_in);

        let fa_in = primary_fungible_store::withdraw(caller, token_in, amount_in);

        let fa_mid = hyperion::swap(pool_1, a_to_b_1, fa_in, 0);
        let fa_out = hyperion::swap(pool_2, a_to_b_2, fa_mid, 0);

        let total_out = fungible_asset::amount(&fa_out);

        let fee_amount = 0u64;
        if (baseline_out > 0 && total_out > baseline_out) {
            let surplus = total_out - baseline_out;
            let fee = surplus * SURPLUS_FEE_BPS / BPS_DENOM;
            if (fee > 0) {
                let fa_fee = fungible_asset::extract(&mut fa_out, fee);
                primary_fungible_store::deposit(TREASURY, fa_fee);
                fee_amount = fee;
            };
        };

        // Slippage check AFTER fee extraction.
        let user_out = fungible_asset::amount(&fa_out);
        assert!(user_out >= min_out_to_user, E_MIN_OUT);

        primary_fungible_store::deposit(caller_addr, fa_out);

        event::emit(UserSwapExecuted {
            caller: caller_addr,
            token_in: object::object_address(&token_in),
            amount_in,
            amount_out_to_user: user_out,
            baseline_out,
            surplus_fee: fee_amount,
            route_kind: 1,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ===== Keeper: flash-arb cross-tier =====

    /// Atomic cross-tier arbitrage using Aave flash loan (0 fee on supported assets).
    /// Flow:
    ///   1. Aave flash_loan_simple(asset, amount) → receipt + asset in caller store
    ///   2. Withdraw borrowed FA → swap via pool_buy (cheap side) → fa_mid
    ///   3. Swap fa_mid via pool_sell (expensive side) → fa_back (same asset as borrowed)
    ///   4. Deposit fa_back, pay_flash_loan_simple pulls repay amount
    ///   5. Remaining balance in caller store = profit. Assert min_profit floor.
    public entry fun flash_arb_cross_tier(
        caller: &signer,
        borrow_asset: Object<Metadata>,
        borrow_amount: u64,
        pool_buy: Object<pool_v3::LiquidityPoolV3>,
        a_to_b_buy: bool,
        pool_sell: Object<pool_v3::LiquidityPoolV3>,
        a_to_b_sell: bool,
        min_profit: u64,
        deadline: u64,
    ) {
        assert!(borrow_amount > 0, E_ZERO_AMOUNT);
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE);

        let caller_addr = signer::address_of(caller);
        let borrow_asset_addr = object::object_address(&borrow_asset);

        // Balance before for profit accounting
        let bal_before = primary_fungible_store::balance(caller_addr, borrow_asset);

        // 1. Flash borrow — deposits to caller's primary store
        let receipt = flashloan_logic::flash_loan_simple(
            caller,
            caller_addr,
            borrow_asset_addr,
            (borrow_amount as u256),
            0u16,
        );

        // 2. Withdraw borrowed amount + swap via pool_buy
        let fa_borrowed = primary_fungible_store::withdraw(caller, borrow_asset, borrow_amount);
        let fa_mid = hyperion::swap(pool_buy, a_to_b_buy, fa_borrowed, 0);

        // 3. Swap mid → back via pool_sell
        let fa_back = hyperion::swap(pool_sell, a_to_b_sell, fa_mid, 0);
        let back_amount = fungible_asset::amount(&fa_back);
        assert!(back_amount >= borrow_amount, E_CANT_REPAY);

        // 4. Deposit result; Aave repay will pull from store
        primary_fungible_store::deposit(caller_addr, fa_back);

        // 5. Repay flash loan (pulls borrow_amount from caller store)
        flashloan_logic::pay_flash_loan_simple(caller, receipt);

        // 6. Profit check — balance increase >= min_profit
        let bal_after = primary_fungible_store::balance(caller_addr, borrow_asset);
        assert!(bal_after >= bal_before + min_profit, E_INSUFFICIENT_PROFIT);

        event::emit(FlashArbExecuted {
            caller: caller_addr,
            borrow_asset: borrow_asset_addr,
            borrow_amount,
            profit: bal_after - bal_before,
            pool_buy: object::object_address(&pool_buy),
            pool_sell: object::object_address(&pool_sell),
            timestamp: timestamp::now_seconds(),
        });
    }
}
