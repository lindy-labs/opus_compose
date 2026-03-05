use opus::interfaces::{
    IAbbotDispatcher, IAbbotDispatcherTrait, IGateDispatcher, IGateDispatcherTrait,
};
use opus::types::AssetBalance;
use opus_compose::addresses::mainnet;
use opus_compose::atu_abbot::interfaces::atu_abbot::IAtuAbbotDispatcherTrait;
use opus_compose::atu_abbot::tests::utils::atu_abbot_utils;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{CheatSpan, cheat_caller_address};
use starknet::ContractAddress;
use wadray::{RAY_ONE, Ray, Wad};

// Helper function to get default relative threshold (80%)
// Returns 0.8 in Ray format
fn get_default_relative_threshold() -> Ray {
    // 80% = 8/10, so multiply RAY_ONE by 8 then divide by 10
    // This is computed at compile time
    let eighty_pct: u128 = 800000000000000000000000000; // 0.8 * 10^27
    eighty_pct.into()
}

//
// Test: Deployment
//

#[test]
#[fork("MAINNET_ATU")]
fn test_atu_abbot_deployment() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);

    // Verify deployment succeeded
    let troves_count = test_config.atu_abbot.get_trove_id_by_index(0);
    // Index 0 should return 0 (no troves yet)
    assert(troves_count == 0, 'initial count should be 0');
}

//
// Test: IAbbot Interface - Open Trove
//

#[test]
#[fork("MAINNET_ATU")]
fn test_open_trove_success() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000; // 0.1 ETH
    let forge_amount: Wad = 50000000_u128.into(); // 50 CASH
    let max_forge_fee_pct: Wad = 1_u128.into(); // 1%

    // Create IAbbotDispatcher pointing to atu_abbot contract
    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Fund user with ETH
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());

    // Approve gate for ETH
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);

    // Approve atu_abbot for ETH
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Verify trove owner
    let owner = abbot.get_trove_owner(trove_id);
    assert(owner.is_some(), 'owner should exist');
    assert(owner.unwrap() == user, 'owner mismatch');

    // Verify user's trove IDs
    let trove_ids = abbot.get_user_trove_ids(user);
    println!("trove ids len: {}", trove_ids.len());
    assert(trove_ids.len() == 1, 'should have 1 trove');
    assert(*trove_ids.at(0) == trove_id, 'trove_id mismatch');
}

#[test]
#[fork("MAINNET_ATU")]
fn test_get_troves_count() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000; // 0.1 ETH
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Initial count should be 0
    let initial_count = abbot.get_troves_count();
    assert(initial_count == 0, 'initial count should be 0');

    // Fund and approve
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
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
#[fork("MAINNET_ATU")]
fn test_close_trove_success() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Setup
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Close trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    abbot.close_trove(trove_id);

    // Verify owner cleared
    let owner = abbot.get_trove_owner(trove_id);
    assert(owner.is_none(), 'owner should be cleared');
}

#[test]
#[fork("MAINNET_ATU")]
#[should_panic(expected: "ATY: Not owner")]
fn test_close_trove_not_owner_reverts() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let other_user: ContractAddress = 'other user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Setup
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove as user
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Try to close as other_user
    cheat_caller_address(
        test_config.atu_abbot.contract_address, other_user, CheatSpan::TargetCalls(1),
    );
    abbot.close_trove(trove_id);
}

//
// Test: IAtuAbbot Interface - Config Management
//

#[test]
#[fork("MAINNET_ATU")]
fn test_get_trove_config_no_config() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Setup
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove (but don't set config)
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Config should exist but have default values
    let config = test_config.atu_abbot.get_trove_config(trove_id);
    assert(config.is_some(), 'config should exist');
}

#[test]
#[fork("MAINNET_ATU")]
fn test_should_topup_returns_false_no_trove() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);

    // No trove created - should return false
    let should = test_config.atu_abbot.should_topup(999);
    assert(!should, 'should_topup should be false');
}

//
// Test: IAbbot Interface - Deposit
//

#[test]
#[fork("MAINNET_ATU")]
fn test_deposit_success() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let deposit_amount: u128 = 50000000000000000; // 0.05 ETH
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Fund user (initial + deposit)
    let total_amount: u256 = (yang_amount + deposit_amount).into();
    atu_abbot_utils::fund_user_eth(user, total_amount);
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Deposit additional collateral
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    abbot.deposit(trove_id, AssetBalance { address: yang, amount: deposit_amount });
    // No panic = success
}

#[test]
#[fork("MAINNET_ATU")]
#[should_panic(expected: "ATY: Not owner")]
fn test_deposit_not_owner_reverts() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let other_user: ContractAddress = 'other user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Setup
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Try deposit as other user
    cheat_caller_address(
        test_config.atu_abbot.contract_address, other_user, CheatSpan::TargetCalls(1),
    );
    abbot.deposit(trove_id, AssetBalance { address: yang, amount: 1000 });
}

//
// Test: IAbbot Interface - Withdraw
//

#[test]
#[fork("MAINNET_ATU")]
#[should_panic(expected: "ATY: Not owner")]
fn test_withdraw_not_owner_reverts() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let other_user: ContractAddress = 'other user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Setup
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Try withdraw as other user
    cheat_caller_address(
        test_config.atu_abbot.contract_address, other_user, CheatSpan::TargetCalls(1),
    );
    abbot.withdraw(trove_id, AssetBalance { address: yang, amount: 1000 });
}

//
// Test: IAbbot Interface - Forge
//

#[test]
#[fork("MAINNET_ATU")]
fn test_forge_success() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Setup
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove with initial forge
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Forge additional CASH
    let additional_forge: Wad = 10000_u128.into();
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    abbot.forge(trove_id, additional_forge, max_forge_fee_pct);
    // No panic = success
}

//
// Test: Get Trove ID by Index
//

#[test]
#[fork("MAINNET_ATU")]
fn test_get_trove_id_by_index() {
    let test_config = atu_abbot_utils::atu_abbot_deploy(None);
    let user: ContractAddress = 'test user'.try_into().unwrap();
    let yang = mainnet::ETH;
    let yang_amount: u128 = 100000000000000000;
    let forge_amount: Wad = 50000000_u128.into();
    let max_forge_fee_pct: Wad = 1_u128.into();

    let abbot = IAbbotDispatcher { contract_address: test_config.atu_abbot.contract_address };

    // Setup
    atu_abbot_utils::fund_user_eth(user, yang_amount.into());
    atu_abbot_utils::approve_gate_for_user(test_config.eth_gate, yang, user);
    atu_abbot_utils::approve_for_user(test_config.atu_abbot.contract_address, yang, user);

    // Open trove
    cheat_caller_address(test_config.atu_abbot.contract_address, user, CheatSpan::TargetCalls(1));
    let trove_id = abbot
        .open_trove(
            array![AssetBalance { address: yang, amount: yang_amount }].span(),
            forge_amount,
            max_forge_fee_pct,
        );

    // Get trove_id by index (1-indexed)
    let retrieved_id = test_config.atu_abbot.get_trove_id_by_index(1);
    assert(retrieved_id == trove_id, 'trove_id mismatch');
}
