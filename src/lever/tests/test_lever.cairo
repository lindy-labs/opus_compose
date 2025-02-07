use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
use core::num::traits::Zero;
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use ekubo::router_lite::{RouteNode, Swap, TokenAmount};
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, IFlashBorrowerDispatcher,
    IFlashBorrowerDispatcherTrait, IShrineDispatcher, IShrineDispatcherTrait,
};
use opus::types::{AssetBalance, Health};
use opus::utils::assert_equalish;
use opus_compose::addresses::mainnet;
use opus_compose::lever::constants::{SENTINEL_ROLES_FOR_LEVER, SHRINE_ROLES_FOR_LEVER};
use opus_compose::lever::contracts::lever::lever as lever_contract;
use opus_compose::lever::interfaces::lever::{ILeverDispatcher, ILeverDispatcherTrait};
use opus_compose::lever::types::{
    LeverUpParams, LeverDownParams, ModifyLeverAction, ModifyLeverParams,
};
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, spy_events,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use wadray::{Wad, WAD_ONE};

//
// Helpers
//

fn deploy_lever() -> ILeverDispatcher {
    let lever_class = declare("lever").unwrap().contract_class();

    let calldata: Array<felt252> = array![
        mainnet::shrine().into(),
        mainnet::sentinel().into(),
        mainnet::abbot().into(),
        mainnet::flash_mint().into(),
        mainnet::ekubo_router().into(),
    ];

    let (lever_addr, _) = lever_class.deploy(@calldata).unwrap();

    start_cheat_caller_address(mainnet::shrine(), mainnet::multisig());
    IAccessControlDispatcher { contract_address: mainnet::shrine() }
        .grant_role(SHRINE_ROLES_FOR_LEVER, lever_addr);
    stop_cheat_caller_address(mainnet::shrine());

    start_cheat_caller_address(mainnet::sentinel(), mainnet::multisig());
    IAccessControlDispatcher { contract_address: mainnet::sentinel() }
        .grant_role(SENTINEL_ROLES_FOR_LEVER, lever_addr);
    stop_cheat_caller_address(mainnet::sentinel());

    ILeverDispatcher { contract_address: lever_addr }
}

// Helper function to open a trove with 2 ETH.
// Returns the trove ID.
fn open_trove_helper(user: ContractAddress, eth_asset_amt: u128) -> u64 {
    let abbot = IAbbotDispatcher { contract_address: mainnet::abbot() };

    let eth = mainnet::eth();
    let gate = mainnet::eth_gate();

    start_cheat_caller_address(eth, user);
    IERC20Dispatcher { contract_address: eth }.approve(gate, eth_asset_amt.into());
    stop_cheat_caller_address(eth);

    start_cheat_caller_address(abbot.contract_address, user);
    let trove_id: u64 = abbot
        .open_trove(
            array![AssetBalance { address: eth, amount: eth_asset_amt }].span(),
            1_u128.into(),
            WAD_ONE.into(),
        );
    stop_cheat_caller_address(abbot.contract_address);

    trove_id
}

