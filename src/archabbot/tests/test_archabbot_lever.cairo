use core::num::traits::Zero;
use ekubo::interfaces::router::{RouteNode, Swap, TokenAmount};
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, IFlashBorrowerDispatcher,
    IFlashBorrowerDispatcherTrait, ISentinelDispatcherTrait, IShrineDispatcherTrait,
};
use opus::types::{AssetBalance, Health};
use opus::utils::assertions::assert_equalish;
use opus_compose::addresses::mainnet;
use opus_compose::archabbot::contracts::archabbot::archabbot as archabbot_contract;
use opus_compose::archabbot::interfaces::lever::{ILeverDispatcher, ILeverDispatcherTrait};
use opus_compose::archabbot::tests::mocks::malicious_lever::{
    IMaliciousLeverDispatcher, IMaliciousLeverDispatcherTrait,
};
use opus_compose::archabbot::tests::utils::archabbot_utils;
use opus_compose::archabbot::types::{
    LeverDownParams, LeverUpParams, ModifyLeverAction, ModifyLeverParams,
};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait,
    cheat_caller_address, declare, spy_events,
};
use starknet::{ContractAddress, SyscallResultTrait};
use wadray::{RAY_ONE, Ray, WAD_ONE, Wad};

// Helper function to open a trove with the given ETH amount.
fn lever_open_trove_helper(
    test_config: archabbot_utils::ArchabbotTestConfig, user: ContractAddress, eth_asset_amt: u128,
) -> (archabbot_utils::ArchabbotTestConfig, u64) {
    let yang = mainnet::ETH;
    let forge_amount: Wad = 1_u128.into();
    let max_forge_fee_pct: Wad = WAD_ONE.into();

    archabbot_utils::fund_user_eth(user, eth_asset_amt.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    cheat_caller_address(test_config.abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id: u64 = test_config
        .abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: eth_asset_amt }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    (test_config, trove_id)
}

// Helper function to open a trove then lever up by an amount of debt equal to
// the value of the given ETH amount.
fn lever_open_trove_and_lever_up(
    test_config: archabbot_utils::ArchabbotTestConfig, user: ContractAddress, eth_asset_amt: u128,
) -> (archabbot_utils::ArchabbotTestConfig, u64, Wad) {
    let shrine = test_config.shrine;
    let eth = mainnet::ETH;
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let (test_config, trove_id) = lever_open_trove_helper(test_config, user, eth_asset_amt);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: Wad = (eth_price * eth_asset_amt.into());

    let max_ltv: Ray = RAY_ONE.into();
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id,
        max_ltv,
        yang: eth,
        max_forge_fee_pct,
        min_asset_amount: 1,
        swaps: lever_up_swaps(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    lever.up(debt, lever_up_params);

    (test_config, trove_id, debt)
}

// Deploy a malicious lever mock that targets the archabbot's on_flash_loan
fn deploy_malicious_lever(archabbot_address: ContractAddress) -> IMaliciousLeverDispatcher {
    let malicious_lever_class = declare("malicious_lever").unwrap_syscall().contract_class();

    let calldata: Array<felt252> = array![
        mainnet::SHRINE.into(), mainnet::FLASH_MINT.into(), archabbot_address.into(),
    ];

    let (malicious_lever_addr, _) = malicious_lever_class.deploy(@calldata).unwrap_syscall();

    IMaliciousLeverDispatcher { contract_address: malicious_lever_addr }
}

// Helper function to construct the multi-multihop swaps for swapping ~6780 CASH for ETH.
// Retrieved from Ekubo's API at the time of the given block
fn lever_up_swaps() -> Array<Swap> {
    array![
        // Swap 3363 CASH for ETH via CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330736317803144455322555132694253,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::ETH,
                        token1: mainnet::USDC_E,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 22704275119776591868462473673560333,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 3363000000000000000000, sign: false },
            },
        },
        // Swap 1681.5 CASH for ETH via CASH/USDC, USDC/STRK and STRK/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330722852803238016631206569062946,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::STRK,
                        token1: mainnet::USDC_E,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 271667830685237634466192167264716,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::STRK,
                        token1: mainnet::ETH,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 3592321727052849444936006015603599237,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 1681500000000000000000, sign: false },
            },
        },
        // Swap 840.75 CASH for CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330716120714418657046702660609541,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::ETH,
                        token1: mainnet::USDC_E,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 22706680499711875562415185171564081,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 840750000000000000000, sign: false },
            },
        },
        // Swap 630.5625 CASH for ETH via CASH/USDC, USDC/STRK and STRK/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330711071827661470971123546548538,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::STRK,
                        token1: mainnet::USDC_E,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 271692175002064946752726549291357,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::STRK,
                        token1: mainnet::ETH,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 3592175465380814184112485437189674966,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 630562500000000000000, sign: false },
            },
        },
        // Swap 210.1875 CASH for CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330709388899666220664960200969123,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::ETH,
                        token1: mainnet::USDC_E,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 22707281811029300853046446933748959,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 210187500000000000000, sign: false },
            },
        },
    ]
}

