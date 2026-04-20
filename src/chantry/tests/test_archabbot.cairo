use core::num::traits::Zero;
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, IShrineDispatcherTrait,
};
use opus::types::{AssetBalance, Health};
use opus::utils::assertions::assert_equalish;
use opus_compose::addresses::mainnet;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use opus_compose::chantry::contracts::archabbot::archabbot as archabbot_contract;
use opus_compose::chantry::interfaces::archabbot::IArchabbotDispatcherTrait;
use opus_compose::chantry::tests::utils::archabbot_utils;
use opus_compose::chantry::types::TroveConfig;
use snforge_std::{CheatSpan, cheat_caller_address};
use starknet::ContractAddress;
use wadray::{WAD_ONE, Wad};

const EXISTING_TROVE_ID: u64 = 1;

//
// Deployment
//

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_archabbot_deployment() {
    let abbot = IAbbotDispatcher { contract_address: mainnet::ABBOT };
    let legacy_troves_count: u64 = abbot.get_troves_count();

    let test_config = archabbot_utils::archabbot_deploy(None);
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    let troves_count = archabbot.get_troves_count();
    assert_eq!(troves_count, legacy_troves_count, "Wrong starting troves count");
}

//
// Abbot functions
//

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_open_trove_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user = archabbot_utils::USER;
    let yang = mainnet::ETH;
    let yang_amount: u128 = WAD_ONE / 10; // 0.1 ETH
    let forge_amount: Wad = (50 * WAD_ONE).into(); // 50 CASH
    let max_forge_fee_pct: Wad = Zero::zero();

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let count = archabbot.get_troves_count();

    archabbot_utils::fund_user_eth(user, yang_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    let before_yin_balance = test_config.shrine.get_yin(user);

    // Open trove
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = archabbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    let expected_count = count + 1;
    let count = archabbot.get_troves_count();
    assert_eq!(count, expected_count, "Wrong troves count");

    let trove_owner = archabbot.get_trove_owner(trove_id);
    assert!(trove_owner.is_some(), "Smart Trove owner should exist");
    assert!(trove_owner.unwrap() == user, "Smart Trove owner mismatch");

    // Verify user's trove IDs
    let trove_ids = archabbot.get_user_trove_ids(user);
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
#[fork("MAINNET_CHANTRY")]
fn test_close_trove_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let yang = mainnet::ETH;
    let yang_amount: u128 = WAD_ONE;
    let forge_amount: Wad = (5 * WAD_ONE).into();
    let max_forge_fee_pct: Wad = Zero::zero();

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    // Setup
    archabbot_utils::fund_user_eth(user, yang_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    // Open trove
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = archabbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Close trove
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.archabbot.contract_address, forge_amount.into());
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.close_trove(trove_id);

    let owner = archabbot.get_trove_owner(trove_id);
    assert(owner.is_some(), 'owner should still exist');

    // Verify trove deposit is zero after close
    let deposit = test_config.shrine.get_deposit(yang, trove_id);
    assert(deposit.is_zero(), 'deposit should be zero');

    // Verify trove debt is zero after close
    let trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    assert(trove_health.debt.is_zero(), 'debt should be zero');
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_close_trove_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.close_trove(trove_id);
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_deposit_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let yang: ContractAddress = mainnet::ETH;
    let deposit_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);
    let before_yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);

    // Deposit additional collateral
    archabbot_utils::fund_user_eth(user, deposit_amount.into());
    archabbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });

    let after_yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    let expected_yang_deposit: Wad = before_yang_deposit + deposit_amount.into();
    let error_margin: Wad = 20_u128.into();
    assert_equalish(
        after_yang_deposit, expected_yang_deposit, error_margin, 'Wrong yang deposit amount',
    );
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_deposit_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let yang: ContractAddress = mainnet::ETH;
    let deposit_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_withdraw_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let yang: ContractAddress = mainnet::ETH;
    let yang_erc20 = IERC20Dispatcher { contract_address: yang };
    let deposit_amount: u128 = WAD_ONE / 10; // 0.1 ETH

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    let before_yang_balance: u256 = yang_erc20.balance_of(user);

    // Repay and withdraw collateral
    let trove_health: Health = test_config.shrine.get_trove_health(trove_id);
    let repay_amount: Wad = trove_health.debt;
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.archabbot.contract_address, repay_amount.into());
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(2));
    archabbot.melt(trove_id, trove_health.debt);
    archabbot.withdraw(trove_id, AssetBalance { address: yang, amount: deposit_amount });

    let after_yang_balance: u256 = yang_erc20.balance_of(user);
    let expected_yang_balance: u256 = before_yang_balance + deposit_amount.into();
    let error_margin: u256 = 1_u128.into();
    assert_equalish(after_yang_balance, expected_yang_balance, error_margin, 'Wrong yang balance');
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_withdraw_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let yang: ContractAddress = mainnet::ETH;

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.withdraw(trove_id, AssetBalance { address: yang, amount: WAD_ONE / 100 });
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_forge_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    let before_balance: Wad = test_config.shrine.get_yin(user);

    // Forge additional CASH
    let forge_amount: Wad = WAD_ONE.into();
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.forge(trove_id, forge_amount, Zero::zero());

    let after_balance: Wad = test_config.shrine.get_yin(user);
    let expected_balance: Wad = before_balance + forge_amount;
    assert_eq!(after_balance, expected_balance, "Wrong yin balance");
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_melt_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    let before_health: Health = test_config.shrine.get_trove_health(trove_id);

    // Forge additional CASH
    let melt_amount: Wad = (WAD_ONE / 10).into();
    cheat_caller_address(test_config.shrine.contract_address, user, CheatSpan::TargetCalls(1));
    IERC20Dispatcher { contract_address: test_config.shrine.contract_address }
        .approve(test_config.archabbot.contract_address, melt_amount.into());
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.melt(trove_id, melt_amount);

    let after_health: Health = test_config.shrine.get_trove_health(trove_id);
    let expected_debt: Wad = before_health.debt - melt_amount;
    assert_eq!(after_health.debt, expected_debt, "Wrong debt");
}