// Helper function to open a trove with 2 ETH, then lever up by an
// amount of debt equal to the value of 2 ETH.
// Returns a tuple of the trove ID and the amount of debt forged
fn open_trove_and_lever_up(
    lever: ILeverDispatcher, user: ContractAddress, eth_asset_amt: u128,
) -> (u64, Wad) {
    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let eth = mainnet::eth();

    let trove_id: u64 = open_trove_helper(user, eth_asset_amt);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    // ETH price is ~3,363 (Wad) in Shrine, so debt is ~6,726 (Wad)
    let debt: Wad = (eth_price * eth_asset_amt.into());

    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id, yang: eth, max_forge_fee_pct, swaps: lever_up_swaps(),
    };

    start_cheat_caller_address(lever.contract_address, user);
    lever.up(debt, lever_up_params);
    stop_cheat_caller_address(lever.contract_address);

    (trove_id, debt)
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
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330736317803144455322555132694253,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::eth(),
                        token1: mainnet::usdc(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 22704275119776591868462473673560333,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 3363000000000000000000, sign: false },
            },
        },
        // Swap 1681.5 CASH for ETH via CASH/USDC, USDC/STRK and STRK/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330722852803238016631206569062946,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::strk(),
                        token1: mainnet::usdc(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 271667830685237634466192167264716,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::strk(),
                        token1: mainnet::eth(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 3592321727052849444936006015603599237,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 1681500000000000000000, sign: false },
            },
        },
        // Swap 840.75 CASH for CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330716120714418657046702660609541,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::eth(),
                        token1: mainnet::usdc(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 22706680499711875562415185171564081,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 840750000000000000000, sign: false },
            },
        },
        // Swap 630.5625 CASH for ETH via CASH/USDC, USDC/STRK and STRK/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330711071827661470971123546548538,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::strk(),
                        token1: mainnet::usdc(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 271692175002064946752726549291357,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::strk(),
                        token1: mainnet::eth(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 3592175465380814184112485437189674966,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 630562500000000000000, sign: false },
            },
        },
        // Swap 210.1875 CASH for CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 330709388899666220664960200969123,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::eth(),
                        token1: mainnet::usdc(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 22707281811029300853046446933748959,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 210187500000000000000, sign: false },
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
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 347840964009677317618791081605181,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::eth(),
                        token1: mainnet::usdc(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 17640198316915435058123240771195958,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 5935250000000000000000, sign: true },
            },
        },
        // Swap ETH for 430.375 worth of CASH via CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 347844505678956919466190622313263,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::eth(),
                        token1: mainnet::usdc(),
                        fee: 1020847100762815411640772995208708096,
                        tick_spacing: 5982,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 9450845647111419008121756408257958,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 430375000000000000000, sign: true },
            },
        },
        // Swap ETH for 325.28125 worth of CASH via CASH/USDC and USDC/ETH
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::shrine(),
                        token1: mainnet::usdc(),
                        fee: 34028236692093847977029636859101184,
                        tick_spacing: 200,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 347847161978246774175281959408508,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::strk(),
                        token1: mainnet::usdc(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 211193410336673033217806364000717,
                    skip_ahead: 0,
                },
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::strk(),
                        token1: mainnet::eth(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 4617504752654235504522799319223086796,
                    skip_ahead: 0,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 325281250000000000000, sign: true },
            },
        },
        // Swap ETH for 115.09375 worth of CASH directly
        Swap {
            route: array![
                RouteNode {
                    pool_key: PoolKey {
                        token0: mainnet::shrine(),
                        token1: mainnet::eth(),
                        fee: 170141183460469235273462165868118016,
                        tick_spacing: 1000,
                        extension: Zero::zero(),
                    },
                    sqrt_ratio_limit: 6545527281850043152580132658722343059,
                    skip_ahead: 3,
                },
            ],
            token_amount: TokenAmount {
                token: mainnet::shrine(), amount: i129 { mag: 115093750000000000000, sign: true },
            },
        },
    ]
}

//
// Tests
//