// Helper function to construct the multi-multihop swaps for swapping ETH for ~6726 CASH.
// Retrieved from Ekubo's API at the time of the given block
fn lever_down_swaps() -> Array<Swap> {
    // Swap ETH for 5935.25 worth of CASH via CASH/USDC and USDC/ETH
    array![
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 347840964009677317618791081605181,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::ETH,
                        token1: mainnet::USDC_E,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 17640198316915435058123240771195958,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 5935250000000000000000, sign: true },
            },
        },
        // Swap ETH for 430.375 worth of CASH via CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 347844505678956919466190622313263,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::ETH,
                        token1: mainnet::USDC_E,
                        fee: 1020847100762815411640772995208708096,
                        tick_spacing: 5982,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 9450845647111419008121756408257958,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 430375000000000000000, sign: true },
            },
        },
        // Swap ETH for 325.28125 worth of CASH via CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 347847161978246774175281959408508,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::STRK,
                        token1: mainnet::USDC_E,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 211193410336673033217806364000717,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::STRK,
                        token1: mainnet::ETH,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 4617504752654235504522799319223086796,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 325281250000000000000, sign: true },
            },
        },
        // Swap ETH for 115.09375 worth of CASH directly
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::ETH,
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 6545527281850043152580132658722343059,
                    skip_ahead: 3,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: 115093750000000000000, sign: true },
            },
        },
    ]
}

//
// Lever test cases
//

