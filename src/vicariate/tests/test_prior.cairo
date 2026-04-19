use core::num::traits::Zero;
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, IGateDispatcher, IGateDispatcherTrait,
    IShrineDispatcherTrait,
};
use opus::types::{AssetBalance, Health};
use opus::utils::assertions::assert_equalish;
use opus_compose::addresses::mainnet;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use opus_compose::vicariate::contracts::prior::prior as prior_contract;
use opus_compose::vicariate::interfaces::prior::IPriorDispatcherTrait;
use opus_compose::vicariate::tests::utils::prior_utils;
use opus_compose::vicariate::types::TroveConfig;
use snforge_std::{CheatSpan, cheat_caller_address};
use starknet::ContractAddress;
use wadray::{RAY_ONE, Ray, WAD_ONE, Wad};

const EXISTING_TROVE_ID: u64 = 1;

//
// Deployment
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_prior_deployment() {
    let abbot = IAbbotDispatcher { contract_address: mainnet::ABBOT };
    let legacy_troves_count: u64 = abbot.get_troves_count();

    let test_config = prior_utils::prior_deploy(None);
    let prior = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    let troves_count = prior.get_troves_count();
    assert_eq!(troves_count, legacy_troves_count, "Wrong starting troves count");
}

//
// Abbot functions
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_open_trove_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user = prior_utils::USER;
    let yang = mainnet::ETH;
    let yang_amount: u128 = WAD_ONE / 10; // 0.1 ETH
    let forge_amount: Wad = (50 * WAD_ONE).into(); // 50 CASH
    let max_forge_fee_pct: Wad = Zero::zero();

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let count = prior_abbot.get_troves_count();

    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    let before_yin_balance = test_config.shrine.get_yin(user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = prior_abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    let expected_count = count + 1;
    let count = prior_abbot.get_troves_count();
    assert_eq!(count, expected_count, "Wrong troves count");

    let trove_owner = prior_abbot.get_trove_owner(trove_id);
    assert!(trove_owner.is_some(), "Smart Trove owner should exist");
    assert!(trove_owner.unwrap() == user, "Smart Trove owner mismatch");

    // Verify user's trove IDs
    let trove_ids = prior_abbot.get_user_trove_ids(user);
    assert_eq!(trove_ids.len(), 1, "Should have 1 trove");
    assert_eq!(*trove_ids.at(0), trove_id, "Trove IDs mismatch");

    // Verify trove deposit via shrine
    let deposit = test_config.shrine.get_deposit(yang, trove_id);
    assert!(deposit.is_non_zero(), "Yang not deposited");

    // Verify trove debt
    let trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    assert_eq!(trove_health.debt, forge_amount, "Wrong trove debt");

    // Verify user's yin balance (forged CASH)
    let after_yin_balance = test_config.shrine.get_yin(user);
    assert_eq!(after_yin_balance - before_yin_balance, forge_amount, "Wrong yin amount");
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_close_trove_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let yang = mainnet::ETH;
    let yang_amount: u128 = WAD_ONE;
    let forge_amount: Wad = (5 * WAD_ONE).into();
    let max_forge_fee_pct: Wad = Zero::zero();

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = prior_abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Close trove
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.prior.contract_address, forge_amount.into());
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    prior_abbot.close_trove(trove_id);

    let owner = prior_abbot.get_trove_owner(trove_id);
    assert(owner.is_some(), 'owner should still exist');

    // Verify trove deposit is zero after close
    let deposit = test_config.shrine.get_deposit(yang, trove_id);
    assert(deposit.is_zero(), 'deposit should be zero');

    // Verify trove debt is zero after close
    let trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_zero(), 'debt should be zero');
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "PRI: Not trove owner")]
fn test_close_trove_not_owner_reverts() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    cheat_caller_address(
        test_config.prior.contract_address, prior_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    prior_abbot.close_trove(trove_id);
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_deposit_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let yang: ContractAddress = mainnet::ETH;
    let deposit_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);
    let before_yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);

    // Deposit additional collateral
    prior_utils::fund_user_eth(user, deposit_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    prior_abbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });

    let after_yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    let expected_yang_deposit: Wad = before_yang_deposit + deposit_amount.into();
    let error_margin: Wad = 20_u128.into();
    assert_equalish(
        after_yang_deposit, expected_yang_deposit, error_margin, 'Wrong yang deposit amount',
    );
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "PRI: Not trove owner")]
fn test_deposit_not_owner_reverts() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let yang: ContractAddress = mainnet::ETH;
    let deposit_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    cheat_caller_address(
        test_config.prior.contract_address, prior_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    prior_abbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_withdraw_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let yang: ContractAddress = mainnet::ETH;
    let yang_erc20 = IERC20Dispatcher { contract_address: yang };
    let deposit_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    let before_yang_balance: u256 = yang_erc20.balance_of(user);

    // Repay and withdraw collateral
    let trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    let repay_amount: Wad = trove_health.debt;
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.prior.contract_address, repay_amount.into());
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(2));
    prior_abbot.melt(trove_id, trove_health.debt);
    prior_abbot.withdraw(trove_id, AssetBalance { address: yang, amount: deposit_amount });

    let after_yang_balance: u256 = yang_erc20.balance_of(user);
    let expected_yang_balance: u256 = before_yang_balance + deposit_amount.into();
    let error_margin: u256 = 1_u128.into();
    assert_equalish(after_yang_balance, expected_yang_balance, error_margin, 'Wrong yang balance');
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "PRI: Not trove owner")]
fn test_withdraw_not_owner_reverts() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let yang: ContractAddress = mainnet::ETH;

    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    cheat_caller_address(
        test_config.prior.contract_address, prior_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    prior_abbot.withdraw(trove_id, AssetBalance { address: yang, amount: WAD_ONE / 100 });
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_forge_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    let before_balance: Wad = test_config.shrine.get_yin(user);

    // Forge additional CASH
    let forge_amount: Wad = WAD_ONE.into();
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    prior_abbot.forge(trove_id, forge_amount, Zero::zero());

    let after_balance: Wad = test_config.shrine.get_yin(user);
    let expected_balance: Wad = before_balance + forge_amount;
    assert_eq!(after_balance, expected_balance, "Wrong yin balance");
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_melt_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    let before_health: Health = test_config.shrine.get_trove_health(trove_id);

    // Forge additional CASH
    let melt_amount: Wad = (WAD_ONE / 10).into();
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.prior.contract_address, melt_amount.into());
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    prior_abbot.melt(trove_id, melt_amount);

    let after_health: Health = test_config.shrine.get_trove_health(trove_id);
    let expected_debt: Wad = before_health.debt - melt_amount;
    assert_eq!(after_health.debt, expected_debt, "Wrong debt");
}


