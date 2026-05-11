use core::num::traits::Zero;
use opus::interfaces::{IShrineDispatcher, IShrineDispatcherTrait};
use opus::types::Health;
use opus_compose::addresses::mainnet;
use opus_compose::archabbot::contracts::archabbot::archabbot as archabbot_contract;
use opus_compose::archabbot::contracts::rites::topup::constants::MAX_SLIPPAGE;
use opus_compose::archabbot::contracts::rites::topup::topup_rite::{
    ITopupRiteDispatcher, ITopupRiteDispatcherTrait, topup_rite as topup_rite_contract,
};
use opus_compose::archabbot::contracts::rites::topup::types::{TopupConditions, TopupConfig};
use opus_compose::archabbot::contracts::rites::types::EkuboPoolParams;
use opus_compose::archabbot::interfaces::celebrant::{
    ICelebrantDispatcher, ICelebrantDispatcherTrait,
};
use opus_compose::archabbot::interfaces::rite::{IRITE_ID, IRiteDispatcher, IRiteDispatcherTrait};
use opus_compose::archabbot::tests::utils::archabbot_utils;
use opus_compose::constants;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use opus_compose::shared::components::src5::{ISRC5Dispatcher, ISRC5DispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait,
    cheat_caller_address, declare, spy_events,
};
use starknet::{ContractAddress, SyscallResultTrait};
use wadray::{RAY_PERCENT, Ray, WAD_ONE, Wad};


//
// Helpers
//

