use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
use core::num::traits::Zero;
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use ekubo::router_lite::{RouteNode, Swap, TokenAmount};
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, ISentinelDispatcher, ISentinelDispatcherTrait,
    IShrineDispatcher, IShrineDispatcherTrait
};
use opus::types::{AssetBalance, Health, YangBalance};
use opus_lever::addresses::mainnet;
use opus_lever::interface::{ILeverDispatcher, ILeverDispatcherTrait};
use opus_lever::types::{LeverUpParams, LeverDownParams};
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    stop_cheat_caller_address
};
use wadray::{Wad, WAD_ONE};

// Forge, deposit and withdraw
const SHRINE_ROLES_FOR_LEVER: u128 = 8 + 32 + 524288;

// Enter and exit
const SENTINEL_ROLES_FOR_LEVER: u128 = 2 + 4;


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

#[test]
#[fork("MAINNET")]
fn test_lever() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };
    let sentinel = ISentinelDispatcher { contract_address: mainnet::sentinel() };
    let abbot = IAbbotDispatcher { contract_address: mainnet::abbot() };

    let whale = mainnet::whale();
    let eth = mainnet::eth();

    // Deposit 2 ETH and leverage to 4 ETH-ish
    let eth_capital: u128 = 2 * WAD_ONE;
    start_cheat_caller_address(eth, whale);
    IERC20Dispatcher { contract_address: eth }.approve(mainnet::eth_gate(), eth_capital.into());
    stop_cheat_caller_address(eth);

    start_cheat_caller_address(abbot.contract_address, whale);
    let trove_id: u64 = abbot
        .open_trove(
            array![AssetBalance { address: eth, amount: eth_capital }].span(),
            1_u128.into(),
            WAD_ONE.into(),
        );
    stop_cheat_caller_address(abbot.contract_address);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    // ETH price is ~3,363 (Wad) in Shrine, so debt is ~6,726 (Wad)
    let debt: u128 = eth_price.into() * 2;

    start_cheat_caller_address(lever.contract_address, whale);
    let max_forge_fee_pct: Wad = WAD_ONE.into();

    let lever_up_params = LeverUpParams {
        trove_id, yang: eth, max_forge_fee_pct, swaps: lever_up_swaps()
    };

    lever.up(debt.into(), lever_up_params);
    stop_cheat_caller_address(lever.contract_address);
    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_non_zero(), 'lever up failed');

    assert(shrine.is_healthy(trove_id), 'trove unhealthy #1');

    let eth_yang_id: u32 = 1;
    // sanity check
    assert_eq!(eth, sentinel.get_yang(eth_yang_id), "wrong yang id for eth");

    let mut trove_deposits: Span<YangBalance> = shrine.get_trove_deposits(trove_id);
    let mut eth_yang_amt: Wad = Default::default();
    loop {
        match trove_deposits.pop_front() {
            Option::Some(yang_balance) => {
                if *yang_balance.yang_id == eth_yang_id {
                    eth_yang_amt = *yang_balance.amount;
                    // Check that yang amount does not exceed 4 ETH equivalent
                    // The actual amount is likely lower due to pessimistic oracle and
                    // slippage
                    assert(
                        *yang_balance.amount <= (4 * WAD_ONE).into(), 'yang exceeds upper limit'
                    );
                } else {
                    continue;
                }
            },
            Option::None => { break; },
        };
    };

    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps()
    };

    start_cheat_caller_address(lever.contract_address, whale);
    lever.down(trove_health.debt, lever_down_params);
    stop_cheat_caller_address(lever.contract_address);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_zero(), 'lever down failed');
    assert(trove_health.value.is_zero(), 'incorrect value');

    let mut trove_deposits: Span<YangBalance> = shrine.get_trove_deposits(trove_id);
    loop {
        match trove_deposits.pop_front() {
            Option::Some(yang_balance) => {
                assert((*yang_balance.amount).is_zero(), 'incorrect yang amt');
            },
            Option::None => { break; },
        };
    };

    assert(shrine.is_healthy(trove_id), 'trove unhealthy #2');
}