#[test]
#[fork("MAINNET_LEVER")]
fn test_lever_up_and_down() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let abbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let mut spy = spy_events();
    let mut expected_events = array![];

    let forge_fee_pct = shrine.get_forge_fee_pct();
    let before_shrine_health = shrine.get_shrine_health();

    // Deposit 2 ETH and leverage to 4 ETH-ish
    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id, debt) = lever_open_trove_and_lever_up(
        test_config, whale, eth_capital,
    );
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert!(trove_health.debt.is_non_zero(), "lever up failed");

    assert!(shrine.is_healthy(trove_id), "trove unhealthy #1");

    let before_eth_asset_amt: u128 = abbot.get_trove_asset_balance(trove_id, eth);
    // Check that yang amount does not exceed 4 ETH equivalent
    // The actual amount is likely lower due to pessimistic oracle and slippage
    let eth_asset_amt_deposited = before_eth_asset_amt - eth_capital;
    let eth_yang_amt_deposited = test_config.sentinel.convert_to_yang(eth, eth_asset_amt_deposited);
    assert!(before_eth_asset_amt <= 4 * WAD_ONE, "yang exceeds upper limit");

    expected_events
        .append(
            (
                test_config.archabbot.contract_address,
                archabbot_contract::Event::LeverUp(
                    archabbot_contract::LeverUp {
                        user: whale, trove_id, yang: eth, amount: debt, min_asset_amount: 1,
                    },
                ),
            ),
        );
    expected_events
        .append(
            (
                test_config.archabbot.contract_address,
                archabbot_contract::Event::Deposit(
                    archabbot_contract::Deposit {
                        user: whale,
                        trove_id,
                        yang: eth,
                        yang_amt: eth_yang_amt_deposited,
                        asset_amt: eth_asset_amt_deposited,
                    },
                ),
            ),
        );

    let max_ltv: Ray = RAY_ONE.into();
    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };

    let debt_before_down = trove_health.debt;

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    lever.down(trove_health.debt, lever_down_params);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert!(trove_health.debt.is_zero(), "lever down failed");

    assert!(shrine.is_healthy(trove_id), "trove unhealthy #2");

    let after_eth_asset_amt: u128 = abbot.get_trove_asset_balance(trove_id, eth);
    let eth_balance_diff = eth_capital - after_eth_asset_amt;

    // Check that the remainder collateral was redeposited
    // after round-tripping, minus the forge fees (and negligible swap fees)
    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let expected_eth_paid_to_forge_fee = forge_fee_pct * debt / eth_price;
    let error_margin: u128 = (WAD_ONE / 100).into();
    assert_equalish(
        expected_eth_paid_to_forge_fee.into(),
        eth_balance_diff,
        error_margin,
        'wrong amount after round trip',
    );

    // Check various protocol parameters after round trip
    let after_shrine_health = shrine.get_shrine_health();
    assert_eq!(before_shrine_health.debt, after_shrine_health.debt, "Wrong total debt");

    let expected_eth_deposited_value: Wad = (eth_capital - eth_balance_diff).into() * eth_price;
    let expected_shrine_value: Wad = before_shrine_health.value + expected_eth_deposited_value;
    let error_margin: Wad = WAD_ONE.into();
    assert_equalish(
        after_shrine_health.value, expected_shrine_value, error_margin, 'Wrong total value',
    );

    expected_events
        .append(
            (
                test_config.archabbot.contract_address,
                archabbot_contract::Event::LeverDown(
                    archabbot_contract::LeverDown {
                        user: whale,
                        trove_id,
                        yang: eth,
                        amount: debt_before_down,
                        yang_asset_amount_withdrawn: before_eth_asset_amt,
                        yang_asset_amount_redeposited: after_eth_asset_amt,
                    },
                ),
            ),
        );
    expected_events
        .append(
            (
                test_config.archabbot.contract_address,
                archabbot_contract::Event::Withdraw(
                    archabbot_contract::Withdraw {
                        user: whale,
                        trove_id,
                        yang: eth,
                        yang_amt: eth_yang_amt,
                        asset_amt: before_eth_asset_amt,
                    },
                ),
            ),
        );

    let eth_yang_amt_redeposited: Wad = test_config
        .sentinel
        .convert_to_yang(eth, after_eth_asset_amt);
    expected_events
        .append(
            (
                test_config.archabbot.contract_address,
                archabbot_contract::Event::Deposit(
                    archabbot_contract::Deposit {
                        user: whale,
                        trove_id,
                        yang: eth,
                        yang_amt: eth_yang_amt_redeposited,
                        asset_amt: after_eth_asset_amt,
                    },
                ),
            ),
        );
    spy.assert_emitted(@expected_events);
}

// Similar to the test for `up` in `test_lever_up_and_down` but with a quarter the collateral
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'SH: Trove LTV > threshold')]
fn test_lever_up_unhealthy_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = WAD_ONE / 4;
    let (test_config, trove_id) = lever_open_trove_helper(test_config, whale, eth_capital);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 2;

    let max_ltv: Ray = RAY_ONE.into();
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id,
        max_ltv,
        yang: eth,
        max_forge_fee_pct,
        min_asset_amount: 1,
        swaps: lever_up_swaps(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    lever.up(debt.into(), lever_up_params);
}

// Similar to the test for `up` in `test_lever_up_and_down` but with max LTV
// set to 51.4%, whereas the default lever up params will result in
// the trove's LTV at 51.45%
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Exceeds max LTV")]
fn test_lever_up_exceeds_max_ltv_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = WAD_ONE * 2;
    let (test_config, trove_id) = lever_open_trove_helper(test_config, whale, eth_capital);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 2;

    let max_ltv: Ray = 514000000000000000000000000_u128.into();
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id,
        max_ltv,
        yang: eth,
        max_forge_fee_pct,
        min_asset_amount: 1,
        swaps: lever_up_swaps(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    lever.up(debt.into(), lever_up_params);
}

