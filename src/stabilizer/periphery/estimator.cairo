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

#[starknet::contract]
pub mod estimator {
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
            println!("Initial pool price: {}", pool_price.sqrt_ratio);
            println!("Initial pool liquidity: {}", pool_liquidity);

            let (is_token1, sqrt_ratio_limit) = if input.token == pool_key.token0 {
                (false, pool_price.sqrt_ratio / 2)
            } else {
                (true, pool_price.sqrt_ratio * 2)
            };

            let sqrt_ratio_lower = tick_to_sqrt_ratio(bounds.lower);
            let sqrt_ratio_upper = tick_to_sqrt_ratio(bounds.upper);

            let input_u128: u128 = input.amount.try_into().unwrap();

            // Binary search bounds
            let mut lower: u128 = 0;
            let mut upper: u128 = input_u128;
            let mut optimal_swap_amount = input_u128 / 2;
            let mut optimal_liquidity = 0;

            // Bidirectional binary search
            for i in 0..iterations {
                println!("Iteration {}", i);
                println!("Swap amount: {}", optimal_swap_amount);
                println!("Optimal liquidity: {}", optimal_liquidity);
                // Calculate step size and test in both directions
                let step = (upper - lower) / 4; // Quarter of current range
                let test_upper = if optimal_swap_amount + step > input_u128 {
                    input_u128
                } else {
                    optimal_swap_amount + step
                };
                let test_lower = if optimal_swap_amount > step {
                    optimal_swap_amount - step
                } else {
                    0
                };

                // Test upper direction
                let swap_result_upper: SwapResult = swap_result(
                    pool_price.sqrt_ratio,
                    pool_liquidity,
                    sqrt_ratio_limit,
                    test_upper.into(),
                    is_token1,
                    fee,
                );

                let max_liquidity_upper: u128 = self
                    .get_liquidity_from_swap_result(
                        swap_result_upper,
                        input.amount,
                        sqrt_ratio_lower,
                        sqrt_ratio_upper,
                        is_token1,
                    );

                // Test lower direction
                let swap_result_lower: SwapResult = swap_result(
                    pool_price.sqrt_ratio,
                    pool_liquidity,
                    sqrt_ratio_limit,
                    test_lower.into(),
                    is_token1,
                    fee,
                );
                let max_liquidity_lower: u128 = self
                    .get_liquidity_from_swap_result(
                        swap_result_lower,
                        input.amount,
                        sqrt_ratio_lower,
                        sqrt_ratio_upper,
                        is_token1,
                    );

                // Move towards direction that improves over current optimal
                if max_liquidity_upper > optimal_liquidity
                    && max_liquidity_upper >= max_liquidity_lower {
                    lower = optimal_swap_amount;
                    optimal_swap_amount = test_upper;
                    optimal_liquidity = max_liquidity_upper;
                } else if max_liquidity_lower > optimal_liquidity {
                    upper = optimal_swap_amount;
                    optimal_swap_amount = test_lower;
                    optimal_liquidity = max_liquidity_lower;
                } else {
                    // Neither direction improves over current optimal - converge towards current
                    // optimum
                    lower = (lower + optimal_swap_amount) / 2;
                    upper = (upper + optimal_swap_amount) / 2;
                }

                if upper - lower <= MIN_LIQUIDITY_RANGE {
                    break;
                }
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
