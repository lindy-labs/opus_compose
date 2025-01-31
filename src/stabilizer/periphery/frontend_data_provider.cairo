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
}

#[starknet::contract]
pub mod frontend_data_provider {
    use core::num::traits::{WideMul, Zero};
    use core::integer::{u512, u512_safe_div_rem_by_u256};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
    use ekubo::types::bounds::Bounds;
    use ekubo::types::keys::PoolKey;
    use ekubo::types::pool_price::{PoolPrice};
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use opus_compose::addresses::mainnet;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::stabilizer::interfaces::stabilizer::{
        IStabilizerDispatcher, IStabilizerDispatcherTrait,
    };
    use opus_compose::stabilizer::types::PoolInfo;
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::{IFrontendDataProvider, IOracleDispatcher, IOracleDispatcherTrait};
    use wadray::{rmul_wr, Wad, WAD_DECIMALS, Ray};

    const TWO_POW_128: u256 = 0x100000000000000000000000000000000;
    const TWAP_PERIOD: u64 = 5 * 60; // 5 minutes x 60s

    //
    // Storage
    //

    #[storage]
    struct Storage {
        ekubo_core: ICoreDispatcher,
        ekubo_oracle: IOracleDispatcher,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, ekubo_core: ContractAddress, ekubo_oracle: ContractAddress,
    ) {
        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_oracle.write(IOracleDispatcher { contract_address: ekubo_oracle });
    }

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

            let pool_tvl = self.get_pool_tvl_helper(pool_key, pool_info);

            let staked_liquidity: u128 = stabilizer.get_total_liquidity();
            get_proportionate_tvl(pool_tvl, staked_liquidity, pool_info.liquidity)
        }

        fn get_user_staked_tvl(
            self: @ContractState, stabilizer: ContractAddress, user: ContractAddress,
        ) -> Wad {
            let stabilizer = IStabilizerDispatcher { contract_address: stabilizer };
            let pool_key: PoolKey = stabilizer.get_pool_key();
            let bounds: Bounds = stabilizer.get_bounds();

            let pool_info = self.get_pool_info_helper(pool_key, bounds);

            let pool_tvl = self.get_pool_tvl_helper(pool_key, pool_info);

            let staked_liquidity: u128 = if stabilizer.get_token_id_for_user(user).is_some() {
                stabilizer.get_stake(user).liquidity
            } else {
                Zero::zero()
            };
            
            get_proportionate_tvl(pool_tvl, staked_liquidity, pool_info.liquidity)
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
            let math = mathlib();
        
            let ekubo_core = self.ekubo_core.read();
            let pool_liquidity: u128 = ekubo_core.get_pool_liquidity(pool_key);
            let pool_price: PoolPrice = ekubo_core.get_pool_price(pool_key);

            let upper_tick_sqrt_ratio: u256 = math.tick_to_sqrt_ratio(bounds.upper);
            let lower_tick_sqrt_ratio: u256 = math.tick_to_sqrt_ratio(bounds.lower);
            let sqrt_ratio: u256 = pool_price.sqrt_ratio.into();

            let token0_intermediate: u512 = WideMul::wide_mul(
                pool_liquidity.into() * (upper_tick_sqrt_ratio - sqrt_ratio), TWO_POW_128,
            );
            let (token0_amount, _) = u512_safe_div_rem_by_u256(
                token0_intermediate, (sqrt_ratio * upper_tick_sqrt_ratio).try_into().unwrap(),
            );
            let token1_amount: u256 = pool_liquidity.into()
                * (sqrt_ratio - lower_tick_sqrt_ratio)
                / TWO_POW_128;

            PoolInfo {
                liquidity: pool_liquidity,
                sqrt_ratio: pool_price.sqrt_ratio,
                token0_amount: token0_amount.try_into().unwrap(),
                token1_amount,
            }
        }

        fn get_pool_tvl_helper(
            self: @ContractState, pool_key: PoolKey, pool_info: PoolInfo,
        ) -> Wad {
            let (other_token, other_token_amount, yin_amount) = if pool_key
                .token0 == mainnet::shrine() {
                (pool_key.token1, pool_info.token1_amount, pool_info.token0_amount)
            } else {
                (pool_key.token0, pool_info.token0_amount, pool_info.token1_amount)
            };

            let other_token_price: Wad = convert_ekubo_oracle_price_to_wad(
                self
                    .ekubo_oracle
                    .read()
                    .get_price_x128_over_last(other_token, mainnet::shrine(), TWAP_PERIOD),
                IERC20Dispatcher { contract_address: other_token }.decimals(),
                WAD_DECIMALS,
            );

            other_token_amount.try_into().unwrap() * other_token_price
                + yin_amount.try_into().unwrap()
        }
    }

    // Returns the TVL for a given amount of liquidity and total liquidity in the Ekubo pool
    pub fn get_proportionate_tvl(tvl: Wad, liquidity: u128, total_liquidity: u128) -> Wad {
        let staked_liquidity_pct: Ray = liquidity.into() / total_liquidity.into();
        rmul_wr(tvl, staked_liquidity_pct)
    }
}
