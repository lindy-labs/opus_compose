use ekubo::interfaces::router::TokenAmount;
use ekubo::types::bounds::Bounds;
use ekubo::types::keys::PoolKey;

#[starknet::interface]
pub trait IEstimator<TContractState> {
    // Returns a tuple of the amount to swap and the liquidity
    fn get_optimal_swap_amount(
        self: @TContractState,
        pool_key: PoolKey,
        bounds: Bounds,
        input: TokenAmount,
        iterations: u8,
    ) -> (u128, u128);
}

// Single-sided liquidity provision by swapping an amount of the given asset for the other
// against a pool in order to provide the maximum liquidity to the same pool at the resulting
// price after the swap.
// Adapted from https://www.libevm.com/2022/04/06/uniswapv3-optimal-single-lp/
#[starknet::contract]
pub mod estimator {
    use core::cmp::max;
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::router::TokenAmount;
    use ekubo::math::max_liquidity::max_liquidity;
    use ekubo::math::swap::{SwapResult, swap_result};
    use ekubo::math::ticks::tick_to_sqrt_ratio;
    use ekubo::types::bounds::Bounds;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::IEstimator;

    const MIN_LIQUIDITY_RANGE: u128 = 100;

    #[storage]
    pub struct Storage {
        ekubo_core: ICoreDispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, ekubo_core: ContractAddress) {
        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
    }

    #[abi(embed_v0)]
    pub impl EstimatorImpl of IEstimator<ContractState> {
        fn get_optimal_swap_amount(
            self: @ContractState,
            pool_key: PoolKey,
            bounds: Bounds,
            input: TokenAmount,
            iterations: u8,
        ) -> (u128, u128) {
            assert!(!input.amount.sign, "Amount should be positive");
            let ekubo_core = self.ekubo_core.read();

            let fee = pool_key.fee;
            let pool_price = ekubo_core.get_pool_price(pool_key);
            let pool_liquidity = ekubo_core.get_pool_liquidity(pool_key);

            let (is_token1, sqrt_ratio_limit) = if input.token == pool_key.token0 {
                (false, pool_price.sqrt_ratio / 2)
            } else {
                (true, pool_price.sqrt_ratio * 2)
            };

            let sqrt_ratio_lower = tick_to_sqrt_ratio(bounds.lower);
            let sqrt_ratio_upper = tick_to_sqrt_ratio(bounds.upper);

            let input_u128: u128 = input.amount.try_into().unwrap();

            // Golden-section search
            // Golden ratio φ ≈ 1.618, inverse 1/φ ≈ 0.618
            // Using fixed-point: 1/φ = 618034/1000000 (high precision)
            let mut lower: u128 = 0;
            let mut upper: u128 = input_u128;

            // Pre-compute division: 618034 / 1000000
            let golden_ratio_inverse_numerator: u128 = 618034;
            let golden_ratio_inverse_denominator: u128 = 1000000;

            // Initial two test points
            let range = upper - lower;
            let golden_ratio_step = range
                * golden_ratio_inverse_numerator
                / golden_ratio_inverse_denominator;

            let mut c: u128 = upper - golden_ratio_step;
            let mut d: u128 = lower + golden_ratio_step;

            // Evaluate at both initial points
            let swap_result_c: SwapResult = swap_result(
                pool_price.sqrt_ratio, pool_liquidity, sqrt_ratio_limit, c.into(), is_token1, fee,
            );
            let mut liquidity_c: u128 = self
                .get_liquidity_from_swap_result(
                    swap_result_c, input.amount, sqrt_ratio_lower, sqrt_ratio_upper, is_token1,
                );

            let swap_result_d: SwapResult = swap_result(
                pool_price.sqrt_ratio, pool_liquidity, sqrt_ratio_limit, d.into(), is_token1, fee,
            );
            let mut liquidity_d: u128 = self
                .get_liquidity_from_swap_result(
                    swap_result_d, input.amount, sqrt_ratio_lower, sqrt_ratio_upper, is_token1,
                );

            let (mut optimal_liquidity, mut optimal_swap_amount) = if liquidity_c > liquidity_d {
                (liquidity_c, c)
            } else {
                (liquidity_d, d)
            };

            // Golden-section iterations
            for _ in 0..iterations {
                if upper - lower <= MIN_LIQUIDITY_RANGE {
                    break;
                }

                if liquidity_c > liquidity_d {
                    // Discard [d, upper]
                    upper = d;
                    d = c;
                    liquidity_d = liquidity_c;
                    // New c
                    c = upper
                        - ((upper - lower)
                            * golden_ratio_inverse_numerator
                            / golden_ratio_inverse_denominator);
                    let swap_result_new: SwapResult = swap_result(
                        pool_price.sqrt_ratio,
                        pool_liquidity,
                        sqrt_ratio_limit,
                        c.into(),
                        is_token1,
                        fee,
                    );
                    liquidity_c = self
                        .get_liquidity_from_swap_result(
                            swap_result_new,
                            input.amount,
                            sqrt_ratio_lower,
                            sqrt_ratio_upper,
                            is_token1,
                        );
                } else if liquidity_d > liquidity_c {
                    // Discard [lower, c]
                    lower = c;
                    c = d;
                    liquidity_c = liquidity_d;
                    // New d
                    d = lower
                        + ((upper - lower)
                            * golden_ratio_inverse_numerator
                            / golden_ratio_inverse_denominator);
                    let swap_result_new: SwapResult = swap_result(
                        pool_price.sqrt_ratio,
                        pool_liquidity,
                        sqrt_ratio_limit,
                        d.into(),
                        is_token1,
                        fee,
                    );
                    liquidity_d = self
                        .get_liquidity_from_swap_result(
                            swap_result_new,
                            input.amount,
                            sqrt_ratio_lower,
                            sqrt_ratio_upper,
                            is_token1,
                        );
                } else {
                    // Equal liquidity values - already converged
                    break;
                }

                // Update optimal
                optimal_liquidity = max(liquidity_c, liquidity_d);
                optimal_swap_amount = if liquidity_c > liquidity_d {
                    c
                } else {
                    d
                };
            }

            (optimal_swap_amount, optimal_liquidity)
        }
    }

    #[generate_trait]
    impl EstimatorHelpers of EstimatorHelpersTrait {
        fn get_liquidity_from_swap_result(
            self: @ContractState,
            swap_result_received: SwapResult,
            input_amount: i129,
            sqrt_ratio_lower: u256,
            sqrt_ratio_upper: u256,
            is_token1: bool,
        ) -> u128 {
            let remaining_input: u128 = (input_amount - swap_result_received.consumed_amount)
                .try_into()
                .unwrap();
            let purchased_other_asset = swap_result_received.calculated_amount;

            let (amount0, amount1) = if is_token1 {
                (purchased_other_asset, remaining_input)
            } else {
                (remaining_input, purchased_other_asset)
            };

            max_liquidity(
                swap_result_received.sqrt_ratio_next,
                sqrt_ratio_lower,
                sqrt_ratio_upper,
                amount0,
                amount1,
            )
        }
    }
}