// Similar to the test for `up` in `test_lever_up_and_down`
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'CLEAR_AT_LEAST_MINIMUM')]
fn test_lever_up_below_min_asset_amount_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = WAD_ONE * 2;
    let (test_config, trove_id) = lever_open_trove_helper(test_config, whale, eth_capital);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 2;

    let max_ltv: Ray = RAY_ONE.into();
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    // Set minimum asset amount to the original capital, which is guaranteed to be
    // more than what can be swapped
    let min_asset_amount = eth_capital;
    let lever_up_params = LeverUpParams {
        trove_id, max_ltv, yang: eth, max_forge_fee_pct, min_asset_amount, swaps: lever_up_swaps(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    lever.up(debt.into(), lever_up_params);
}

// Similar to the test for `up` in `test_lever_up_and_down`
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'SH: forge_fee% > max_forge_fee%')]
fn test_lever_up_exceeds_max_forge_fee_pct_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = WAD_ONE * 2;
    let (test_config, trove_id) = lever_open_trove_helper(test_config, whale, eth_capital);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 2;

    let max_ltv: Ray = RAY_ONE.into();
    let max_forge_fee_pct: Wad = Zero::zero();
    let lever_up_params = LeverUpParams {
        trove_id,
        max_ltv,
        yang: eth,
        max_forge_fee_pct,
        min_asset_amount: 1,
        swaps: lever_up_swaps(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    lever.up(debt.into(), lever_up_params);
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_unauthorized_lever_up_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    cheat_caller_address(
        test_config.archabbot.contract_address, mainnet::WHALE, CheatSpan::TargetCalls(1),
    );
    let debt: Wad = 100_u128.into();
    let max_ltv: Ray = RAY_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id: 1,
        max_ltv,
        yang: mainnet::ETH,
        max_forge_fee_pct: WAD_ONE.into(),
        min_asset_amount: 1,
        swaps: lever_up_swaps(),
    };
    lever.up(debt, lever_up_params);
}

// No gate found in Sentinel, so approval is made to zero address
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(
    expected: (
        'ERC20: approve to 0',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
    ),
)]
fn test_lever_up_invalid_yang_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let whale = mainnet::WHALE;

    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id) = lever_open_trove_helper(test_config, whale, eth_capital);

    let swap_amount: u128 = WAD_ONE;
    let usdc_swap: Array<Swap> = array![
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::SHRINE,
                        token1: mainnet::USDC_E,
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330736317803144455322555132694253,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::SHRINE, amount: i129 { mag: swap_amount, sign: false },
            },
        },
    ];

    let invalid_yang = mainnet::USDC_E;

    let max_ltv: Ray = RAY_ONE.into();
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id,
        max_ltv,
        yang: invalid_yang,
        max_forge_fee_pct,
        min_asset_amount: 1,
        swaps: usdc_swap,
    };

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    lever.up(swap_amount.into(), lever_up_params);
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_unauthorized_lever_down_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };

    let debt: Wad = WAD_ONE.into();
    let max_ltv: Ray = RAY_ONE.into();
    let trove_id = 1;
    let lever_down_params = LeverDownParams {
        trove_id,
        max_ltv,
        yang: mainnet::ETH,
        yang_amt: 1000000000_u128.into(),
        swaps: lever_down_swaps(),
    };

    cheat_caller_address(
        test_config.archabbot.contract_address, mainnet::WHALE, CheatSpan::TargetCalls(1),
    );
    lever.down(debt, lever_down_params);
}

// Similar to the test for `down` in `test_lever_up_and_down` but with less collateral withdrawn
// such that it is insufficient to pay for the debt.
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'u256_sub Overflow')]
fn test_lever_down_unhealthy_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };
    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id, _debt) = lever_open_trove_and_lever_up(
        test_config, whale, eth_capital,
    );

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert!(trove_health.debt.is_non_zero(), "lever up failed");

    let eth_yang_amt: u128 = shrine.get_deposit(eth, trove_id).into();
    let eth_yang_amt: Wad = (eth_yang_amt / 10).into();
    let max_ltv: Ray = RAY_ONE.into();

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    lever.down(trove_health.debt, lever_down_params)
}

