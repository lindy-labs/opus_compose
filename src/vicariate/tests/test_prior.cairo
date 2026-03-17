use core::num::traits::Zero;
use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, IGateDispatcher, IGateDispatcherTrait,
    IShrineDispatcherTrait,
};
use opus::types::{AssetBalance, Health};
use opus_compose::addresses::mainnet;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use opus_compose::vicariate::interfaces::prior::IPriorDispatcherTrait;
use opus_compose::vicariate::tests::utils::prior_utils;
use snforge_std::{CheatSpan, cheat_caller_address};
use starknet::ContractAddress;
use wadray::{RAY_ONE, Ray, Wad};

const USER: ContractAddress = 'test user'.try_into().unwrap();

//
// Test: Deployment
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_prior_deployment() {
    let test_config = prior_utils::prior_deploy(None);
    let prior = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    let zero_index = test_config.prior.get_trove_id_by_index(0);
    assert!(zero_index.is_zero(), "Index 0 should be empty");
    let one_index = test_config.prior.get_trove_id_by_index(1);
    assert!(one_index.is_zero(), "Index 1 should be empty");

    let atu_troves_count = prior.get_troves_count();
    assert!(atu_troves_count.is_zero(), "Troves count should be zero");
}

//
// Test: IAbbot Interface - Open Trove
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_open_trove_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user = USER;
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000; // 0.1 ETH
    let forge_amount: Wad = 50000000_u128.into(); // 50 CASH
    let max_forge_fee_pct: Wad = 1_u128.into(); // 1%

    let prior = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    let before_yin_balance = test_config.shrine.get_yin(user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = prior
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Verify trove owner
    let primary_owner = test_config.abbot.get_trove_owner(trove_id);
    assert!(primary_owner.is_some(), "Primary owner should exist");
    assert!(primary_owner.unwrap() == test_config.prior.contract_address, "Primary owner mismatch");

    let atu_owner = prior.get_trove_owner(trove_id);
    assert!(atu_owner.is_some(), "ATU owner should exist");
    assert!(atu_owner.unwrap() == user, "ATU owner mismatch");

    let atu_trove_id_by_index = test_config.prior.get_trove_id_by_index(1);
    assert_eq!(atu_trove_id_by_index, trove_id, "Wrong ATU trove ID by index");

    // Verify user's trove IDs
    let trove_ids = prior.get_user_trove_ids(user);
    assert(trove_ids.len() == 1, 'should have 1 trove');
    assert(*trove_ids.at(0) == trove_id, 'trove_id mismatch');

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
fn test_get_troves_count() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000; // 0.1 ETH
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Initial count should be 0
    let initial_count = abbot.get_troves_count();
    assert(initial_count == 0, 'initial count should be 0');

    // Fund and approve
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let _ = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Count should be 1
    let count = abbot.get_troves_count();
    assert(count == 1, 'count should be 1');
}

//
// Test: IAbbot Interface - Close Trove
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_close_trove_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Close trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    abbot.close_trove(trove_id);

    // Note: ATU Abbot no longer clears owner on close
    // The underlying Abbot trove is closed, but ATU tracking remains
    // Verify the close succeeded by checking owner still exists in ATU tracking
    let owner = abbot.get_trove_owner(trove_id);
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
#[should_panic(expected: "ATY: Not owner")]
fn test_close_trove_not_owner_reverts() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let other_user: ContractAddress = 'other user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove as user
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Try to close as other_user
    cheat_caller_address(test_config.prior.contract_address, other_user, CheatSpan::TargetCalls(1));
    abbot.close_trove(trove_id);
}

//
// Test: IAtuAbbot Interface - Config Management
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_get_trove_config_no_config() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove (but don't set config)
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Config should exist but have default values
    let config = test_config.prior.get_trove_config(trove_id);
    assert(config.is_some(), 'config should exist');
}

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_should_topup_returns_false_no_trove() {
    let test_config = prior_utils::prior_deploy(None);

    // No trove created - should return false
    let should = test_config.prior.should_topup(999);
    assert(!should, 'should_topup should be false');
}

//
// Test: IAbbot Interface - Deposit
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_deposit_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let deposit_amount: u128 = 50000000000000000; // 0.05 ETH
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Fund user (initial + deposit)
    let total_amount: u256 = (yang_amount + deposit_amount).into();
    prior_utils::fund_user_eth(user, total_amount);
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Deposit additional collateral
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    abbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });
    // No panic = success
}

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "ATY: Not owner")]
fn test_deposit_not_owner_reverts() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let other_user: ContractAddress = 'other user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Try deposit as other user
    cheat_caller_address(test_config.prior.contract_address, other_user, CheatSpan::TargetCalls(1));
    abbot.deposit(trove_id, AssetBalance { address: yang, amount: 1000 });
}

//
// Test: IAbbot Interface - Withdraw
//

#[test]
#[fork("MAINNET_VICARIATE")]
#[should_panic(expected: "ATY: Not owner")]
fn test_withdraw_not_owner_reverts() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let other_user: ContractAddress = 'other user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Try withdraw as other user
    cheat_caller_address(test_config.prior.contract_address, other_user, CheatSpan::TargetCalls(1));
    abbot.withdraw(trove_id, AssetBalance { address: yang, amount: 1000 });
}

//
// Test: IAbbot Interface - Forge
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_forge_success() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove with initial forge
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Forge additional CASH
    let additional_forge: Wad = 10000_u128.into();
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    abbot.forge(trove_id, additional_forge, max_forge_fee_pct);
    // No panic = success
}

//
// Test: Get Trove ID by Index
//

#[test]
#[fork("MAINNET_VICARIATE")]
fn test_get_trove_id_by_index() {
    let test_config = prior_utils::prior_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.prior.contract_address };

    // Setup
    prior_utils::fund_user_eth(user, yang_amount.into());
    prior_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    prior_utils::approve_for_user(test_config.prior.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.prior.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Get trove_id by index (1-indexed)
    let retrieved_id = test_config.prior.get_trove_id_by_index(1);
    assert(retrieved_id == trove_id, 'trove_id mismatch');
}
