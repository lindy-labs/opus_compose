use core::num::traits::Zero;
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, ISentinelDispatcherTrait, IShrineDispatcherTrait,
};
use opus::types::{AssetBalance, Health};
use opus::utils::assertions::assert_equalish;
use opus_compose::addresses::mainnet;
use opus_compose::archabbot::contracts::archabbot::archabbot as archabbot_contract;
use opus_compose::archabbot::interfaces::celebrant::ICelebrantDispatcherTrait;
use opus_compose::archabbot::interfaces::rite::{IRiteDispatcher, IRiteDispatcherTrait};
use opus_compose::archabbot::tests::mocks::mock_rite::MockRiteConfig;
use opus_compose::archabbot::tests::mocks::reentrant_rite::ReentrantRiteConfig;
use opus_compose::archabbot::tests::mocks::trove_opening_rite::TroveOpeningRiteConfig;
use opus_compose::archabbot::tests::utils::archabbot_utils;
use opus_compose::archabbot::types::{Action, TroveConfig};
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait,
    cheat_caller_address, declare, spy_events,
};
use starknet::{ContractAddress, SyscallResultTrait};
use wadray::{WAD_ONE, Wad};

const EXISTING_TROVE_ID: u64 = 1;
const EXISTING_TROVE_IDS: [u64; 2] = [EXISTING_TROVE_ID, 282];

//
// Deployment
//

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_archabbot_deployment() {
    let abbot = IAbbotDispatcher { contract_address: mainnet::ABBOT };
    let expected_troves_count: u64 = abbot.get_troves_count();

    let test_config = archabbot_utils::archabbot_deploy(None);
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    let troves_count = archabbot.get_troves_count();
    assert_eq!(troves_count, expected_troves_count, "Wrong starting troves count");
}

//
// Abbot functions
//

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Disabled")]
fn test_open_trove_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user = archabbot_utils::USER;
    let yang = mainnet::ETH;
    let yang_amount: u128 = WAD_ONE / 10; // 0.1 ETH
    let forge_amount: Wad = (50 * WAD_ONE).into(); // 50 CASH
    let max_forge_fee_pct: Wad = Zero::zero();

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    archabbot_utils::fund_user_eth(user, yang_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    // Open trove
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    let _trove_id = archabbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );
}

