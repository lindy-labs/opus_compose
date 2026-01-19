use core::num::traits::Zero;
use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use ekubo::interfaces::positions::{
    GetTokenInfoResult, IPositionsDispatcher, IPositionsDispatcherTrait,
};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::bounds::Bounds;
use ekubo::types::delta::Delta;
use ekubo::types::keys::PoolKey;
use opus_compose::addresses::mainnet;
use opus_compose::stabilizer::constants::{LOWER_TICK_MAG, UPPER_TICK_MAG};
use opus_compose::stabilizer::periphery::estimator::{
    IEstimatorDispatcher, IEstimatorDispatcherTrait,
};
use snforge_std::{CheatSpan, ContractClassTrait, DeclareResultTrait, cheat_caller_address, declare};
use starknet::ContractAddress;
use wadray::WAD_ONE;

const MAX_ITERATIONS: u8 = 20;
const USDC_SCALE: u128 = 1000000;

const INPUT_AMT: u128 = 10;
const CASH_INPUT_AMT: u128 = INPUT_AMT * WAD_ONE;
const USDC_INPUT_AMT: u128 = INPUT_AMT * USDC_SCALE;

//
// Helpers
//

fn deploy_estimator() -> IEstimatorDispatcher {
    let estimator_class = declare("estimator").unwrap().contract_class();
    let calldata: Array<felt252> = array![mainnet::EKUBO_CORE.into()];
    let (estimator_addr, _) = estimator_class.deploy(@calldata).unwrap();

    IEstimatorDispatcher { contract_address: estimator_addr }
}

#[test]
#[fork("MAINNET_LATEST")]
#[test_case(mainnet::MULTISIG, mainnet::SHRINE, CASH_INPUT_AMT)]
#[test_case(mainnet::USDC_WHALE, mainnet::USDC, USDC_INPUT_AMT)]
fn test_estimator(user: ContractAddress, token: ContractAddress, input_amt: u128) {
    let estimator = deploy_estimator();
    let cash = mainnet::SHRINE;
    println!("Deployed estimator");

    let pool_key = PoolKey {
        token0: mainnet::USDC,
        token1: cash,
        fee: 6805647338418769825990228293189632,
        tick_spacing: 20,
        extension: Zero::zero(),
    };

    // Values are flipped because native USDC is token0 while bridged USDC was token1
    let bounds = Bounds { lower: UPPER_TICK_MAG.into(), upper: LOWER_TICK_MAG.into() };

    let input = TokenAmount { token, amount: input_amt.into() };

    println!("Fetching estimate");
    let (swap_amount, estimated_liquidity) = estimator
        .get_optimal_swap_amount(pool_key, bounds, input, MAX_ITERATIONS);
    println!("Amount to swap: {}", swap_amount);

    let token_erc20 = IERC20Dispatcher { contract_address: token };
    let other_token = if token == cash {
        mainnet::USDC
    } else {
        cash
    };
    let other_token_erc20 = IERC20Dispatcher { contract_address: other_token };

    cheat_caller_address(token, user, CheatSpan::TargetCalls(1));
    token_erc20.transfer(mainnet::EKUBO_ROUTER, swap_amount.into());

    let ekubo_core = ICoreDispatcher { contract_address: mainnet::EKUBO_CORE };
    let pool_price = ekubo_core.get_pool_price(pool_key);

    let sqrt_ratio_limit = if pool_key.token0 == input.token {
        pool_price.sqrt_ratio / 2
    } else {
        pool_price.sqrt_ratio * 2
    };

    let route_node = RouteNode { pool_key, sqrt_ratio_limit, skip_ahead: 0 };

    let router = IRouterDispatcher { contract_address: mainnet::EKUBO_ROUTER };
    cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
    println!("Swapping");
    let delta: Delta = router.swap(route_node, TokenAmount { token, amount: swap_amount.into() });
    println!("Swapped");

    let router_clear = IClearDispatcher { contract_address: mainnet::EKUBO_ROUTER };
    cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(2));
    router_clear.clear(token_erc20);
    router_clear.clear(other_token_erc20);
    println!("Swap delta a0: {}", delta.amount0);
    println!("Swap delta a1: {}", delta.amount1);

    let (token_remaining, other_token_purchased) = if token == cash {
        (input_amt.into() - delta.amount1.mag.into(), delta.amount0.mag.into())
    } else {
        (input_amt.into() - delta.amount0.mag.into(), delta.amount1.mag.into())
    };

    cheat_caller_address(token, user, CheatSpan::TargetCalls(1));
    token_erc20.transfer(mainnet::EKUBO_POSITIONS, token_remaining);
    cheat_caller_address(other_token, user, CheatSpan::TargetCalls(1));
    other_token_erc20.transfer(mainnet::EKUBO_POSITIONS, other_token_purchased);

    let ekubo_positions = IPositionsDispatcher { contract_address: mainnet::EKUBO_POSITIONS };
    let min_liquidity = (estimated_liquidity / 10) * 9;
    let (position_id, liquidity, usdc_refunded, cash_refunded) = ekubo_positions
        .mint_and_deposit_and_clear_both(pool_key, bounds, min_liquidity);
    println!("Liquidity provided: {}", liquidity);
    println!("CASH refunded: {}", cash_refunded);
    println!("USDC refunded: {}", usdc_refunded);

    let token_info: GetTokenInfoResult = ekubo_positions
        .get_token_info(position_id, pool_key, bounds);
    println!("Position amount0: {}", token_info.amount0);
    println!("Position amount1: {}", token_info.amount1);
}