// Similar to the test for `up` in `test_lever` but with a quarter the collateral
#[test]
#[fork("MAINNET")]
#[should_panic(expected: 'SH: Trove LTV > threshold')]
fn test_lever_up_unhealthy_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };
    let abbot = IAbbotDispatcher { contract_address: mainnet::abbot() };

    let whale = mainnet::whale();
    let eth = mainnet::eth();

    let eth_capital: u128 = (WAD_ONE / 4);
    start_cheat_caller_address(eth, whale);
    IERC20Dispatcher { contract_address: eth }.approve(mainnet::eth_gate(), eth_capital.into());
    stop_cheat_caller_address(eth);

    start_cheat_caller_address(abbot.contract_address, whale);
    let trove_id: u64 = abbot
        .open_trove(
            array![AssetBalance { address: eth, amount: eth_capital }].span(),
            1_u128.into(),
            WAD_ONE.into(),
        );

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 2;

    start_cheat_caller_address(lever.contract_address, whale);
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id, yang: eth, max_forge_fee_pct, swaps: lever_up_swaps()
    };
    lever.up(debt.into(), lever_up_params);
}

// Similar to the test for `down` in `test_lever` but with less collateral withdrawn
// such that it is insufficient to pay for the debt.
#[test]
#[fork("MAINNET")]
#[should_panic(expected: 'u256_sub Overflow')]
fn test_lever_down_unhealthy_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };
    let sentinel = ISentinelDispatcher { contract_address: mainnet::sentinel() };
    let abbot = IAbbotDispatcher { contract_address: mainnet::abbot() };

    let whale = mainnet::whale();
    let eth = mainnet::eth();

    let eth_capital: u128 = 2 * WAD_ONE;
    start_cheat_caller_address(eth, whale);
    IERC20Dispatcher { contract_address: eth }.approve(mainnet::eth_gate(), eth_capital.into());
    stop_cheat_caller_address(eth);

    start_cheat_caller_address(abbot.contract_address, whale);
    let trove_id: u64 = abbot
        .open_trove(
            array![AssetBalance { address: eth, amount: eth_capital }].span(),
            1_u128.into(),
            WAD_ONE.into(),
        );
    stop_cheat_caller_address(abbot.contract_address);

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 2;

    start_cheat_caller_address(lever.contract_address, whale);
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    let lever_up_params = LeverUpParams {
        trove_id, yang: eth, max_forge_fee_pct, swaps: lever_up_swaps()
    };
    lever.up(debt.into(), lever_up_params);
    stop_cheat_caller_address(lever.contract_address);

    let trove_health: Health = shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_non_zero(), 'lever up failed');

    let eth_yang_id: u32 = 1;
    // sanity check
    assert_eq!(eth, sentinel.get_yang(eth_yang_id), "wrong yang id for eth");

    let mut trove_deposits: Span<YangBalance> = shrine.get_trove_deposits(trove_id);
    let mut eth_yang_amt: Wad = Default::default();
    loop {
        match trove_deposits.pop_front() {
            Option::Some(yang_balance) => {
                if *yang_balance.yang_id == eth_yang_id {
                    let eth_yang_amt_u128: u128 = (*yang_balance.amount).into();
                    eth_yang_amt = (eth_yang_amt_u128 / 10).into();
                } else {
                    continue;
                }
            },
            Option::None => { break; },
        };
    };

    start_cheat_caller_address(lever.contract_address, whale);
    let lever_down_params = LeverDownParams {
        trove_id, yang: eth, yang_amt: eth_yang_amt, swaps: lever_down_swaps()
    };
    lever.down(trove_health.debt, lever_down_params)
}

#[test]
#[fork("MAINNET")]
#[should_panic(expected: 'LEV: Not trove owner')]
fn test_unauthorized_lever_up_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    let debt: Wad = 100_u128.into();
    let lever_up_params = LeverUpParams {
        trove_id: 1,
        yang: mainnet::eth(),
        max_forge_fee_pct: WAD_ONE.into(),
        swaps: lever_up_swaps()
    };
    lever.up(debt, lever_up_params);
}

#[test]
#[fork("MAINNET")]
#[should_panic(expected: 'LEV: Not trove owner')]
fn test_unauthorized_lever_down_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    let debt: Wad = WAD_ONE.into();
    let lever_down_params = LeverDownParams {
        trove_id: 1,
        yang: mainnet::eth(),
        yang_amt: 1000000000_u128.into(),
        swaps: lever_down_swaps()
    };
    lever.down(debt, lever_down_params);
}