fn deploy_topup_rite(archabbot_address: ContractAddress) -> ContractAddress {
    let topup_class = declare("topup_rite").unwrap_syscall().contract_class();
    let calldata: Array<felt252> = array![
        mainnet::SHRINE.into(), // yin (CASH = Shrine address)
        archabbot_address.into(),
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
            min_asset_balance: 5 * WAD_ONE, slippage: RAY_PERCENT.into(),
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

// Open a trove via Archabbot, deploy a topup rite, and attach it.
fn setup_trove_with_topup_rite() -> (ICelebrantDispatcher, u64, ContractAddress) {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user = archabbot_utils::USER;

    let trove_id = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let rite_addr = deploy_topup_rite(test_config.archabbot.contract_address);

    // Attach rite to trove
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    test_config.archabbot.set_rite(trove_id, rite_addr);
    ICelebrantDispatcherTrait::set_trove_config(
        test_config.archabbot, trove_id, archabbot_utils::BASE_TROVE_CONFIG(),
    );

    (test_config.archabbot, trove_id, rite_addr)
}

//
// Rite Tests
//

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_topup_rite_constructor() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let rite_addr = deploy_topup_rite(test_config.archabbot.contract_address);
    let rite = IRiteDispatcher { contract_address: rite_addr };

    assert!(rite.get_rite_id() == "TOPUP", "wrong rite id");
    assert!(
        ISRC5Dispatcher { contract_address: rite_addr }.supports_interface(IRITE_ID),
        "Rite SRC5 ID not supported",
    );
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_set_trove_config_cash_asset_success() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
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
#[fork("MAINNET_CHANTRY")]
fn test_balance_above_minimum_asset_balance() {
    let (archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let mut spy = spy_events();

    let mut config = default_topup_config(user);
    let cash = IERC20Dispatcher { contract_address: mainnet::SHRINE };
    let user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();
    config.conditions.min_asset_balance = user_cash_balance - 1;

    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.set_rite(trove_id, rite_addr);

    assert_eq!(archabbot.get_rite(trove_id), rite_addr, "Rite not set");

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    assert!(!archabbot.can_execute_rite(trove_id), "Rite should not be ready");
    assert!(!rite.is_ready(trove_id), "Rite should not be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended");

    spy
        .assert_emitted(
            @array![
                (
                    rite_addr,
                    topup_rite_contract::Event::TopupConfigUpdated(
                        topup_rite_contract::TopupConfigUpdated { user, trove_id, config },
                    ),
                ),
            ],
        );
    spy
        .assert_emitted(
            @array![
                (
                    archabbot.contract_address,
                    archabbot_contract::Event::RiteSet(
                        archabbot_contract::RiteSet { user, trove_id, rite: rite_addr },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_disable_trove_config() {
    let (archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let mut spy = spy_events();
    // Disable by setting topup_amount to 0
    let mut config = default_topup_config(user);
    config.topup_amount = 0;
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    let stored_span = rite.get_trove_config(trove_id);
    let mut stored_iter = stored_span;
    let stored: TopupConfig = Serde::<TopupConfig>::deserialize(ref stored_iter).unwrap();
    assert!(stored.topup_amount.is_zero(), "should be zero");

    assert!(!archabbot.can_execute_rite(trove_id), "Rite should not be ready");
    assert!(!rite.is_ready(trove_id), "Rite should not be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended");

    spy
        .assert_emitted(
            @array![
                (
                    rite_addr,
                    topup_rite_contract::Event::TopupConfigUpdated(
                        topup_rite_contract::TopupConfigUpdated { user, trove_id, config },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_set_trove_config_max_slippage() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        conditions: TopupConditions {
            slippage: MAX_SLIPPAGE.into(), ..default_topup_config(user).conditions,
        },
        ..default_topup_config(user),
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    let stored_span = rite.get_trove_config(trove_id);
    let mut stored_iter = stored_span;
    let stored: TopupConfig = Serde::<TopupConfig>::deserialize(ref stored_iter).unwrap();
    let stored_slippage: u128 = stored.conditions.slippage.into();
    assert_eq!(stored_slippage, MAX_SLIPPAGE, "slippage should be max");
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Slippage out of acceptable range")]
fn test_set_trove_config_zero_slippage_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        conditions: TopupConditions {
            slippage: Zero::zero(), ..default_topup_config(user).conditions,
        },
        ..default_topup_config(user),
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Slippage out of acceptable range")]
fn test_set_trove_config_slippage_exceeds_max_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        conditions: TopupConditions {
            slippage: (MAX_SLIPPAGE + 1).into(), ..default_topup_config(user).conditions,
        },
        ..default_topup_config(user),
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Not owner")]
fn test_set_trove_config_not_owner_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(archabbot_utils::BAD_GUY);

    cheat_caller_address(rite_addr, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Invalid asset")]
fn test_set_trove_config_zero_asset_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig { asset: Zero::zero(), ..default_topup_config(user) };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Invalid pool params")]
fn test_set_trove_config_invalid_pool_params_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        asset: mainnet::USDC,
        pool_params: EkuboPoolParams { fee: 3000_u128, tick_spacing: 0, extension: Zero::zero() },
        ..default_topup_config(user),
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Pool price is zero")]
fn test_set_trove_config_non_existent_pool_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        asset: mainnet::USDC,
        pool_params: EkuboPoolParams {
            fee: 100000000000000000, tick_spacing: 20, extension: Zero::zero(),
        },
        ..default_topup_config(user),
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Topup amount less than minimum")]
fn test_set_trove_config_topup_amount_below_min_balance_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig {
        topup_amount: 1 * WAD_ONE, // below min_asset_balance (5 * WAD_ONE)
        ..default_topup_config(user),
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Invalid destination")]
fn test_set_trove_config_zero_destination_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = TopupConfig { destination: Zero::zero(), ..default_topup_config(user) };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_is_ready_returns_false_when_no_config() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let rite_addr = deploy_topup_rite(test_config.archabbot.contract_address);
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let ready = rite.is_ready(999);
    assert!(!ready, "should not be ready no config");
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Caller is not Archabbot")]
fn test_perform_non_archabbot_caller_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(user);
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.perform(trove_id);
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "TOPUP: Caller is not Archabbot")]
fn test_end_non_archabbot_caller_reverts() {
    let (_archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_topup_config(user);
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.end(trove_id);
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_end_rite() {
    let (archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let mut spy = spy_events();

    let mut config = default_topup_config(user);

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.end_rite(trove_id);

    spy
        .assert_emitted(
            @array![
                (
                    archabbot.contract_address,
                    archabbot_contract::Event::RiteEnded(
                        archabbot_contract::RiteEnded { caller: user, trove_id, rite: rite_addr },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_cash_topup() {
    let (archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let mut spy = spy_events();

    let mut config = default_topup_config(user);
    let cash = IERC20Dispatcher { contract_address: mainnet::SHRINE };
    let shrine = IShrineDispatcher { contract_address: mainnet::SHRINE };
    let before_user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();
    let before_trove_health: Health = shrine.get_trove_health(trove_id);

    config.conditions.min_asset_balance = before_user_cash_balance + 1;

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    assert_eq!(archabbot.get_rite(trove_id), rite_addr, "Rite not set");
    assert!(archabbot.can_execute_rite(trove_id), "Rite should be ready");
    assert!(rite.is_ready(trove_id), "Rite should be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended");

    let topup = ITopupRiteDispatcher { contract_address: rite_addr };
    let swap_params = topup.get_swap_params(trove_id);

    let forge_amount: u128 = swap_params.forge_amount.into();
    assert_eq!(forge_amount, config.topup_amount, "Wrong forge amount");
    assert!(swap_params.route_node.is_none(), "Wrong swap data");

    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.execute_rite(trove_id);

    let after_user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();
    let expected_user_cash_balance: u128 = before_user_cash_balance + config.topup_amount;
    assert_eq!(after_user_cash_balance, expected_user_cash_balance, "Topup did not happen");

    let after_trove_health: Health = shrine.get_trove_health(trove_id);
    let expected_trove_debt: Wad = before_trove_health.debt + config.topup_amount.into();
    assert_eq!(after_trove_health.debt, expected_trove_debt, "Wrong trove debt");

    assert!(!archabbot.can_execute_rite(trove_id), "Rite should not be ready");
    assert!(!rite.is_ready(trove_id), "Rite should not be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended #2");

    spy
        .assert_emitted(
            @array![
                (
                    rite_addr,
                    topup_rite_contract::Event::TopupExecuted(
                        topup_rite_contract::TopupExecuted {
                            trove_id,
                            forge_amount: config.topup_amount.into(),
                            asset: cash.contract_address,
                            topup_amount: config.topup_amount,
                            destination: user,
                        },
                    ),
                ),
            ],
        );
    spy
        .assert_emitted(
            @array![
                (
                    archabbot.contract_address,
                    archabbot_contract::Event::RiteExecuted(
                        archabbot_contract::RiteExecuted {
                            caller: user, trove_id, rite: rite_addr, incentive: Zero::zero(),
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: LTV exceeds relative threshold")]
fn test_cash_topup_exceeds_relative_ltv_fail() {
    let (archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let shrine = IShrineDispatcher { contract_address: mainnet::SHRINE };

    let mut trove_config = archabbot.get_trove_config(trove_id);
    let trove_health = shrine.get_trove_health(trove_id);
    trove_config.relative_threshold = trove_health.ltv / trove_health.threshold;
    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.set_trove_config(trove_id, trove_config);

    let mut config = default_topup_config(user);
    let cash = IERC20Dispatcher { contract_address: mainnet::SHRINE };
    let before_user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();

    config.conditions.min_asset_balance = before_user_cash_balance + 1;

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    assert_eq!(archabbot.get_rite(trove_id), rite_addr, "Rite not set");
    assert!(archabbot.can_execute_rite(trove_id), "Rite should be ready");
    assert!(rite.is_ready(trove_id), "Rite should be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended");

    let topup = ITopupRiteDispatcher { contract_address: rite_addr };
    let swap_params = topup.get_swap_params(trove_id);

    let forge_amount: u128 = swap_params.forge_amount.into();
    assert_eq!(forge_amount, config.topup_amount, "Wrong forge amount");
    assert!(swap_params.route_node.is_none(), "Wrong swap data");

    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.execute_rite(trove_id);
}

// Parametrized across EKUBO (CASH is token0) and USDC (CASH is token1)
#[test]
#[fork("MAINNET_CHANTRY")]
#[test_case(
    name: "ekubo",
    (
        mainnet::EKUBO,
        EkuboPoolParams {
            fee: constants::CASH_EKUBO_TWAMM_POOL_FEE,
            tick_spacing: constants::EKUBO_TWAMM_TICK_SPACING,
            extension: mainnet::EKUBO_TWAMM_EXTENSION,
        },
        WAD_ONE / 20, // 0.05 EKUBO
        WAD_ONE / 10 // 0.1 EKUBO
    ),
)]
#[test_case(
    name: "usdc",
    (
        mainnet::USDC,
        EkuboPoolParams {
            fee: 6805647338418769825990228293189632, tick_spacing: 20, extension: Zero::zero(),
        },
        5000000, // 5 USDC
        10000000 // 10 USDC
    ),
)]
fn test_swap_topup_with_incentive(test_case: (ContractAddress, EkuboPoolParams, u128, u128)) {
    let (asset, pool_params, min_asset_balance, topup_amount) = test_case;
    let (archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let mut spy = spy_events();

    let mut trove_config = archabbot.get_trove_config(trove_id);
    let incentive: Wad = WAD_ONE.into();
    trove_config.incentive = incentive;

    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.set_trove_config(trove_id, trove_config);

    let slippage: Ray = RAY_PERCENT.into();
    let config = TopupConfig {
        asset,
        pool_params,
        conditions: TopupConditions { min_asset_balance, slippage },
        topup_amount,
        destination: user,
    };

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    assert_eq!(archabbot.get_rite(trove_id), rite_addr, "Rite not set");
    assert!(archabbot.can_execute_rite(trove_id), "Rite should be ready");
    assert!(rite.is_ready(trove_id), "Rite should be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended");

    let asset_token = IERC20Dispatcher { contract_address: asset };
    let cash = IERC20Dispatcher { contract_address: mainnet::SHRINE };
    let shrine = IShrineDispatcher { contract_address: mainnet::SHRINE };
    let before_user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();
    let before_user_asset_balance: u128 = asset_token.balance_of(user).try_into().unwrap();
    let before_trove_health: Health = shrine.get_trove_health(trove_id);

    let topup_dispatcher = ITopupRiteDispatcher { contract_address: rite_addr };
    let swap_params = topup_dispatcher.get_swap_params(trove_id);

    let forge_amount: u128 = swap_params.forge_amount.into();
    assert!(forge_amount.is_non_zero(), "Wrong forge amount");
    assert!(swap_params.route_node.is_some(), "Wrong swap data");

    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.execute_rite(trove_id);

    let after_user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();
    let expected_user_cash_balance: u128 = before_user_cash_balance + incentive.into();
    assert_eq!(after_user_cash_balance, expected_user_cash_balance, "Wrong incentive");

    let after_user_asset_balance: u128 = asset_token.balance_of(user).try_into().unwrap();
    let expected_user_asset_balance: u128 = before_user_asset_balance + config.topup_amount;
    assert_eq!(after_user_asset_balance, expected_user_asset_balance, "Topup did not happen");

    let after_trove_health: Health = shrine.get_trove_health(trove_id);
    let expected_trove_debt: Wad = before_trove_health.debt + forge_amount.into() + incentive;
    assert_eq!(after_trove_health.debt, expected_trove_debt, "Wrong trove debt");

    assert!(!archabbot.can_execute_rite(trove_id), "Rite should not be ready");
    assert!(!rite.is_ready(trove_id), "Rite should not be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended #2");

    spy
        .assert_emitted(
            @array![
                (
                    rite_addr,
                    topup_rite_contract::Event::TopupExecuted(
                        topup_rite_contract::TopupExecuted {
                            trove_id,
                            forge_amount: swap_params.forge_amount,
                            asset: asset_token.contract_address,
                            topup_amount: config.topup_amount,
                            destination: user,
                        },
                    ),
                ),
            ],
        );
    spy
        .assert_emitted(
            @array![
                (
                    archabbot.contract_address,
                    archabbot_contract::Event::RiteExecuted(
                        archabbot_contract::RiteExecuted {
                            caller: user, trove_id, rite: rite_addr, incentive,
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: 'SH: forge_fee% > max_forge_fee%')]
fn test_cash_topup_exceeds_max_forge_fee_pct_fail() {
    let (archabbot, trove_id, rite_addr) = setup_trove_with_topup_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let mut config = default_topup_config(user);
    let cash = IERC20Dispatcher { contract_address: mainnet::SHRINE };
    let before_user_cash_balance: u128 = cash.balance_of(user).try_into().unwrap();

    config.conditions.min_asset_balance = before_user_cash_balance + 1;

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_config(config));

    assert_eq!(archabbot.get_rite(trove_id), rite_addr, "Rite not set");
    assert!(archabbot.can_execute_rite(trove_id), "Rite should be ready");
    assert!(rite.is_ready(trove_id), "Rite should be ready #2");
    assert!(rite.has_ended(trove_id), "Rite should have ended");

    let topup = ITopupRiteDispatcher { contract_address: rite_addr };
    let swap_params = topup.get_swap_params(trove_id);

    let forge_amount: u128 = swap_params.forge_amount.into();
    assert_eq!(forge_amount, config.topup_amount, "Wrong forge amount");
    assert!(swap_params.route_node.is_none(), "Wrong swap data");

    cheat_caller_address(mainnet::SHRINE, mainnet::RECEPTOR, CheatSpan::TargetCalls(1));
    let depegged_price: Wad = (WAD_ONE - WAD_ONE / 10).into(); // 0.9
    IShrineDispatcher { contract_address: mainnet::SHRINE }.update_yin_spot_price(depegged_price);

    cheat_caller_address(archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.execute_rite(trove_id);
}