// ---------------------------------------------------------------------------
// Tests for interacting with existing troves
// — uses EXISTING_TROVE_ID owned by EXISTING_TROVE_OWNER on mainnet.
// Archabbot delegates owner lookups to the real Abbot contract.
// ---------------------------------------------------------------------------

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_trove_ownership() {
    let test_config = archabbot_utils::archabbot_deploy(None);

    let user: ContractAddress = mainnet::EXISTING_TROVE_OWNER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    // Verify ownership of the existing trove
    let owner = archabbot.get_trove_owner(EXISTING_TROVE_ID);
    assert!(owner.is_some(), "no owner");
    assert!(owner.unwrap() == user, "wrong owner");

    let trove_ids = archabbot.get_user_trove_ids(user);
    assert_eq!(trove_ids, EXISTING_TROVE_IDS.span(), "Incorrect trove IDs");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_trove_deposit_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = mainnet::EXISTING_TROVE_OWNER;
    let trove_id: u64 = EXISTING_TROVE_ID;
    let yang: ContractAddress = mainnet::ETH;
    let deposit_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    let before_yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);

    // Fund user and approve gate
    archabbot_utils::fund_user_eth(user, deposit_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    let mut spy = spy_events();

    // Deposit into existing trove
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });

    let after_yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    let expected_yang_deposit: Wad = before_yang_deposit + deposit_amount.into();
    let error_margin: Wad = 20_u128.into();
    assert_equalish(
        after_yang_deposit, expected_yang_deposit, error_margin, 'Wrong yang deposit amount',
    );

    // Verify Deposit event
    let yang_amt = test_config.sentinel.convert_to_yang(yang, deposit_amount);
    spy
        .assert_emitted(
            @array![
                (
                    test_config.archabbot.contract_address,
                    archabbot_contract::Event::Deposit(
                        archabbot_contract::Deposit {
                            user, trove_id, yang, yang_amt, asset_amt: deposit_amount,
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_trove_withdraw_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = mainnet::EXISTING_TROVE_OWNER;
    let trove_id: u64 = EXISTING_TROVE_ID;
    let yang: ContractAddress = mainnet::ETH;
    let yang_erc20 = IERC20Dispatcher { contract_address: yang };
    let withdraw_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    // First deposit so there's something to withdraw
    archabbot_utils::fund_user_eth(user, withdraw_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.deposit(trove_id, AssetBalance { address: yang, amount: withdraw_amount });

    // Now withdraw
    let before_yang_balance: u256 = yang_erc20.balance_of(user);

    // Repay enough debt to cover withdrawal — melt entire debt to be safe
    let trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    let repay_amount: Wad = trove_health.debt;
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.archabbot.contract_address, repay_amount.into());
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    archabbot.melt(trove_id, trove_health.debt);

    let mut spy = spy_events();

    archabbot.withdraw(trove_id, AssetBalance { address: yang, amount: withdraw_amount });

    let after_yang_balance: u256 = yang_erc20.balance_of(user);
    let expected_yang_balance: u256 = before_yang_balance + withdraw_amount.into();
    let error_margin: u256 = 1_u128.into();
    assert_equalish(after_yang_balance, expected_yang_balance, error_margin, 'Wrong yang balance');

    // Verify Withdraw event
    let yang_amt = test_config.sentinel.convert_to_yang(yang, withdraw_amount);
    let asset_amt = test_config.sentinel.convert_to_assets(yang, yang_amt);
    spy
        .assert_emitted(
            @array![
                (
                    test_config.archabbot.contract_address,
                    archabbot_contract::Event::Withdraw(
                        archabbot_contract::Withdraw { user, trove_id, yang, yang_amt, asset_amt },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_trove_forge_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = mainnet::EXISTING_TROVE_OWNER;
    let trove_id: u64 = EXISTING_TROVE_ID;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    let before_balance: Wad = test_config.shrine.get_yin(user);
    let before_trove_health: Health = test_config.shrine.get_trove_health(trove_id);

    // Forge additional CASH into existing trove
    let forge_amount: Wad = WAD_ONE.into();
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.forge(trove_id, forge_amount, Zero::zero());

    let after_balance: Wad = test_config.shrine.get_yin(user);
    let expected_balance: Wad = before_balance + forge_amount;
    assert_eq!(after_balance, expected_balance, "Wrong yin balance");

    let after_trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    let expected_debt: Wad = before_trove_health.debt + forge_amount;
    assert_eq!(after_trove_health.debt, expected_debt, "Wrong trove debt");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_trove_melt_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = mainnet::EXISTING_TROVE_OWNER;
    let trove_id: u64 = EXISTING_TROVE_ID;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    // Forge first so there is debt to melt
    let forge_amount: Wad = (5 * WAD_ONE).into();
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.forge(trove_id, forge_amount, Zero::zero());

    let before_balance: Wad = test_config.shrine.get_yin(user);
    let before_health: Health = test_config.shrine.get_trove_health(trove_id);

    // Melt part of the debt
    let melt_amount: Wad = (WAD_ONE / 10).into();
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.archabbot.contract_address, melt_amount.into());
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.melt(trove_id, melt_amount);

    let after_balance: Wad = test_config.shrine.get_yin(user);
    let expected_balance: Wad = before_balance - melt_amount;
    assert_eq!(after_balance, expected_balance, "Wrong yin balance");

    let after_health: Health = test_config.shrine.get_trove_health(trove_id);
    let expected_debt: Wad = before_health.debt - melt_amount;
    assert_eq!(after_health.debt, expected_debt, "Wrong debt");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_trove_close_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let yang = mainnet::ETH;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    // Open trove via legacy abbot (archabbot.open_trove is disabled)
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let before_yin_balance: Wad = test_config.shrine.get_yin(user);
    assert!(before_yin_balance.is_non_zero(), "user should have yin");

    // Capture deposit before close for event verification
    let yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    assert!(yang_deposit.is_non_zero(), "should have yang deposit");

    let mut spy = spy_events();

    // Close trove
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.close_trove(trove_id);

    let owner = archabbot.get_trove_owner(trove_id);
    assert!(owner.is_some(), "owner should still exist");

    // Verify trove deposit is zero after close
    let deposit = test_config.shrine.get_deposit(yang, trove_id);
    assert!(deposit.is_zero(), "deposit should be zero");

    // Verify trove debt is zero after close
    let trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    assert!(trove_health.debt.is_zero(), "debt should be zero");

    // Verify Withdraw + TroveClosed events
    let asset_amt = test_config.sentinel.convert_to_assets(yang, yang_deposit);
    spy
        .assert_emitted(
            @array![
                (
                    test_config.archabbot.contract_address,
                    archabbot_contract::Event::Withdraw(
                        archabbot_contract::Withdraw {
                            user, trove_id, yang, yang_amt: yang_deposit, asset_amt,
                        },
                    ),
                ),
                (
                    test_config.archabbot.contract_address,
                    archabbot_contract::Event::TroveClosed(
                        archabbot_contract::TroveClosed { trove_id },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_trove_close_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.close_trove(EXISTING_TROVE_ID);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_trove_deposit_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let yang: ContractAddress = mainnet::ETH;
    let deposit_amount: u128 = WAD_ONE / 10;

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.deposit(EXISTING_TROVE_ID, AssetBalance { address: yang, amount: deposit_amount });
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_trove_withdraw_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let yang: ContractAddress = mainnet::ETH;

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.withdraw(EXISTING_TROVE_ID, AssetBalance { address: yang, amount: WAD_ONE / 100 });
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_trove_forge_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    let forge_amount: Wad = WAD_ONE.into();
    let max_forge_fee_pct: Wad = Zero::zero();
    archabbot.forge(EXISTING_TROVE_ID, forge_amount, max_forge_fee_pct);
}


//
// Rite functions
// - Additional coverage in tests for topup rite
//

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_default_config() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    // Config should exist but have default values
    let config = test_config.archabbot.get_trove_config(trove_id);
    assert_eq!(config, Default::default(), "Wrong default config");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_set_config_capped() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let mut spy = spy_events();

    // Set config with relative_threshold far beyond max (RAY_ONE)
    let config = TroveConfig {
        relative_threshold: (archabbot_contract::MAX_RELATIVE_THRESHOLD + 1).into(),
        max_forge_fee_pct: (archabbot_contract::MAX_FORGE_FEE_PCT + 1).into(),
        incentive: (archabbot_contract::MAX_INCENTIVE + 1).into(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_trove_config(trove_id, config);

    let stored = test_config.archabbot.get_trove_config(trove_id);
    assert_eq!(
        stored.relative_threshold,
        archabbot_contract::MAX_RELATIVE_THRESHOLD.into(),
        "Relative threshold not capped",
    );
    assert_eq!(
        stored.max_forge_fee_pct,
        archabbot_contract::MAX_FORGE_FEE_PCT.into(),
        "Max forge fee % not capped",
    );
    assert_eq!(
        stored.incentive, archabbot_contract::MAX_INCENTIVE.into(), "Max incentive not capped",
    );

    let expected_config = TroveConfig {
        relative_threshold: archabbot_contract::MAX_RELATIVE_THRESHOLD.into(),
        max_forge_fee_pct: archabbot_contract::MAX_FORGE_FEE_PCT.into(),
        incentive: archabbot_contract::MAX_INCENTIVE.into(),
    };
    let expected_events = array![
        (
            test_config.archabbot.contract_address,
            archabbot_contract::Event::ConfigUpdated(
                archabbot_contract::ConfigUpdated { user, trove_id, config: expected_config },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_set_config_exact_max_values() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let mut spy = spy_events();

    // Set each field exactly at its maximum — should be stored unchanged (no capping)
    let config = TroveConfig {
        relative_threshold: archabbot_contract::MAX_RELATIVE_THRESHOLD.into(),
        max_forge_fee_pct: archabbot_contract::MAX_FORGE_FEE_PCT.into(),
        incentive: archabbot_contract::MAX_INCENTIVE.into(),
    };

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_trove_config(trove_id, config);

    let stored = test_config.archabbot.get_trove_config(trove_id);
    assert_eq!(
        stored.relative_threshold,
        archabbot_contract::MAX_RELATIVE_THRESHOLD.into(),
        "relative_threshold changed at max",
    );
    assert_eq!(
        stored.max_forge_fee_pct,
        archabbot_contract::MAX_FORGE_FEE_PCT.into(),
        "fee pct changed at max",
    );
    assert_eq!(
        stored.incentive, archabbot_contract::MAX_INCENTIVE.into(), "incentive changed at max",
    );

    let expected_events = array![
        (
            test_config.archabbot.contract_address,
            archabbot_contract::Event::ConfigUpdated(
                archabbot_contract::ConfigUpdated { user, trove_id, config },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_set_config_not_owner() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    // Config should exist but have default values
    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    test_config.archabbot.set_trove_config(trove_id, Default::default());
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_default_rite() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    assert!(test_config.archabbot.get_rite(trove_id).is_zero(), "Rite set");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_set_rite_not_owner() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    test_config.archabbot.set_rite(trove_id, user);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_set_rite_to_zero_disables_rite() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let rite_addr = deploy_mock_rite(test_config.archabbot.contract_address);

    // Attach rite to trove and configure it
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    test_config.archabbot.set_rite(trove_id, rite_addr);
    test_config.archabbot.set_trove_config(trove_id, archabbot_utils::BASE_TROVE_CONFIG());

    // Configure mock rite so is_ready returns true
    let rite = IRiteDispatcher { contract_address: rite_addr };
    let config = default_mock_config();
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    // Verify rite is attached and ready
    assert_eq!(test_config.archabbot.get_rite(trove_id), rite_addr, "Rite not set");
    assert!(test_config.archabbot.can_execute_rite(trove_id), "Rite should be ready");

    let mut spy = spy_events();

    // Reset rite to zero address
    let zero_address: ContractAddress = Zero::zero();
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_rite(trove_id, zero_address);

    // Verify rite is detached
    assert!(test_config.archabbot.get_rite(trove_id).is_zero(), "Rite should be zero");
    assert!(!test_config.archabbot.can_execute_rite(trove_id), "Rite should not be ready");

    // Verify RiteSet event with zero address
    spy
        .assert_emitted(
            @array![
                (
                    test_config.archabbot.contract_address,
                    archabbot_contract::Event::RiteSet(
                        archabbot_contract::RiteSet { user, trove_id, rite: zero_address },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Cannot execute rite")]
fn test_execute_default_rite() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    test_config.archabbot.execute_rite(trove_id);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: No rite set")]
fn test_end_default_rite() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.end_rite(trove_id);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_can_execute_rite_invalid_trove() {
    let test_config = archabbot_utils::archabbot_deploy(None);

    // No trove created - can_execute_rite should return false
    // (no rite attached, so is_ready would revert or return false)
    let can_execute = test_config.archabbot.can_execute_rite(1);
    assert!(!can_execute, "can_execute should be false");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Caller not rite")]
fn test_on_rite_actions_not_rite() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.on_rite_actions(trove_id, array![Action::None].span());
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: 'ENTRYPOINT_NOT_FOUND')]
fn test_set_invalid_rite() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_rite(trove_id, test_config.archabbot.contract_address);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Rite interface not supported")]
fn test_set_rite_src5_without_rite_interface_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    // Deploy a contract that implements SRC5 but does NOT register the IRite interface
    let fake_class = declare("fake_src5_rite").unwrap_syscall().contract_class();
    let calldata: Array<felt252> = array![];
    let (fake_rite_addr, _) = fake_class.deploy(@calldata).expect('fake src5 rite deploy fail');

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_rite(trove_id, fake_rite_addr);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_end_rite_not_owner() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    test_config.archabbot.end_rite(trove_id);
}

//
// Mock Rite tests
// - Forge and Melt are covered in topup rite tests
//

fn deploy_mock_rite(archabbot_address: ContractAddress) -> ContractAddress {
    let mock_class = declare("mock_rite").unwrap_syscall().contract_class();
    let calldata: Array<felt252> = array![archabbot_address.into()];
    let (rite_addr, _) = mock_class.deploy(@calldata).expect('mock rite deploy fail');
    rite_addr
}

fn default_mock_config() -> MockRiteConfig {
    MockRiteConfig {
        is_deposit: true,
        num_calls: 1,
        asset: mainnet::ETH,
        amount: WAD_ONE / 10,
        is_malicious: false,
    }
}

fn serialize_mock_config(config: MockRiteConfig) -> Span<felt252> {
    let mut serialized: Array<felt252> = Default::default();
    config.serialize(ref serialized);
    serialized.span()
}

// Open a trove, deploy a mock rite, and attach it.
fn setup_trove_with_mock_rite() -> (archabbot_utils::ArchabbotTestConfig, u64, ContractAddress) {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user = archabbot_utils::USER;

    let trove_id = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let rite_addr = deploy_mock_rite(test_config.archabbot.contract_address);

    // Attach rite to trove and set trove config
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    test_config.archabbot.set_rite(trove_id, rite_addr);
    test_config.archabbot.set_trove_config(trove_id, archabbot_utils::BASE_TROVE_CONFIG());

    (test_config, trove_id, rite_addr)
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_set_mock_rite_pass() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let trove_id: u64 = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let mut spy = spy_events();

    let rite_addr = deploy_mock_rite(test_config.archabbot.contract_address);
    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    test_config.archabbot.set_rite(trove_id, rite_addr);

    let expected_events = array![
        (
            test_config.archabbot.contract_address,
            archabbot_contract::Event::RiteSet(
                archabbot_contract::RiteSet { user, trove_id, rite: rite_addr },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}


#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_mock_rite_has_ended() {
    let (_test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let rite = IRiteDispatcher { contract_address: rite_addr };

    assert!(rite.has_ended(trove_id), "should always have ended");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[test_case(true)]
#[test_case(false)]
fn test_mock_rite_deposit(is_perform: bool) {
    let (test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };
    let yang = mainnet::ETH;

    let mut spy = spy_events();

    let num_calls = 3;
    let amount_per_call: u128 = WAD_ONE / 10;
    let config = MockRiteConfig {
        is_deposit: true, num_calls, asset: yang, amount: amount_per_call, is_malicious: false,
    };
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    // Fund the mock rite so it can deposit via the archabbot
    let total_deposit_amount: u128 = num_calls.into() * amount_per_call;
    archabbot_utils::fund_user_eth(rite_addr, total_deposit_amount.into());

    let before_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    assert!(test_config.archabbot.can_execute_rite(trove_id), "Rite should be ready");
    assert!(rite.is_ready(trove_id), "Rite should be ready #2");

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    let mut expected_rite_event = if is_perform {
        test_config.archabbot.execute_rite(trove_id);
        (
            test_config.archabbot.contract_address,
            archabbot_contract::Event::RiteExecuted(
                archabbot_contract::RiteExecuted {
                    caller: user, trove_id, rite: rite_addr, incentive: Zero::zero(),
                },
            ),
        )
    } else {
        test_config.archabbot.end_rite(trove_id);
        (
            test_config.archabbot.contract_address,
            archabbot_contract::Event::RiteEnded(
                archabbot_contract::RiteEnded { caller: user, trove_id, rite: rite_addr },
            ),
        )
    };

    let after_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    let expected_deposit: Wad = before_deposit + total_deposit_amount.into();
    let error_margin: Wad = 50_u128.into();
    assert_equalish(after_deposit, expected_deposit, error_margin, 'Wrong deposit amount');

    let yang_amount = test_config.sentinel.convert_to_yang(yang, amount_per_call);
    let expected_deposit_event = (
        test_config.archabbot.contract_address,
        archabbot_contract::Event::Deposit(
            archabbot_contract::Deposit {
                user, trove_id, yang, yang_amt: yang_amount, asset_amt: amount_per_call,
            },
        ),
    );

    let expected_events = array![
        expected_rite_event, expected_deposit_event, expected_deposit_event, expected_deposit_event,
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[test_case(true)]
#[test_case(false)]
fn test_mock_rite_withdraw(is_perform: bool) {
    let (test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };
    let yang = mainnet::ETH;
    let yang_erc20 = IERC20Dispatcher { contract_address: yang };

    let mut spy = spy_events();

    let deposit_amount: u128 = WAD_ONE;
    archabbot_utils::fund_user_eth(user, deposit_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    archabbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });

    let num_calls = 4;
    let amount_per_call: u128 = WAD_ONE / 10;
    let config = MockRiteConfig {
        is_deposit: false, num_calls, asset: yang, amount: amount_per_call, is_malicious: false,
    };
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    // Compute yang amount, and then asset amount again for loss of precision.
    let yang_amount = test_config.sentinel.convert_to_yang(yang, amount_per_call);
    let asset_amount_per_call = test_config.sentinel.convert_to_assets(yang, yang_amount);

    let before_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    let before_rite_balance: u256 = yang_erc20.balance_of(rite_addr);
    assert!(test_config.archabbot.can_execute_rite(trove_id), "Rite should be ready");
    assert!(rite.is_ready(trove_id), "Rite should be ready #2");

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    let mut expected_rite_event = if is_perform {
        test_config.archabbot.execute_rite(trove_id);
        (
            test_config.archabbot.contract_address,
            archabbot_contract::Event::RiteExecuted(
                archabbot_contract::RiteExecuted {
                    caller: user, trove_id, rite: rite_addr, incentive: Zero::zero(),
                },
            ),
        )
    } else {
        test_config.archabbot.end_rite(trove_id);
        (
            test_config.archabbot.contract_address,
            archabbot_contract::Event::RiteEnded(
                archabbot_contract::RiteEnded { caller: user, trove_id, rite: rite_addr },
            ),
        )
    };

    let total_withdraw_amount: u128 = num_calls.into() * amount_per_call;
    let after_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    let expected_deposit: Wad = before_deposit - total_withdraw_amount.into();
    let error_margin: Wad = 50_u128.into();
    assert_equalish(after_deposit, expected_deposit, error_margin, 'Wrong trove amount');

    let after_rite_balance: u256 = yang_erc20.balance_of(rite_addr);
    let expected_rite_balance: u256 = before_rite_balance + total_withdraw_amount.into();
    let error_margin: u256 = 50;
    assert_equalish(after_rite_balance, expected_rite_balance, error_margin, 'Wrong user balance');

    let expected_withdraw_event = (
        test_config.archabbot.contract_address,
        archabbot_contract::Event::Withdraw(
            archabbot_contract::Withdraw {
                user, trove_id, yang, yang_amt: yang_amount, asset_amt: asset_amount_per_call,
            },
        ),
    );

    let expected_events = array![
        expected_rite_event,
        expected_withdraw_event,
        expected_withdraw_event,
        expected_withdraw_event,
        expected_withdraw_event,
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: LTV exceeds relative threshold")]
fn test_execute_mock_rite_exceeds_relative_threshold_reverts() {
    let (test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };
    let yang = mainnet::ETH;

    let trove_health = test_config.shrine.get_trove_health(trove_id);
    let relative_threshold = trove_health.ltv / trove_health.threshold;

    // Set relative threshold to the current LTV / threshold so
    // that a single withdrawal of collateral will cause the LTV
    // to fall below the relative threshold
    let trove_config = TroveConfig {
        relative_threshold, max_forge_fee_pct: Zero::zero(), incentive: Zero::zero(),
    };
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_trove_config(trove_id, trove_config);

    // Configure mock rite for a deposit
    let withdraw_amount: u128 = WAD_ONE / 10;
    let config = MockRiteConfig {
        is_deposit: false, num_calls: 1, asset: yang, amount: withdraw_amount, is_malicious: false,
    };
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    assert!(test_config.archabbot.can_execute_rite(trove_id), "Rite should be ready");
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.execute_rite(trove_id);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: LTV exceeds relative threshold")]
fn test_execute_incentive_exceeds_relative_threshold_reverts() {
    let (test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };
    let yang = mainnet::ETH;

    let trove_health = test_config.shrine.get_trove_health(trove_id);
    let relative_threshold = trove_health.ltv / trove_health.threshold;

    // Set relative threshold to the current LTV / threshold so
    // that a single withdrawal of collateral will cause the LTV
    // to fall below the relative threshold
    let trove_config = TroveConfig {
        relative_threshold, max_forge_fee_pct: Zero::zero(), incentive: WAD_ONE.into(),
    };
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_trove_config(trove_id, trove_config);

    // Configure mock rite for a deposit
    let deposit_amount: u128 = 100_u128.into();
    archabbot_utils::fund_user_eth(rite_addr, deposit_amount.into());
    let config = MockRiteConfig {
        is_deposit: true, num_calls: 1, asset: yang, amount: deposit_amount, is_malicious: false,
    };
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    assert!(test_config.archabbot.can_execute_rite(trove_id), "Rite should be ready");
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.execute_rite(trove_id);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
fn test_end_mock_rite_exceeds_relative_threshold_pass() {
    let (test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };
    let yang = mainnet::ETH;

    let before_trove_health = test_config.shrine.get_trove_health(trove_id);
    let relative_threshold = before_trove_health.ltv / before_trove_health.threshold;

    // Set relative threshold to the current LTV / threshold so
    // that a single withdrawal of collateral will cause the LTV
    // to fall below the relative threshold
    let trove_config = TroveConfig {
        relative_threshold, max_forge_fee_pct: Zero::zero(), incentive: Zero::zero(),
    };
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.set_trove_config(trove_id, trove_config);

    // Configure mock rite for a deposit
    let withdraw_amount: u128 = WAD_ONE / 10;
    let config = MockRiteConfig {
        is_deposit: false, num_calls: 1, asset: yang, amount: withdraw_amount, is_malicious: false,
    };
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    assert!(test_config.archabbot.can_execute_rite(trove_id), "Rite should be ready");
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.end_rite(trove_id);

    let after_trove_health = test_config.shrine.get_trove_health(trove_id);
    assert!(after_trove_health.ltv > before_trove_health.ltv, "LTV did not worsen");
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Caller not rite")]
#[test_case(true)]
#[test_case(false)]
fn test_mock_rite_malicious_different_rite_reverts(is_perform: bool) {
    let (test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = MockRiteConfig {
        is_deposit: false,
        num_calls: 1,
        asset: mainnet::ETH,
        amount: WAD_ONE / 10,
        is_malicious: true,
    };
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    if is_perform {
        test_config.archabbot.execute_rite(trove_id);
    } else {
        test_config.archabbot.end_rite(trove_id);
    }
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Execution not started")]
#[test_case(true)]
#[test_case(false)]
fn test_mock_rite_malicious_same_rite_reverts(is_perform: bool) {
    let (test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = MockRiteConfig {
        is_deposit: false,
        num_calls: 1,
        asset: mainnet::ETH,
        amount: WAD_ONE / 10,
        is_malicious: true,
    };
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    let another_user = 'another user'.try_into().unwrap();

    let next_trove_id = archabbot_utils::open_trove_for_user(test_config.abbot, another_user);

    // Attach rite to next trove ID and set trove config
    cheat_caller_address(
        test_config.archabbot.contract_address, another_user, CheatSpan::TargetCalls(2),
    );
    test_config.archabbot.set_rite(next_trove_id, rite_addr);
    test_config.archabbot.set_trove_config(next_trove_id, archabbot_utils::BASE_TROVE_CONFIG());

    cheat_caller_address(rite_addr, another_user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(next_trove_id, serialize_mock_config(config));

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    if is_perform {
        test_config.archabbot.execute_rite(trove_id);
    } else {
        test_config.archabbot.end_rite(trove_id);
    }
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "MOCK_RITE: Caller is not Archabbot")]
#[test_case(true)]
#[test_case(false)]
fn test_mock_rite_non_archabbot_caller_reverts(is_perform: bool) {
    let (_test_config, trove_id, rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;
    let rite = IRiteDispatcher { contract_address: rite_addr };

    let config = default_mock_config();
    rite.set_trove_config(trove_id, serialize_mock_config(config));

    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    if is_perform {
        rite.perform(trove_id);
    } else {
        rite.end(trove_id);
    }
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Cannot execute rite")]
fn test_mock_rite_execute_not_ready_reverts() {
    let (test_config, trove_id, _rite_addr) = setup_trove_with_mock_rite();
    let user = archabbot_utils::USER;

    // Mock rite has no config set (default: num_calls=0, amount=0), so is_ready returns false.
    // This should cause execute_rite to revert before any execution begins.
    assert!(!test_config.archabbot.can_execute_rite(trove_id), "Rite should not be ready");

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.execute_rite(trove_id);
}

//
// No Callback Rite tests
//

fn deploy_no_callback_rite(archabbot_address: ContractAddress) -> ContractAddress {
    let mock_class = declare("no_callback_rite").unwrap_syscall().contract_class();
    let calldata: Array<felt252> = array![archabbot_address.into()];
    let (rite_addr, _) = mock_class.deploy(@calldata).expect('no callback rite deploy fail');
    rite_addr
}

// Open a trove, deploy a no_callback_rite, and attach it.
fn setup_trove_with_no_callback_rite() -> (
    archabbot_utils::ArchabbotTestConfig, u64, ContractAddress,
) {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user = archabbot_utils::USER;

    let trove_id = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    let rite_addr = deploy_no_callback_rite(test_config.archabbot.contract_address);

    // Attach rite to trove and set trove config
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    test_config.archabbot.set_rite(trove_id, rite_addr);
    test_config.archabbot.set_trove_config(trove_id, archabbot_utils::BASE_TROVE_CONFIG());

    (test_config, trove_id, rite_addr)
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Callback not executed")]
#[test_case(true)]
#[test_case(false)]
fn test_no_callback_rite_reverts(is_perform: bool) {
    let (test_config, trove_id, _rite_addr) = setup_trove_with_no_callback_rite();
    let user = archabbot_utils::USER;

    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    if is_perform {
        test_config.archabbot.execute_rite(trove_id);
    } else {
        test_config.archabbot.end_rite(trove_id);
    }
}

//
// Reentrant rite tests
//

fn deploy_reentrant_rite(archabbot_address: ContractAddress) -> ContractAddress {
    let mock_class = declare("reentrant_rite").unwrap_syscall().contract_class();
    let calldata: Array<felt252> = array![archabbot_address.into()];
    let (rite_addr, _) = mock_class.deploy(@calldata).expect('reentrant rite deploy fail');
    rite_addr
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Another trove in execution")]
fn test_execute_rite_parallel_execution_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user = archabbot_utils::USER;

    // Open two troves: one for the reentrant rite, one as the reentry target
    let trove_id_1 = archabbot_utils::open_trove_for_user(test_config.abbot, user);
    let another_user = 'another user'.try_into().unwrap();
    let trove_id_2 = archabbot_utils::open_trove_for_user(test_config.abbot, another_user);

    // Deploy mocks
    let reentrant_addr = deploy_reentrant_rite(test_config.archabbot.contract_address);
    let no_callback_addr = deploy_no_callback_rite(test_config.archabbot.contract_address);

    // Attach reentrant_rite to trove_1, configured to target trove_2
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    test_config.archabbot.set_rite(trove_id_1, reentrant_addr);
    test_config.archabbot.set_trove_config(trove_id_1, archabbot_utils::BASE_TROVE_CONFIG());

    let reentrant = IRiteDispatcher { contract_address: reentrant_addr };
    let reentrant_config = ReentrantRiteConfig { target_trove_id: trove_id_2 };
    let mut reentrant_serialized: Array<felt252> = Default::default();
    reentrant_config.serialize(ref reentrant_serialized);
    cheat_caller_address(reentrant.contract_address, user, CheatSpan::TargetCalls(1));
    reentrant.set_trove_config(trove_id_1, reentrant_serialized.span());

    // Attach no_callback_rite to trove_2 so can_execute_rite_helper returns true for the
    // inner reentrant call. The inner execute_rite will fail at the transient_trove_id
    // check before reaching no_callback_rite.perform.
    cheat_caller_address(
        test_config.archabbot.contract_address, another_user, CheatSpan::TargetCalls(2),
    );
    test_config.archabbot.set_rite(trove_id_2, no_callback_addr);
    test_config.archabbot.set_trove_config(trove_id_2, archabbot_utils::BASE_TROVE_CONFIG());

    // Execute rite on trove_1 → reentrant_rite.perform calls execute_rite(trove_2)
    // → transient_trove_id is already set → PANIC
    assert!(test_config.archabbot.can_execute_rite(trove_id_1), "Trove 1 rite should be ready");
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.execute_rite(trove_id_1);
}

#[test]
#[fork("MAINNET_ARCHABBOT")]
#[should_panic(expected: "ARC: Another trove in execution")]
fn test_end_rite_parallel_execution_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user = archabbot_utils::USER;

    let trove_id = archabbot_utils::open_trove_for_user(test_config.abbot, user);

    // Deploy trove_opening_rite — in end(), it opens a new trove (becoming the
    // owner) and then calls end_rite on it. No caller cheating needed for the
    // reentrant path: the rite IS the natural owner of the new trove.
    let rite_class = declare("trove_opening_rite").unwrap_syscall().contract_class();
    let calldata: Array<felt252> = array![
        test_config.abbot.contract_address.into(), test_config.archabbot.contract_address.into(),
    ];
    let (rite_addr, _) = rite_class.deploy(@calldata).expect('trove opening rite deploy fail');

    // Pre-fund the rite so it can open a trove during end()
    let yang = mainnet::ETH;
    let asset_amount: u128 = WAD_ONE;
    archabbot_utils::fund_user_eth(rite_addr, asset_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, rite_addr);

    // Attach rite to trove and configure it
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    test_config.archabbot.set_rite(trove_id, rite_addr);
    test_config.archabbot.set_trove_config(trove_id, archabbot_utils::BASE_TROVE_CONFIG());

    let rite = IRiteDispatcher { contract_address: rite_addr };
    let config = TroveOpeningRiteConfig {
        yang, asset_amount, forge_amount: 5 * WAD_ONE, max_forge_fee_pct: 0,
    };
    let mut config_serialized: Array<felt252> = Default::default();
    config.serialize(ref config_serialized);
    cheat_caller_address(rite_addr, user, CheatSpan::TargetCalls(1));
    rite.set_trove_config(trove_id, config_serialized.span());

    // end_rite(trove_id) → rite.end() opens a new trove (rite is the owner)
    // → rite calls end_rite(new_trove_id) → assert_trove_owner passes
    // → transient_trove_id is still set → PANIC
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.archabbot.end_rite(trove_id);
}
