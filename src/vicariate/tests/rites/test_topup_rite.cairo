use core::num::traits::Zero;
use opus::interfaces::IAbbotDispatcher;
use opus_compose::addresses::mainnet;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use opus_compose::shared::components::src5::{ISRC5Dispatcher, ISRC5DispatcherTrait};
use opus_compose::vicariate::contracts::rites::topup::constants::MAX_SLIPPAGE;
use opus_compose::vicariate::contracts::rites::topup::topup_rite::{
    ITopupRiteDispatcher, ITopupRiteDispatcherTrait, topup_rite as topup_rite_contract
};
use opus_compose::vicariate::contracts::rites::topup::types::{TopupConditions, TopupConfig};
use opus_compose::vicariate::contracts::rites::types::EkuboPoolParams;
use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
use opus_compose::vicariate::interfaces::rite::{IRiteDispatcher, IRiteDispatcherTrait, IRITE_ID};
use opus_compose::vicariate::tests::utils::prior_utils;
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait,
    cheat_caller_address, declare, spy_events,
};
use starknet::ContractAddress;
use wadray::{RAY_PERCENT, Ray, WAD_ONE};


//
// Helpers 
//

fn deploy_topup_rite(prior_address: ContractAddress) -> ContractAddress {
    let topup_class = declare("topup_rite").unwrap().contract_class();
    let calldata: Array<felt252> = array![
        mainnet::SHRINE.into(), // yin (CASH = Shrine address)
        prior_address.into(),
        mainnet::EKUBO_ROUTER.into(),
        mainnet::EKUBO_CORE.into(),
    ];
    let (rite_addr, _) = topup_class.deploy(@calldata).expect('topup deploy fail');
    rite_addr
}

fn default_pool_params() -> EkuboPoolParams {
    EkuboPoolParams { fee: 0, tick_spacing: 0, extension: Zero::zero() }
}

fn default_topup_config(destination: ContractAddress) -> TopupConfig {
    TopupConfig {
        asset: mainnet::SHRINE,
        pool_params: default_pool_params(),
        conditions: TopupConditions {
            min_asset_balance: 5 * WAD_ONE,
            slippage: RAY_PERCENT.into(),
        },
        topup_amount: 10 * WAD_ONE,
        destination,
    }
}

fn serialize_config(config: TopupConfig) -> Span<felt252> {
    let mut serialized: Array<felt252> = Default::default();
    config.serialize(ref serialized);
    serialized.span()
}

// Open a trove via Prior, deploy a topup rite, and attach it.
fn setup_trove_with_topup_rite()
-> (IPriorDispatcher, u64, ContractAddress) {
    let test_config = prior_utils::prior_deploy(None);
    let user = prior_utils::USER;

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id = prior_utils::open_trove_for_user(prior_abbot, user);

    let rite_addr = deploy_topup_rite(test_config.prior.contract_address);

    // Attach rite to trove
    cheat_caller_address(
        test_config.prior.contract_address, user, CheatSpan::TargetCalls(1),
    );
    test_config.prior.set_rite(trove_id, rite_addr);

    (test_config.prior, trove_id, rite_addr)
}