// Similar to the test for `down` in `test_lever_up_and_down` but we withdraw more collateral than
// the value of debt repaid so that LTV will increase, but we set the max LTV as unchanged
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Exceeds max LTV")]
fn test_lever_down_exceeds_max_ltv_fail_3() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let shrine = test_config.shrine;
    let archabbot_abbot = IAbbotDispatcher {
        contract_address: test_config.archabbot.contract_address,
    };

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = 2 * WAD_ONE;

    let (test_config, trove_id) = lever_open_trove_helper(test_config, whale, eth_capital);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    // Forge 1 ETH worth of debt such that LTV will be around 50%
    let debt = eth_price;
    let max_forge_fee_pct: Wad = WAD_ONE.into();

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    archabbot_abbot.forge(trove_id, debt, max_forge_fee_pct);

    let trove_health = shrine.get_trove_health(trove_id);
    let max_ltv: Ray = trove_health.ltv / (RAY_ONE * 2).into();

    // Remove the first swap, so total amount swapped is 790.75 CASH worth of ETH
    let mut modified_swaps = lever_down_swaps();
    let _ = modified_swaps.pop_front();

    let debt_to_repay: u128 = 790750000000000000000;

    // Remove thrice the amount of value of debt to repay so that LTV will increase
    let eth_value_to_withdraw = debt_to_repay * 3;
    let eth_yang_amt: Wad = (eth_value_to_withdraw.into() / eth_price);

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: eth, yang_amt: eth_yang_amt, swaps: modified_swaps,
    };
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };
    lever.down(debt_to_repay.into(), lever_down_params)
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'SH: Insufficient yang balance')]
fn test_lever_down_insufficient_trove_yang_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };
    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id, _debt) = lever_open_trove_and_lever_up(
        test_config, whale, eth_capital,
    );

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert!(trove_health.debt.is_non_zero(), "lever up failed");

    let eth_yang_amt: u128 = shrine.get_deposit(eth, trove_id).into();
    let eth_yang_amt: Wad = (eth_yang_amt + 1).into();
    let max_ltv: Ray = RAY_ONE.into();

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    lever.down(trove_health.debt, lever_down_params)
}

// Sentinel will catch invalid yangs
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(
    expected: (
        'SE: Yang not added',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
        'ENTRYPOINT_FAILED',
    ),
)]
fn test_lever_down_invalid_yang_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let lever = ILeverDispatcher { contract_address: test_config.archabbot.contract_address };
    let shrine = test_config.shrine;

    let whale = mainnet::WHALE;

    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id, _debt) = lever_open_trove_and_lever_up(
        test_config, whale, eth_capital,
    );

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let max_ltv: Ray = RAY_ONE.into();
    let invalid_yang = mainnet::EKUBO;
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: invalid_yang, yang_amt: Zero::zero(), swaps: lever_down_swaps(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, whale, CheatSpan::TargetCalls(1));
    lever.down(trove_health.debt, lever_down_params)
}

// Non-flash-mint caller invokes on_flash_loan callback directly
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Illegal callback")]
fn test_unauthorized_callback_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let shrine = test_config.shrine;

    let eth = mainnet::ETH;
    let whale = mainnet::WHALE;

    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id, _debt) = lever_open_trove_and_lever_up(
        test_config, whale, eth_capital,
    );

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    let max_ltv: Ray = RAY_ONE.into();
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    let modify_lever_params = ModifyLeverParams {
        user: whale, action: ModifyLeverAction::LeverDown(lever_down_params),
    };
    let mut call_data: Array<felt252> = Default::default();
    modify_lever_params.serialize(ref call_data);

    // Non-flash-mint caller calls the callback function
    cheat_caller_address(
        test_config.archabbot.contract_address, mainnet::MULTISIG, CheatSpan::TargetCalls(1),
    );
    IFlashBorrowerDispatcher { contract_address: test_config.archabbot.contract_address }
        .on_flash_loan(
            test_config.archabbot.contract_address,
            mainnet::SHRINE,
            trove_health.debt.into(),
            0_256,
            call_data.span(),
        );
}