//
// Archabbot functions
//

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_default_config() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    // Config should exist but have default values
    let config = test_config.archabbot.get_trove_config(trove_id);
    assert_eq!(config, Default::default(), "Wrong default config");
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_set_config_capped() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

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
    assert_eq!(stored.incentive, archabbot_contract::MAX_INCENTIVE.into(), "Max incentive not capped");
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_set_config_exact_max_values() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

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
    assert_eq!(stored.incentive, archabbot_contract::MAX_INCENTIVE.into(), "incentive changed at max");
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_set_config_not_owner() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = archabbot_utils::USER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };
    let trove_id: u64 = archabbot_utils::open_trove_for_user(archabbot, user);

    // Config should exist but have default values
    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    test_config.archabbot.set_trove_config(trove_id, Default::default());
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_can_execute_rite_invalid_trove() {
    let test_config = archabbot_utils::archabbot_deploy(None);

    // No trove created - can_execute_rite should return false
    // (no rite attached, so is_ready would revert or return false)
    let can_execute = test_config.archabbot.can_execute_rite(1);
    assert(!can_execute, 'can_execute should be false');
}

// ---------------------------------------------------------------------------
// Existing (legacy) trove tests — uses EXISTING_TROVE_ID owned by
// EXISTING_TROVE_OWNER on mainnet. Archabbot delegates owner lookups for legacy
// troves to the real Abbot contract.
// ---------------------------------------------------------------------------


#[test]
#[fork("MAINNET_CHANTRY")]
fn test_legacy_trove_ownership() {
    let test_config = archabbot_utils::archabbot_deploy(None);

    let user: ContractAddress = mainnet::EXISTING_TROVE_OWNER;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    // Verify ownership of the existing legacy trove
    let owner = archabbot.get_trove_owner(EXISTING_TROVE_ID);
    assert!(owner.is_some(), "no owner");
    assert!(owner.unwrap() == user, "wrong owner");
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_existing_trove_deposit_success() {
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

    // Deposit into existing legacy trove
    cheat_caller_address(test_config.archabbot.contract_address, user, CheatSpan::TargetCalls(1));
    archabbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });

    let after_yang_deposit: Wad = test_config.shrine.get_deposit(yang, trove_id);
    let expected_yang_deposit: Wad = before_yang_deposit + deposit_amount.into();
    let error_margin: Wad = 20_u128.into();
    assert_equalish(
        after_yang_deposit, expected_yang_deposit, error_margin, 'Wrong yang deposit amount',
    );
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_existing_trove_withdraw_success() {
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
    archabbot.withdraw(
        trove_id, AssetBalance { address: yang, amount: withdraw_amount },
    );

    let after_yang_balance: u256 = yang_erc20.balance_of(user);
    let expected_yang_balance: u256 = before_yang_balance + withdraw_amount.into();
    let error_margin: u256 = 1_u128.into();
    assert_equalish(after_yang_balance, expected_yang_balance, error_margin, 'Wrong yang balance');
}

#[test]
#[fork("MAINNET_CHANTRY")]
fn test_existing_trove_forge_success() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let user: ContractAddress = mainnet::EXISTING_TROVE_OWNER;
    let trove_id: u64 = EXISTING_TROVE_ID;
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    let before_balance: Wad = test_config.shrine.get_yin(user);
    let before_trove_health: Health = test_config.shrine.get_trove_health(trove_id);

    // Forge additional CASH into existing legacy trove
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
#[fork("MAINNET_CHANTRY")]
fn test_existing_trove_melt_success() {
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
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_existing_trove_close_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.close_trove(EXISTING_TROVE_ID);
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_existing_trove_deposit_not_owner_reverts() {
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
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_existing_trove_withdraw_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);
    let yang: ContractAddress = mainnet::ETH;

    let archabbot = IAbbotDispatcher { contract_address: test_config.archabbot.contract_address };

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    archabbot.withdraw(
        EXISTING_TROVE_ID, AssetBalance { address: yang, amount: WAD_ONE / 100 },
    );
}

#[test]
#[fork("MAINNET_CHANTRY")]
#[should_panic(expected: "ARC: Not trove owner")]
fn test_existing_trove_set_config_not_owner_reverts() {
    let test_config = archabbot_utils::archabbot_deploy(None);

    cheat_caller_address(
        test_config.archabbot.contract_address, archabbot_utils::BAD_GUY, CheatSpan::TargetCalls(1),
    );
    test_config.archabbot.set_trove_config(EXISTING_TROVE_ID, Default::default());
}