#[test]
#[fork("MAINNET_LEVER")]
fn test_lever() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let whale = mainnet::whale();
    let eth = mainnet::eth();
    let eth_erc20 = IERC20Dispatcher { contract_address: eth };

    let mut spy = spy_events();
    let mut expected_events = array![];

    let forge_fee_pct = shrine.get_forge_fee_pct();
    let before_eth_balance = eth_erc20.balanceOf(whale);
    let before_shrine_health = shrine.get_shrine_health();

    let before_up_eth_gate_balance = eth_erc20.balanceOf(mainnet::eth_gate());

    // Deposit 2 ETH and leverage to 4 ETH-ish
    let eth_capital: u128 = 2 * WAD_ONE;
    let (trove_id, debt) = open_trove_and_lever_up(lever, whale, eth_capital);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_non_zero(), 'lever up failed');

    assert(shrine.is_healthy(trove_id), 'trove unhealthy #1');

    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    // Check that yang amount does not exceed 4 ETH equivalent
    // The actual amount is likely lower due to pessimistic oracle and slippage
    assert(eth_yang_amt <= (4 * WAD_ONE).into(), 'yang exceeds upper limit');

    let expected_eth_yang_amt = eth_yang_amt - eth_capital.into();
    expected_events
        .append(
            (
                lever.contract_address,
                lever_contract::Event::LeverDeposit(
                    lever_contract::LeverDeposit {
                        user: whale,
                        trove_id,
                        yang: eth,
                        yang_amt: expected_eth_yang_amt,
                        // Should correspond 1:1 at the prevailing conversion rate
                        asset_amt: expected_eth_yang_amt.into(),
                    },
                ),
            ),
        );

    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };

    start_cheat_caller_address(lever.contract_address, whale);
    lever.down(trove_health.debt, lever_down_params);
    stop_cheat_caller_address(lever.contract_address);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_zero(), 'lever down failed');
    assert(trove_health.value.is_zero(), 'incorrect value');

    assert(shrine.get_deposit(eth, trove_id).is_zero(), 'incorrect yang amt');

    assert(shrine.is_healthy(trove_id), 'trove unhealthy #2');

    let after_eth_balance = eth_erc20.balanceOf(whale);
    let eth_balance_diff = before_eth_balance - after_eth_balance;

    // Check that the caller received the original deposited collateral
    // after round-tripping, minus the forge fees
    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let expected_eth_paid_to_forge_fee = forge_fee_pct * debt / eth_price;
    let error_margin: u256 = (WAD_ONE / 100).into();
    assert_equalish(
        expected_eth_paid_to_forge_fee.into(),
        eth_balance_diff,
        error_margin,
        'wrong amount after round trip',
    );

    // Check various protocol parameters after round trip
    let after_shrine_health = shrine.get_shrine_health();
    assert_eq!(before_shrine_health.debt, after_shrine_health.debt, "Wrong total debt");
    assert_eq!(before_shrine_health.value, after_shrine_health.value, "Wrong total value");

    let after_down_eth_gate_balance = eth_erc20.balanceOf(mainnet::eth_gate());
    assert_eq!(before_up_eth_gate_balance, after_down_eth_gate_balance, "Wrong gate balance");

    expected_events
        .append(
            (
                lever.contract_address,
                lever_contract::Event::LeverWithdraw(
                    lever_contract::LeverWithdraw {
                        user: whale,
                        trove_id,
                        yang: eth,
                        yang_amt: eth_yang_amt,
                        // Should correspond 1:1 at the prevailing conversion rate
                        asset_amt: eth_yang_amt.into(),
                    },
                ),
            ),
        );
    spy.assert_emitted(@expected_events);
}

// Similar to the test for `up` in `test_lever` but with a quarter the collateral
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'SH: Trove LTV > threshold')]
fn test_lever_up_unhealthy_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let whale = mainnet::whale();
    let eth = mainnet::eth();

    let eth_capital: u128 = (WAD_ONE / 4);
    let trove_id: u64 = open_trove_helper(whale, eth_capital);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 2;

    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id, yang: eth, max_forge_fee_pct, swaps: lever_up_swaps(),
    };

    start_cheat_caller_address(lever.contract_address, whale);
    lever.up(debt.into(), lever_up_params);
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "LEV: Not trove owner")]
fn test_unauthorized_lever_up_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    let debt: Wad = 100_u128.into();
    let lever_up_params = LeverUpParams {
        trove_id: 1,
        yang: mainnet::eth(),
        max_forge_fee_pct: WAD_ONE.into(),
        swaps: lever_up_swaps(),
    };
    lever.up(debt, lever_up_params);
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "LEV: Invalid yang")]
fn test_lever_up_invalid_yang_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let whale = mainnet::whale();

    let eth_capital: u128 = 2 * WAD_ONE;
    let trove_id: u64 = open_trove_helper(whale, eth_capital);

    let debt: u128 = WAD_ONE.into();
    let invalid_yang = mainnet::ekubo();
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id, yang: invalid_yang, max_forge_fee_pct, swaps: lever_up_swaps(),
    };

    start_cheat_caller_address(lever.contract_address, whale);
    lever.up(debt.into(), lever_up_params);
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "LEV: Not trove owner")]
fn test_unauthorized_lever_down_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let debt: Wad = WAD_ONE.into();
    let trove_id = 1;
    let lever_down_params = LeverDownParams {
        trove_id, yang: mainnet::eth(), yang_amt: 1000000000_u128.into(), swaps: lever_down_swaps(),
    };

    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    lever.down(debt, lever_down_params);
}