//
// Prior functions
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_default_config() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    // Config should exist but have default values
    let config = test_config.prior.get_trove_config(trove_id);
    assert_eq!(config, Default::default(), "Wrong default config");
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_set_config_capped() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    // Set config with relative_threshold far beyond max (RAY_ONE)
    let config = TroveConfig {
        relative_threshold: (prior_contract::MAX_RELATIVE_THRESHOLD + 1).into(),
        max_forge_fee_pct: (prior_contract::MAX_FORGE_FEE_PCT + 1).into(),
        incentive: (prior_contract::MAX_INCENTIVE + 1).into(),
    };

    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.prior.set_trove_config(trove_id, config);

    let stored = test_config.prior.get_trove_config(trove_id);
    assert_eq!(
        stored.relative_threshold,
        prior_contract::MAX_RELATIVE_THRESHOLD.into(),
        "Relative threshold not capped",
    );
    assert_eq!(
        stored.max_forge_fee_pct,
        prior_contract::MAX_FORGE_FEE_PCT.into(),
        "Max forge fee % not capped",
    );
    assert_eq!(stored.incentive, prior_contract::MAX_INCENTIVE.into(), "Max incentive not capped");
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_set_config_exact_max_values() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    // Set each field exactly at its maximum — should be stored unchanged (no capping)
    let config = TroveConfig {
        relative_threshold: prior_contract::MAX_RELATIVE_THRESHOLD.into(),
        max_forge_fee_pct: prior_contract::MAX_FORGE_FEE_PCT.into(),
        incentive: prior_contract::MAX_INCENTIVE.into(),
    };

    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    test_config.prior.set_trove_config(trove_id, config);

    let stored = test_config.prior.get_trove_config(trove_id);
    assert_eq!(
        stored.relative_threshold,
        prior_contract::MAX_RELATIVE_THRESHOLD.into(),
        "relative_threshold changed at max",
    );
    assert_eq!(
        stored.max_forge_fee_pct,
        prior_contract::MAX_FORGE_FEE_PCT.into(),
        "fee pct changed at max",
    );
    assert_eq!(stored.incentive, prior_contract::MAX_INCENTIVE.into(), "incentive changed at max");
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "PRI: Not trove owner")]
fn test_set_config_not_owner() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = prior_utils::USER;
    let prior_abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };
    let trove_id: u64 = prior_utils::open_trove_for_user(prior_abbot, user);

    // Config should exist but have default values
    cheat_caller_address(
        test_config.prior.contract_address, prior_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    test_config.prior.set_trove_config(trove_id, Default::default());
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_can_execute_rite_invalid_trove() {
    let test_config = prior_utils::prior_deploy(None);

    // No trove created - can_execute_rite should return false
    // (no rite attached, so is_ready would revert or return false)
    let can_execute = test_config.prior.can_execute_rite(1);
    assert(!can_execute, 'can_execute should be false');
}


