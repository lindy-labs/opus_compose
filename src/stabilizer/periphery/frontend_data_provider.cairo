use opus_compose::stabilizer::types::PoolInfo;
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IOracle<TContractState> {
    // Returns the geomean average price of a token as a 128.128 over the last `period` seconds
    fn get_price_x128_over_last(
        self: @TContractState,
        base_token: ContractAddress,
        quote_token: ContractAddress,
        period: u64,
    ) -> u256;
}

#[starknet::interface]
pub trait IFrontendDataProvider<TContractState> {
    // Returns a PoolInfo struct of:
    // 1. liquidity in pool;
    // 2. sqrt_ratio; and
    // the approximate amount of token reserves for a pool of a stabilizer given the exact
    // lower and upper ticks. The amounts may be inexact if there are other LP positions in the same
    // pool with different bounds.
    fn get_pool_info(self: @TContractState, stabilizer: ContractAddress) -> PoolInfo;
    // Returns the TVL of staked liquidity in a Stabilizer, denominated in CASH, using Ekubo's
    // oracle.
    fn get_staked_tvl(self: @TContractState, stabilizer: ContractAddress) -> Wad;
    // Returns the TVL of staked liquidity for a user in a Stabilizer, denominated in CASH, using
    // Ekubo's oracle.
    fn get_user_staked_tvl(
        self: @TContractState, stabilizer: ContractAddress, user: ContractAddress,
    ) -> Wad;
    // Returns the claimable yin for a user
    fn get_user_claimable_yin(
        self: @TContractState, stabilizer: ContractAddress, user: ContractAddress,
    ) -> Wad;
}

#[starknet::contract]
pub mod stabilizer_fdp {
    use core::integer::{u512, u512_safe_div_rem_by_u256};
    use core::num::traits::{Pow, WideMul, Zero};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::math::ticks::tick_to_sqrt_ratio;
    use ekubo::types::bounds::Bounds;
    use ekubo::types::keys::PoolKey;
    use ekubo::types::pool_price::PoolPrice;
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use opus_compose::addresses::mainnet;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::stabilizer::interfaces::stabilizer::{
        IStabilizerDispatcher, IStabilizerDispatcherTrait,
    };
    use opus_compose::stabilizer::math::get_accumulated_yin;
    use opus_compose::stabilizer::types::{PoolInfo, Stake, YieldState};
    use starknet::ContractAddress;
    use wadray::{Ray, WAD_DECIMALS, Wad, rmul_wr};
    use super::{IFrontendDataProvider, IOracleDispatcher, IOracleDispatcherTrait};

    const TWO_POW_128: u256 = 0x100000000000000000000000000000000;
    const TWAP_PERIOD: u64 = 5 * 60; // 5 minutes x 60s

    #[storage]
    struct Storage {}

    //
    // External functions
    //

    #[abi(embed_v0)]
    impl FrontendDataProviderImpl of IFrontendDataProvider<ContractState> {
        fn get_pool_info(self: @ContractState, stabilizer: ContractAddress) -> PoolInfo {
            let stabilizer = IStabilizerDispatcher { contract_address: stabilizer };
            let pool_key: PoolKey = stabilizer.get_pool_key();
            let bounds: Bounds = stabilizer.get_bounds();
            self.get_pool_info_helper(pool_key, bounds)
        }

        fn get_staked_tvl(self: @ContractState, stabilizer: ContractAddress) -> Wad {
            let stabilizer = IStabilizerDispatcher { contract_address: stabilizer };
            let pool_key: PoolKey = stabilizer.get_pool_key();
            let bounds: Bounds = stabilizer.get_bounds();

            let pool_info = self.get_pool_info_helper(pool_key, bounds);

            let staked_liquidity: u128 = stabilizer.get_total_liquidity();
            get_proportionate_tvl(pool_info.value, staked_liquidity, pool_info.liquidity)
        }

        fn get_user_staked_tvl(
            self: @ContractState, stabilizer: ContractAddress, user: ContractAddress,
        ) -> Wad {
            let stabilizer = IStabilizerDispatcher { contract_address: stabilizer };
            let pool_key: PoolKey = stabilizer.get_pool_key();
            let bounds: Bounds = stabilizer.get_bounds();

            let pool_info = self.get_pool_info_helper(pool_key, bounds);

            let staked_liquidity: u128 = if stabilizer.get_token_id_for_user(user).is_some() {
                stabilizer.get_stake(user).liquidity
            } else {
                Zero::zero()
            };

            get_proportionate_tvl(pool_info.value, staked_liquidity, pool_info.liquidity)
        }