//
// Tests
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_topup_rite_constructor() {
    let test_config = prior_utils::prior_deploy(None);
    let rite_addr = deploy_topup_rite(test_config.prior.contract_address);
    let rite = IRiteDispatcher { contract_address: rite_addr };

    assert!(rite.get_rite_id() == "TOPUP", "wrong rite id");
    assert!(ISRC5Dispatcher { contract_address: rite_addr }.supports_interface(IRITE_ID), "Rite SRC5 ID not supported");
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_set_trove_config_cash_asset_success() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let asset = mainnet::SHRINE;
    let topup_amount: u128 = 10 * WAD_ONE;
    let min_asset_balance: u128 = 5 * WAD_ONE;
    let slippage: Ray = RAY_PERCENT.into();
    let destination = user;
    let config = default_topup_config(user);

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    // Verify stored config
    let stored_span = rite.get_trove_config(trove_id);
    let mut stored_iter = stored_span;
    let stored: TopupConfig = Serde::<TopupConfig>::deserialize(ref stored_iter).unwrap();
    assert!(stored.asset == asset, "asset mismatch");
    assert!(stored.topup_amount == topup_amount, "topup amt mismatch");
    assert!(stored.destination == destination, "dest mismatch");
    assert!(stored.conditions.min_asset_balance == min_asset_balance, "min asset balance mismatch");
    assert!(stored.conditions.slippage == slippage, "slippage mismatch");
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_set_trove_config_disable_topup() {
    let (prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let mut spy = spy_events();

    // First set a valid config
    let mut config = default_topup_config(user);
    let cash = IERC20Dispatcher { contract_address: mainnet::SHRINE };
    let user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();
    config.conditions.min_asset_balance = user_cash_balance - 1;

    cheat_caller_address(prior.contract_address, user, CheatSpan::TargetCalls(1));
    prior.set_rite(trove_id, rite_addr);

    assert_eq!(prior.get_rite(trove_id), rite_addr, "Rite not set");

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));


    spy.assert_emitted(
        @array![
            (
                rite_addr,
                topup_rite_contract::Event::TopupConfigUpdated(topup_rite_contract::TopupConfigUpdated {
                    user,
                    trove_id,
                    config,
                }),
            ),
        ],
    );

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    assert!(!prior.can_execute_rite(trove_id), "Rite should not be ready");
    assert!(!rite.is_ready(trove_id), "Rite should not be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended");

    config.conditions.min_asset_balance = user_cash_balance + 1;

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    assert_eq!(prior.get_rite(trove_id), rite_addr, "Rite not set");
    assert!(prior.can_execute_rite(trove_id), "Rite should be ready");
    assert!(rite.is_ready(trove_id), "Rite should be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should not ended");

    // Disable by setting topup_amount to 0
    config.topup_amount = 0;
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    let stored_span = rite.get_trove_config(trove_id);
    let mut stored_iter = stored_span;
    let stored: TopupConfig = Serde::<TopupConfig>::deserialize(ref stored_iter).unwrap();
    assert!(stored.topup_amount.is_zero(), "should be zero");

    assert!(!prior.can_execute_rite(trove_id), "Rite should not be ready #3");
    assert!(!rite.is_ready(trove_id), "Rite should not be ready #4");
    assert!(rite.has_ended(trove_id), "Rite should have ended");
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_set_trove_config_max_slippage() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        conditions: TopupConditions { slippage: MAX_SLIPPAGE.into(), ..default_topup_config(user).conditions },
        ..default_topup_config(user)
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    let stored_span = rite.get_trove_config(trove_id);
    let mut stored_iter = stored_span;
    let stored: TopupConfig = Serde::<TopupConfig>::deserialize(ref stored_iter).unwrap();
    let stored_slippage: u128 = stored.conditions.slippage.into();
    assert(stored_slippage == MAX_SLIPPAGE, 'slippage should be max');
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Slippage out of acceptable range")]
fn test_set_trove_config_zero_slippage_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        conditions: TopupConditions { slippage: Zero::zero(), ..default_topup_config(user).conditions },
        ..default_topup_config(user)
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Slippage out of acceptable range")]
fn test_set_trove_config_slippage_exceeds_max_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        conditions: TopupConditions {
            slippage: (MAX_SLIPPAGE + 1).into(),
            ..default_topup_config(user).conditions
        },
        ..default_topup_config(user)
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Not owner")]
fn test_set_trove_config_not_owner_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(prior_utils::BAD_GUY);

    cheat_caller_address(rite_addr, prior_utils::BAD_GUY, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Invalid asset")]
fn test_set_trove_config_zero_asset_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig { asset: Zero::zero(), ..default_topup_config(user) };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Invalid pool params")]
fn test_set_trove_config_no_swap_path_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        asset: mainnet::USDC,
        pool_params: EkuboPoolParams { fee: 3000_u128, tick_spacing: 0, extension: Zero::zero() },
        ..default_topup_config(user)
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Topup amount less than minimum")]
fn test_set_trove_config_topup_amount_below_min_balance_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        topup_amount: 1 * WAD_ONE, // below min_asset_balance (5 * WAD_ONE)
        ..default_topup_config(user)
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Invalid destination")]
fn test_set_trove_config_zero_destination_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig { destination: Zero::zero(), ..default_topup_config(user) };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_is_ready_returns_false_when_no_config() {
    let test_config = prior_utils::prior_deploy(None);
    let rite_addr = deploy_topup_rite(test_config.prior.contract_address);
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let ready = rite.is_ready(999);
    assert(!ready, 'should not be ready no config');
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Caller is not Prior")]
fn test_perform_non_prior_caller_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(user);
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.perform(trove_id);
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "TOPUP: Caller is not Prior")]
fn test_end_non_prior_caller_reverts() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(user);
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.end(trove_id);
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_get_swap_params_cash_asset_no_swap() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(user);
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    let topup = ITopupRiteDispatcher { contract_address: rite_addr };
    let swap_params = topup.get_swap_params(trove_id);

    let forge_amount: u128 = swap_params.forge_amount.into();
    assert(forge_amount == 10 * WAD_ONE, 'forge should be topup_amt');
    assert(swap_params.swap_data.is_none(), 'no swap for cash asset');
}

// --- Event tests ---

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_set_trove_config_emits_event() {
    let (_prior, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = prior_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(user);

    let mut spy = spy_events();

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    use opus_compose::vicariate::contracts::rites::topup::topup_rite::topup_rite::{
        Event, TopupConfigUpdated,
    };

    spy.assert_emitted(
        @array![
            (
                rite_addr,
                Event::TopupConfigUpdated(TopupConfigUpdated {
                    user,
                    trove_id,
                    config,
                }),
            ),
        ],
    );
}