// Similar to the test for `down` in `test_lever` but with less collateral withdrawn
// such that it is insufficient to pay for the debt.
#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'u256_sub Overflow')]
fn test_lever_down_unhealthy_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let whale = mainnet::whale();
    let eth = mainnet::eth();

    let eth_capital: u128 = 2 * WAD_ONE;
    let (trove_id, _debt) = open_trove_and_lever_up(lever, whale, eth_capital);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_non_zero(), 'lever up failed');

    let eth_yang_amt: u128 = shrine.get_deposit(eth, trove_id).into();
    let eth_yang_amt: Wad = (eth_yang_amt / 10).into();

    start_cheat_caller_address(lever.contract_address, whale);
    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    lever.down(trove_health.debt, lever_down_params)
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'SH: Insufficient yang balance')]
fn test_lever_down_insufficient_trove_yang_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let whale = mainnet::whale();
    let eth = mainnet::eth();

    let eth_capital: u128 = 2 * WAD_ONE;
    let (trove_id, _debt) = open_trove_and_lever_up(lever, whale, eth_capital);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_non_zero(), 'lever up failed');

    let eth_yang_amt: u128 = shrine.get_deposit(eth, trove_id).into();
    let eth_yang_amt: Wad = (eth_yang_amt + 1).into();

    start_cheat_caller_address(lever.contract_address, whale);
    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    lever.down(trove_health.debt, lever_down_params)
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "LEV: Invalid yang")]
fn test_lever_down_invalid_yang_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let whale = mainnet::whale();

    let eth_capital: u128 = 2 * WAD_ONE;
    let (trove_id, _debt) = open_trove_and_lever_up(lever, whale, eth_capital);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let invalid_yang = mainnet::ekubo();
    let lever_down_params = LeverDownParams {
        trove_id, yang: invalid_yang, yang_amt: Zero::zero(), swaps: lever_down_swaps(),
    };

    start_cheat_caller_address(lever.contract_address, whale);
    lever.down(trove_health.debt, lever_down_params)
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "LEV: Not trove owner")]
fn test_unauthorized_callback_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let eth = mainnet::eth();
    let whale = mainnet::whale();

    let eth_capital: u128 = 2 * WAD_ONE;
    let (trove_id, _debt) = open_trove_and_lever_up(lever, whale, eth_capital);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    let modify_lever_params = ModifyLeverParams {
        user: whale, action: ModifyLeverAction::LeverDown(lever_down_params),
    };
    let mut call_data: Array<felt252> = Default::default();
    modify_lever_params.serialize(ref call_data);

    // Non-trove owner calls the callback function
    start_cheat_caller_address(lever.contract_address, mainnet::multisig());
    IFlashBorrowerDispatcher { contract_address: lever.contract_address }
        .on_flash_loan(
            lever.contract_address,
            mainnet::shrine(),
            trove_health.debt.into(),
            0_256,
            call_data.span(),
        );
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: "LEV: Initiator must be lever")]
fn test_invalid_initiator_in_callback_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let eth = mainnet::eth();
    let whale = mainnet::whale();

    let eth_capital: u128 = 2 * WAD_ONE;
    let (trove_id, _debt) = open_trove_and_lever_up(lever, whale, eth_capital);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    let modify_lever_params = ModifyLeverParams {
        user: whale, action: ModifyLeverAction::LeverDown(lever_down_params),
    };
    let mut call_data: Array<felt252> = Default::default();
    modify_lever_params.serialize(ref call_data);

    // Trove owner calls the callback function directly with the wrong initiator
    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    IFlashBorrowerDispatcher { contract_address: lever.contract_address }
        .on_flash_loan(
            mainnet::multisig(),
            mainnet::shrine(),
            trove_health.debt.into(),
            0_256,
            call_data.span(),
        );
}

#[test]
#[fork("MAINNET_LEVER")]
#[should_panic(expected: 'SH: Insufficient yin balance')]
fn test_trove_owner_callback() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };

    let eth = mainnet::eth();
    let whale = mainnet::whale();

    let eth_capital: u128 = 2 * WAD_ONE;
    let (trove_id, _debt) = open_trove_and_lever_up(lever, whale, eth_capital);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    let eth_yang_amt: Wad = shrine.get_deposit(eth, trove_id);
    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps(),
    };
    let modify_lever_params = ModifyLeverParams {
        user: whale, action: ModifyLeverAction::LeverDown(lever_down_params),
    };
    let mut call_data: Array<felt252> = Default::default();
    modify_lever_params.serialize(ref call_data);

    // Trove owner calls the callback function directly with the wrong initiator
    // but it has insufficient yin
    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    IFlashBorrowerDispatcher { contract_address: lever.contract_address }
        .on_flash_loan(
            lever.contract_address,
            mainnet::shrine(),
            trove_health.debt.into(),
            0_256,
            call_data.span(),
        );
}