// Flash mint calls on_flash_loan with invalid initiator
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Initiator must be Archabbot")]
fn test_invalid_initiator_in_callback_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let shrine = test_config.shrine;

    let eth = mainnet::ETH;
    let whale = mainnet::WHALE;

    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id, _debt) = lever_open_trove_and_lever_up(
        test_config, whale, eth_capital,
    );

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    let max_ltv: Ray = RAY_ONE.into();
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    let modify_lever_params = ModifyLeverParams {
        user: whale, action: ModifyLeverAction::LeverDown(lever_down_params),
    };
    let mut call_data: Array<felt252> = Default::default();
    modify_lever_params.serialize(ref call_data);

    // Flash mint calls the callback function directly with the wrong initiator.
    // This is technically impossible.
    cheat_caller_address(
        test_config.archabbot.contract_address, mainnet::FLASH_MINT, CheatSpan::TargetCalls(1),
    );
    IFlashBorrowerDispatcher { contract_address: test_config.archabbot.contract_address }
        .on_flash_loan(
            mainnet::MULTISIG, mainnet::SHRINE, trove_health.debt.into(), 0_256, call_data.span(),
        );
}

// Malicious lever contract that skips the trove owner check
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Initiator must be Archabbot")]
fn test_lever_down_malicious_lever_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let malicious_lever = deploy_malicious_lever(test_config.archabbot.contract_address);

    let archabbot_abbot = IAbbotDispatcher {
        contract_address: test_config.archabbot.contract_address,
    };
    let attacker: ContractAddress = 'attacker'.try_into().unwrap();

    let user = mainnet::WHALE;
    let eth = mainnet::ETH;

    let eth_capital: u128 = 8 * WAD_ONE;
    let (test_config, user_trove_id) = lever_open_trove_helper(test_config, user, eth_capital);

    // User creates some debt
    let user_debt = 10000 * WAD_ONE;
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot_abbot.forge(user_trove_id, user_debt.into(), WAD_ONE.into());

    let eth_to_steal: Wad = (2 * WAD_ONE).into();
    let yin_to_repay: Wad = (6726 * WAD_ONE).into();
    let max_ltv: Ray = RAY_ONE.into();

    cheat_caller_address(malicious_lever.contract_address, attacker, CheatSpan::TargetCalls(1));
    let lever_down_params = LeverDownParams {
        trove_id: user_trove_id,
        max_ltv,
        yang: eth,
        yang_amt: eth_to_steal,
        swaps: lever_down_swaps(),
    };
    malicious_lever.down(yin_to_repay, lever_down_params);
}

// Trove owner calls on_flash_loan callback directly
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "ARC: Illegal callback")]
fn test_trove_owner_callback_fail() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let shrine = test_config.shrine;

    let eth = mainnet::ETH;
    let whale = mainnet::WHALE;

    let eth_capital: u128 = 2 * WAD_ONE;
    let (test_config, trove_id, _debt) = lever_open_trove_and_lever_up(
        test_config, whale, eth_capital,
    );

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    let max_ltv: Ray = RAY_ONE.into();
    let lever_down_params = LeverDownParams {
        trove_id, max_ltv, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    let modify_lever_params = ModifyLeverParams {
        user: whale, action: ModifyLeverAction::LeverDown(lever_down_params),
    };
    let mut call_data: Array<felt252> = Default::default();
    modify_lever_params.serialize(ref call_data);

    // Trove owner calls the callback function directly but is not the flash_mint
    cheat_caller_address(
        test_config.archabbot.contract_address, mainnet::WHALE, CheatSpan::TargetCalls(1),
    );
    IFlashBorrowerDispatcher { contract_address: test_config.archabbot.contract_address }
        .on_flash_loan(
            test_config.archabbot.contract_address,
            mainnet::SHRINE,
            trove_health.debt.into(),
            0_256,
            call_data.span(),
        );
}
