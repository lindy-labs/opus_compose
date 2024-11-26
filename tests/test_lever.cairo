use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
use core::num::traits::Zero;
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, ISentinelDispatcher, ISentinelDispatcherTrait,
    IShrineDispatcher, IShrineDispatcherTrait
};
use opus::types::{AssetBalance, Health, YangBalance};
use opus_lever::addresses::mainnet;
use opus_lever::interface::{ILeverDispatcher, ILeverDispatcherTrait};
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
        mainnet::ekubo_core().into(),
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
    let debt: u128 = eth_price.into() * 2;

    start_cheat_caller_address(lever.contract_address, whale);
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    lever.up(trove_id, debt.into(), eth, max_forge_fee_pct);
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

    start_cheat_caller_address(lever.contract_address, whale);
    lever.down(trove_id, trove_health.debt, eth, eth_yang_amt);
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


// Similar to the test for `up` in `test_lever` but with more debt
#[test]
#[fork("MAINNET")]
#[should_panic(expected: 'SH: Trove LTV > threshold')]
fn test_lever_up_unhealthy_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    let shrine = IShrineDispatcher { contract_address: mainnet::shrine() };
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

    let (eth_price, _, _) = shrine.get_current_yang_price(eth);
    let debt: u128 = eth_price.into() * 10;

    start_cheat_caller_address(lever.contract_address, whale);
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    lever.up(trove_id, debt.into(), eth, max_forge_fee_pct);
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
    lever.up(trove_id, debt.into(), eth, max_forge_fee_pct);
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
    lever.down(trove_id, trove_health.debt, eth, eth_yang_amt);
}


#[test]
#[fork("MAINNET")]
#[should_panic(expected: 'LEV: Not trove owner')]
fn test_unauthorized_lever_up_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    let trove_id: u64 = 1;
    let debt: Wad = 100_u128.into();
    let max_forge_fee_pct: Wad = WAD_ONE.into();
    lever.up(trove_id, debt, mainnet::eth(), max_forge_fee_pct);
}


#[test]
#[fork("MAINNET")]
#[should_panic(expected: 'LEV: Not trove owner')]
fn test_unauthorized_lever_down_fail() {
    let lever: ILeverDispatcher = deploy_lever();

    start_cheat_caller_address(lever.contract_address, mainnet::whale());
    let trove_id: u64 = 1;
    let debt: Wad = WAD_ONE.into();
    let yang_amt: Wad = 1000000000_u128.into();
    lever.up(trove_id, debt, mainnet::eth(), yang_amt);
}
