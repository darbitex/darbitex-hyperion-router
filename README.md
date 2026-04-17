# Darbitex Hyperion Router

Smart-route swap satellite over Hyperion's 6 fee tiers on Aptos, with surplus-fee capture
on user-facing entries and a flash-loan arbitrage entry for keeper bots.

## Mainnet

- **Package publisher (3/5 multisig):** `0x4f54bca9333b94a334f0036fea3aa848e7722f7be0e63087cc4814c84797986a`
- **Module:** `router`
- **Upgrade policy:** `compatible` (soak phase; flip to `immutable` after stabilization)

## Functions

### Views (cheap, use for quoting)

- `quote_pool(pool, token_in, amount_in) -> u64`
- `quote_2hop(pool_1, pool_2, token_in, token_mid, amount_in) -> u64`

### User-facing entries (10% surplus fee to treasury)

- `user_swap_best_of_two(caller, pool_a, a_to_b_a, pool_b, a_to_b_b, baseline_pool, token_in, amount_in, min_out_to_user, deadline)`
- `user_swap_2hop(caller, pool_1, a_to_b_1, pool_2, a_to_b_2, baseline_pool, token_in, amount_in, min_out_to_user, deadline)`

### Keeper entry (flash arb, zero capital)

- `flash_arb_cross_tier(caller, borrow_asset, borrow_amount, pool_buy, a_to_b_buy, pool_sell, a_to_b_sell, min_profit, deadline)`
  - Uses Aave V3 Aptos flash loan (0% fee on supported assets).
  - Caller keeps profit; `min_profit` floor guards against unprofitable execution.

## Design

- **Permissionless.** Every entry accepts any signer; slippage and profit floors enforce safety on-chain.
- **Canonical direction off-chain.** Caller provides `a_to_b` per pool to avoid on-chain token metadata lookups (cheaper gas).
- **Baseline sanity guard.** Surplus fee only applies when `baseline_out > 0` and `total_out > baseline_out`, preventing a dead pool from being used to extract fee on full output.
- **Slippage checked after fee extraction** so the `min_out_to_user` guarantee holds for the amount actually deposited to the caller.

## Dependencies

- `aptos-framework` (mainnet)
- `hyperion_adapter` @ `0x5b4bf2a462a90158514ee1345599c764aa9513d117ba233cadf8494a266fa2bb` — CLMM swap primitive wrapper
- `dex_contract` @ `0x8b4a2c4bb53857c718a04c020b98f8c2e1f99a68b0f57389a8bf5434cd22e05c` — Hyperion V3 pool type
- `aave_pool` @ `0x39ddcd9e1a39fa14f25e3f9ec8a86074d05cc0881cbf667df8a6ee70942016fb` — flash loan source

## Treasury

Surplus fees accrue to the Darbitex treasury multisig at
`0xdbce89113a975826028236f910668c3ff99c8db8981be6a448caa2f8836f9576` (shared with other
Darbitex packages).

## License

Unlicense — public domain dedication.