        fn get_user_claimable_yin(
            self: @ContractState, stabilizer: ContractAddress, user: ContractAddress,
        ) -> Wad {
            let stabilizer = IStabilizerDispatcher { contract_address: stabilizer };
            let stake: Stake = stabilizer.get_stake(user);
            let yield_state: YieldState = stabilizer.get_yield_state();

            let claimable: u256 = get_accumulated_yin(
                stake.liquidity, yield_state.yin_per_liquidity - stake.yin_per_liquidity_snapshot,
            );
            claimable.try_into().unwrap()
        }
    }

    //
    // Internal helpers
    //

    #[generate_trait]
    impl FrontendDataProviderHelpers of FrontendDataProviderTrait {
        fn get_pool_info_helper(
            self: @ContractState, pool_key: PoolKey, bounds: Bounds,
        ) -> PoolInfo {
            let ekubo_core = ICoreDispatcher { contract_address: mainnet::EKUBO_CORE };
            let pool_liquidity: u128 = ekubo_core.get_pool_liquidity(pool_key);
            let pool_price: PoolPrice = ekubo_core.get_pool_price(pool_key);

            let upper_tick_sqrt_ratio: u256 = tick_to_sqrt_ratio(bounds.upper);
            let lower_tick_sqrt_ratio: u256 = tick_to_sqrt_ratio(bounds.lower);

            let token0_intermediate: u512 = WideMul::wide_mul(
                pool_liquidity.into() * (upper_tick_sqrt_ratio - pool_price.sqrt_ratio),
                TWO_POW_128,
            );
            // Use sequential division to avoid overflow
            //   token0_intermediate / (upper_tick_sqrt_ratio * sqrt_ratio)
            // = token0_intermediate / upper_tick_sqrt_ratio / sqrt_ratio
            let (token0_intermediate, _) = u512_safe_div_rem_by_u256(
                token0_intermediate, upper_tick_sqrt_ratio.try_into().unwrap(),
            );
            let (token0_amount, _) = u512_safe_div_rem_by_u256(
                token0_intermediate, pool_price.sqrt_ratio.try_into().unwrap(),
            );

            let token1_amount: u256 = pool_liquidity.into()
                * (pool_price.sqrt_ratio - lower_tick_sqrt_ratio)
                / TWO_POW_128;
            let token0_amount: u256 = token0_amount.try_into().unwrap();

            let (other_token, other_token_amount, yin_amount) = if pool_key
                .token0 == mainnet::SHRINE {
                (pool_key.token1, token1_amount, token0_amount)
            } else {
                (pool_key.token0, token0_amount, token1_amount)
            };

            let pool_value: Wad = self
                .get_pool_value_helper(yin_amount, other_token, other_token_amount);

            PoolInfo {
                liquidity: pool_liquidity,
                sqrt_ratio: pool_price.sqrt_ratio,
                token0_amount,
                token1_amount,
                value: pool_value,
            }
        }

        fn get_pool_value_helper(
            self: @ContractState,
            yin_amount: u256,
            other_token: ContractAddress,
            other_token_amount: u256,
        ) -> Wad {
            let other_token_decimals: u8 = IERC20Dispatcher { contract_address: other_token }
                .decimals();
            let other_token_price: Wad = convert_ekubo_oracle_price_to_wad(
                IOracleDispatcher { contract_address: mainnet::EKUBO_ORACLE }
                    .get_price_x128_over_last(other_token, mainnet::SHRINE, TWAP_PERIOD),
                other_token_decimals,
                WAD_DECIMALS,
            );

            // Scale the other token to Wad precision
            let scaled_other_token_amount: u256 = other_token_amount
                * 10_u256.pow((WAD_DECIMALS - other_token_decimals).into());
            scaled_other_token_amount.try_into().unwrap() * other_token_price
                + yin_amount.try_into().unwrap()
        }
    }

    // Returns the TVL for a given amount of liquidity and total liquidity in the Ekubo pool
    pub fn get_proportionate_tvl(tvl: Wad, liquidity: u128, total_liquidity: u128) -> Wad {
        let staked_liquidity_pct: Ray = liquidity.into() / total_liquidity.into();
        rmul_wr(tvl, staked_liquidity_pct)
    }
}
