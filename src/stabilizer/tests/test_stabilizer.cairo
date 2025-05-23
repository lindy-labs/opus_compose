use core::num::traits::Zero;
use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use opus::interfaces::{
    IEqualizerDispatcher, IEqualizerDispatcherTrait, IShrineDispatcher, IShrineDispatcherTrait,
};
use opus::utils::assert_equalish;
use opus_compose::addresses::mainnet;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use opus_compose::stabilizer::constants::{BOUNDS, LOWER_TICK_MAG, POOL_KEY, UPPER_TICK_MAG};
use opus_compose::stabilizer::contracts::stabilizer::stabilizer as stabilizer_contract;
use opus_compose::stabilizer::interfaces::stabilizer::IStabilizerDispatcherTrait;
use opus_compose::stabilizer::math::get_cumulative_delta;
use opus_compose::stabilizer::periphery::frontend_data_provider::IFrontendDataProviderDispatcherTrait;
use opus_compose::stabilizer::tests::utils::stabilizer_utils::{
    StabilizerTestConfig, USDC_DECIMALS_DIFF_SCALE, create_ekubo_position, create_surplus,
    create_valid_ekubo_position, fund_three_users, setup, stake_ekubo_position,
};
use opus_compose::stabilizer::types::{Stake, YieldState};
use snforge_std::{
    DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use wadray::{WAD_ONE, Wad};


#[test]
#[fork("MAINNET_STABILIZER")]
fn test_setup() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);

    assert(stabilizer.get_total_liquidity().is_zero(), 'Wrong starting liquidity');

    assert!(stabilizer.get_pool_key() == POOL_KEY(), "Wrong pool key");
    assert!(stabilizer.get_bounds() == BOUNDS(), "Wrong bounds");

    let yield_state = stabilizer.get_yield_state();
    assert(yield_state.yin_balance_snapshot.is_zero(), 'Wrong starting yin balance');
    assert(yield_state.yin_per_liquidity.is_zero(), 'Wrong starting yin/liquidity');
}

#[test]
#[fork("MAINNET_STABILIZER")]
fn test_stake() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };
    let shrine = IShrineDispatcher { contract_address: mainnet::SHRINE };

    let mut spy = spy_events();

    let surplus: Wad = (1000 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    let before_surplus = shrine.get_budget();

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();
    let (position_id, position_liquidity) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );

    let before_total_liquidity = stabilizer.get_total_liquidity();

    stake_ekubo_position(positions_nft, stabilizer, user, position_id);
    assert_eq!(
        positions_nft.owner_of(position_id.into()),
        stabilizer.contract_address,
        "Wrong owner after staking",
    );
    assert_eq!(stabilizer.get_token_id_for_user(user).unwrap(), position_id, "Wrong user token id");

    let after_total_liquidity = stabilizer.get_total_liquidity();
    assert_eq!(
        after_total_liquidity, before_total_liquidity + position_liquidity, "Wrong total liquidity",
    );

    // Yin balance snapshot is not updated because total liquidity is zero before first stake
    let yield_state = stabilizer.get_yield_state();
    assert(yield_state.yin_balance_snapshot.is_zero(), 'Wrong yin balance snapshot');
    assert(yield_state.yin_per_liquidity.is_zero(), 'Wrong yin/liquidity');

    let stake = stabilizer.get_stake(user);
    assert_eq!(stake.liquidity, position_liquidity, "Wrong Stake liquidity");
    assert(stake.yin_per_liquidity_snapshot.is_zero(), 'Wrong Stake last cumulative');

    // Assert that the Shrine's surplus is not equalized for first stake
    assert_eq!(shrine.get_budget(), before_surplus, "Budget mismatch");

    let expected_events = array![
        (
            stabilizer.contract_address,
            stabilizer_contract::Event::Staked(
                stabilizer_contract::Staked {
                    user, token_id: position_id, stake, total_liquidity: after_total_liquidity,
                },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: No liquidity found")]
fn test_stake_wrong_lower_tick_fail() {
    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();

    let lower_tick_mag = LOWER_TICK_MAG + 200; // 0.989886
    let bounds = Bounds {
        lower: i129 { mag: lower_tick_mag, sign: true },
        upper: i129 { mag: UPPER_TICK_MAG, sign: true },
    };
    let (position_id, _) = create_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, POOL_KEY(), bounds, lp_amount,
    );

    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.stake(position_id);
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: No liquidity found")]
fn test_stake_wrong_upper_tick_fail() {
    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();

    let upper_tick_mag = UPPER_TICK_MAG + 200;
    let bounds = Bounds {
        lower: i129 { mag: LOWER_TICK_MAG, sign: true },
        upper: i129 { mag: upper_tick_mag, sign: true },
    };
    let (position_id, _) = create_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, POOL_KEY(), bounds, lp_amount,
    );

    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.stake(position_id);
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: Not owner")]
fn test_non_owner_stake_fail() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();
    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );

    start_cheat_caller_address(positions_nft.contract_address, user);
    positions_nft.approve(stabilizer.contract_address, position_id.into());
    stop_cheat_caller_address(positions_nft.contract_address);

    let non_owner = 'non owner'.try_into().unwrap();
    start_cheat_caller_address(stabilizer.contract_address, non_owner);
    stabilizer.stake(position_id);
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: Already staked")]
fn test_double_stake_fail() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();

    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );
    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );
    stake_ekubo_position(positions_nft, stabilizer, user, position_id);
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: Token not approved")]
fn test_stake_unapproved_fail() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();

    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.stake(position_id);
    stop_cheat_caller_address(stabilizer.contract_address);
}

// Check that a user can claim for yin when either:
// 1. yin is already in the contract before staking; or
// 2. yin is sent to the contract after staking
// and nothing happens on a subsequent reclaim with no new yin in Stabilizer
#[test]
#[fork("MAINNET_STABILIZER")]
fn test_claim() {
    let stabilizer_class = *(declare("stabilizer").unwrap().contract_class());

    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };
    let yin = IERC20Dispatcher { contract_address: mainnet::SHRINE };

    let surplus_before_stake_cases = array![true, false].span();

    for surplus_before_stake in surplus_before_stake_cases {
        let StabilizerTestConfig { stabilizer, .. } = setup(Option::Some(stabilizer_class));
        let mut spy = spy_events();

        let surplus: Wad = (1000 * WAD_ONE).into();
        if *surplus_before_stake {
            create_surplus(mainnet::SHRINE, surplus);
            let equalizer = IEqualizerDispatcher { contract_address: mainnet::EQUALIZER };
            equalizer.equalize();
            equalizer.allocate();
        }

        let user = mainnet::MULTISIG;
        let lp_amount: u256 = (1000 * WAD_ONE).into();
        let (position_id, position_liquidity) = create_valid_ekubo_position(
            mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
        );
        stake_ekubo_position(positions_nft, stabilizer, user, position_id);

        if !(*surplus_before_stake) {
            create_surplus(mainnet::SHRINE, surplus);
        }

        let before_user_yin: u256 = yin.balance_of(user);
        let before_total_liquidity: u128 = stabilizer.get_total_liquidity();

        start_cheat_caller_address(stabilizer.contract_address, user);
        stabilizer.claim();
        stop_cheat_caller_address(stabilizer.contract_address);

        let after_user_yin: u256 = yin.balance_of(user);
        let claimed_yin_amt = after_user_yin - before_user_yin;
        let error_margin: u256 = 1;
        assert_equalish(claimed_yin_amt, surplus.into(), error_margin, 'Wrong claimed yin balance');

        let yield_state = stabilizer.get_yield_state();
        let expected_cumulative = get_cumulative_delta(surplus.into(), position_liquidity);
        assert_eq!(yield_state.yin_per_liquidity, expected_cumulative, "Wrong yin/liquidity");

        let expected_yin_balance_snapshot = surplus.into() - claimed_yin_amt;
        assert_eq!(
            yield_state.yin_balance_snapshot,
            expected_yin_balance_snapshot,
            "Wrong yin balance snapshot",
        );

        let stake = stabilizer.get_stake(user);
        assert_eq!(
            stake.yin_per_liquidity_snapshot,
            yield_state.yin_per_liquidity,
            "Wrong Stake last cumulative",
        );

        let expected_yield_state_at_harvest = YieldState {
            yin_balance_snapshot: yin.balance_of(stabilizer.contract_address) + claimed_yin_amt,
            yin_per_liquidity: yield_state.yin_per_liquidity,
        };
        let expected_events = array![
            (
                stabilizer.contract_address,
                stabilizer_contract::Event::Claimed(
                    stabilizer_contract::Claimed { user, amount: claimed_yin_amt },
                ),
            ),
            (
                stabilizer.contract_address,
                stabilizer_contract::Event::YieldStateUpdated(
                    stabilizer_contract::YieldStateUpdated {
                        yield_state: expected_yield_state_at_harvest,
                    },
                ),
            ),
            (
                stabilizer.contract_address,
                stabilizer_contract::Event::Harvested(
                    stabilizer_contract::Harvested {
                        total_liquidity: before_total_liquidity, amount: surplus.into(),
                    },
                ),
            ),
            (
                stabilizer.contract_address,
                stabilizer_contract::Event::YieldStateUpdated(
                    stabilizer_contract::YieldStateUpdated { yield_state },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        // Nothing happens if user claims again
        start_cheat_caller_address(stabilizer.contract_address, user);
        stabilizer.claim();
        stop_cheat_caller_address(stabilizer.contract_address);

        assert_eq!(yin.balance_of(user), after_user_yin, "Yin balance changed");
        assert_eq!(stabilizer.get_stake(user), stake, "Stake changed");
    }
}

#[test]
#[fork("MAINNET_STABILIZER")]
fn test_claim_small_surplus_precision_loss() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };
    let yin = IERC20Dispatcher { contract_address: mainnet::SHRINE };

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = 1000000000000_u128.into(); // 10 ** 12 wei
    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );
    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    // Equalizer has a 1 wei of CASH at the given block, so we can allocate it directly
    let surplus: Wad = 1_u128.into(); // 1 wei (Wad)
    assert_eq!(yin.balance_of(mainnet::EQUALIZER), surplus.into(), "Wrong equalizer balance");
    IEqualizerDispatcher { contract_address: mainnet::EQUALIZER }.allocate();
    assert_eq!(yin.balance_of(stabilizer.contract_address), surplus.into(), "Wrong stabilizer yin");

    let before_user_yin: u256 = yin.balance_of(user);

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.claim();
    stop_cheat_caller_address(stabilizer.contract_address);

    // Precision loss so the 1 wei is lost forever
    let after_user_yin: u256 = yin.balance_of(user);
    assert_eq!(after_user_yin, before_user_yin, "No precision loss");

    let surplus: Wad = 2_u128.into(); // 2 wei (Wad)
    create_surplus(mainnet::SHRINE, surplus);

    let before_user_yin = after_user_yin;

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.claim();
    stop_cheat_caller_address(stabilizer.contract_address);

    let after_user_yin: u256 = yin.balance_of(user);

    let expected_user_yin: u256 = before_user_yin + surplus.into();
    let error_margin = 1_u256;
    // loss of precision of 1 wei
    assert_equalish(after_user_yin, expected_user_yin, error_margin, 'Wrong surplus');
}

#[test]
#[fork("MAINNET_STABILIZER")]
fn test_claim_large_surplus_with_low_liquidity_no_overflow() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };
    let yin = IERC20Dispatcher { contract_address: mainnet::SHRINE };

    let surplus: Wad = (1000000000000 * WAD_ONE).into(); // 1_000_000_000_000 (Wad)
    create_surplus(mainnet::SHRINE, surplus);

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = 1000000000000_u128.into(); // 10 ** 12 wei
    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );
    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    let before_user_yin: u256 = yin.balance_of(user);

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.claim();
    stop_cheat_caller_address(stabilizer.contract_address);

    let after_user_yin: u256 = yin.balance_of(user);
    let expected_user_yin: u256 = before_user_yin + surplus.into();
    let error_margin = 1;
    assert_equalish(after_user_yin, expected_user_yin, error_margin, 'Wrong surplus');
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: No stake found")]
fn test_non_user_claim_fail() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };

    let surplus: Wad = (1000 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();
    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );
    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    let non_user = 'non user'.try_into().unwrap();
    start_cheat_caller_address(stabilizer.contract_address, non_user);
    stabilizer.claim();
}

#[test]
#[fork("MAINNET_STABILIZER")]
fn test_unstake() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };
    let yin = IERC20Dispatcher { contract_address: mainnet::SHRINE };

    let mut spy = spy_events();

    let surplus: Wad = (1000 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();
    let (position_id, position_liquidity) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );

    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    let before_stake = stabilizer.get_stake(user);
    let before_user_yin: u256 = yin.balance_of(user);
    let before_total_liquidity = stabilizer.get_total_liquidity();

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.unstake();
    stop_cheat_caller_address(stabilizer.contract_address);

    assert_eq!(positions_nft.owner_of(position_id.into()), user, "Wrong owner after unstaking");

    let after_user_yin: u256 = yin.balance_of(user);
    let yin_claimed: u256 = after_user_yin - before_user_yin;
    let error_margin = 1;
    assert_equalish(yin_claimed, surplus.into(), error_margin, 'Wrong yin balance');

    let after_total_liquidity = stabilizer.get_total_liquidity();
    assert(after_total_liquidity.is_zero(), 'Wrong total liquidity');

    let after_yield_state = stabilizer.get_yield_state();
    let expected_yin_per_liquidity = get_cumulative_delta(surplus.into(), position_liquidity);
    assert_eq!(
        after_yield_state.yin_per_liquidity, expected_yin_per_liquidity, "Wrong yin/liquidity",
    );

    // Stake should not be updated during an unstake
    let after_stake = stabilizer.get_stake(user);
    assert_eq!(after_stake, before_stake, "Stake changed");

    let expected_yield_state_at_harvest = YieldState {
        yin_balance_snapshot: yin.balance_of(stabilizer.contract_address) + yin_claimed,
        yin_per_liquidity: after_yield_state.yin_per_liquidity,
    };
    let expected_stake_for_unstaked_event = Stake {
        liquidity: before_stake.liquidity,
        yin_per_liquidity_snapshot: after_yield_state.yin_per_liquidity,
    };
    let expected_events = array![
        (
            stabilizer.contract_address,
            stabilizer_contract::Event::Unstaked(
                stabilizer_contract::Unstaked {
                    user,
                    token_id: position_id,
                    stake: expected_stake_for_unstaked_event,
                    total_liquidity: after_total_liquidity,
                },
            ),
        ),
        (
            stabilizer.contract_address,
            stabilizer_contract::Event::YieldStateUpdated(
                stabilizer_contract::YieldStateUpdated {
                    yield_state: expected_yield_state_at_harvest,
                },
            ),
        ),
        (
            stabilizer.contract_address,
            stabilizer_contract::Event::Harvested(
                stabilizer_contract::Harvested {
                    total_liquidity: before_total_liquidity, amount: surplus.into(),
                },
            ),
        ),
        (
            stabilizer.contract_address,
            stabilizer_contract::Event::YieldStateUpdated(
                stabilizer_contract::YieldStateUpdated { yield_state: after_yield_state },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: No stake found")]
fn test_claim_after_unstake_fail() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };

    let surplus: Wad = (1000 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();
    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );

    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.unstake();
    stabilizer.claim();
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: No stake found")]
fn test_double_unstake_fail() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };

    let surplus: Wad = (1000 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();
    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );

    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    start_cheat_caller_address(stabilizer.contract_address, user);
    stabilizer.unstake();
    stabilizer.unstake();
}

#[test]
#[fork("MAINNET_STABILIZER")]
#[should_panic(expected: "STB: No stake found")]
fn test_non_user_unstake_fail() {
    let StabilizerTestConfig { stabilizer, .. } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };

    let surplus: Wad = (1000 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    let user = mainnet::MULTISIG;
    let lp_amount: u256 = (1000 * WAD_ONE).into();
    let (position_id, _) = create_valid_ekubo_position(
        mainnet::SHRINE, mainnet::EKUBO_POSITIONS, user, lp_amount,
    );
    stake_ekubo_position(positions_nft, stabilizer, user, position_id);

    let non_user = 'non user'.try_into().unwrap();
    start_cheat_caller_address(stabilizer.contract_address, non_user);
    stabilizer.unstake();
}

// Sequence of events:
// 1. Three users stake.
// 2. Surplus is distributed
// 3. Second user unstakes
// 4. First user claims
// 5. Surplus is distributed
// 6. Third user unstakes
// 7. Surplus is distributed
// 8. First user claims
#[test]
#[fork("MAINNET_STABILIZER")]
fn test_multi_users() {
    let StabilizerTestConfig { stabilizer, fdp } = setup(Option::None);
    let positions_nft = IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT };
    let yin = IERC20Dispatcher { contract_address: mainnet::SHRINE };

    let user1_yin_amt: u256 = (300 * WAD_ONE).into();
    let user2_yin_amt: u256 = (200 * WAD_ONE).into();
    let user3_yin_amt: u256 = (500 * WAD_ONE).into();

    let users_yin_amts = array![user1_yin_amt, user2_yin_amt, user3_yin_amt].span();
    let users = fund_three_users(mainnet::SHRINE, mainnet::MULTISIG, users_yin_amts);

    let user1 = *users.at(0);
    let user2 = *users.at(1);
    let user3 = *users.at(2);

    let mut users_yin_amts_copy = users_yin_amts;

    let mut users_position_ids: Array<u64> = array![];
    let mut users_liquidity: Array<u128> = array![];
    let mut expected_total_liquidity = 0_u128;

    // Step 1: Three users stakes
    for user in users {
        let user_yin_amt = *users_yin_amts_copy.pop_front().unwrap();

        let (user_position_id, user_liquidity) = create_valid_ekubo_position(
            yin.contract_address, mainnet::EKUBO_POSITIONS, *user, user_yin_amt,
        );
        stake_ekubo_position(positions_nft, stabilizer, *user, user_position_id);

        let stake = stabilizer.get_stake(*user);
        assert_eq!(stake.liquidity, user_liquidity, "Wrong user liquidity");
        assert(stake.yin_per_liquidity_snapshot.is_zero(), 'Wrong user yin/liquidity');

        users_position_ids.append(user_position_id);
        users_liquidity.append(user_liquidity);
        expected_total_liquidity += user_liquidity;
    }

    let pool_info = fdp.get_pool_info(stabilizer.contract_address);
    // Sanity check that the pool does not consist entirely of one token
    assert!(pool_info.token0_amount >= (100 * WAD_ONE).into(), "token0 sanity check");
    assert!(
        pool_info
            .token0_amount >= (100 * WAD_ONE / USDC_DECIMALS_DIFF_SCALE.try_into().unwrap())
            .into(),
        "token1 sanity check",
    );

    let total_liquidity = stabilizer.get_total_liquidity();
    assert_eq!(total_liquidity, expected_total_liquidity, "Wrong total liquidity #1");

    // Step 2: Surplus is distributed
    let surplus: Wad = (1000 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    // Step 3: Second user unstakes
    let user2_stake = stabilizer.get_stake(user2);
    let before_user2_yin_balance = yin.balance_of(user2);

    start_cheat_caller_address(stabilizer.contract_address, user2);
    stabilizer.unstake();
    stop_cheat_caller_address(stabilizer.contract_address);

    assert(stabilizer.get_token_id_for_user(user2).is_none(), 'Wrong token id after unstaking');

    let user2_position_id = *users_position_ids.at(1);
    assert_eq!(
        positions_nft.owner_of(user2_position_id.into()), user2, "Wrong owner after unstaking",
    );

    let user2_liquidity = *users_liquidity.at(1);
    expected_total_liquidity -= user2_liquidity;
    assert_eq!(
        stabilizer.get_total_liquidity(), expected_total_liquidity, "Wrong total liquidity #2",
    );

    let expected_user2_yin_yield = (200 * WAD_ONE).into();
    let after_user2_yin_balance = yin.balance_of(user2);
    let user2_yin_yield = after_user2_yin_balance - before_user2_yin_balance;
    let error_margin = 10_256;
    assert_equalish(
        user2_yin_yield, expected_user2_yin_yield, error_margin, 'Wrong yield for user 2',
    );

    let mut expected_yin_balance_snapshot = surplus.into() - user2_yin_yield;
    let yield_state = stabilizer.get_yield_state();
    assert_eq!(
        yield_state.yin_balance_snapshot,
        expected_yin_balance_snapshot,
        "Wrong yin balance snapshot #1",
    );

    // Stake should not change during an unstake
    assert(stabilizer.get_token_id_for_user(user2).is_none(), 'Wrong user 2 token id');
    assert_eq!(stabilizer.get_stake(user2), user2_stake, "Stake changed");

    // Step 4: First user claims
    let before_user1_yin_balance = yin.balance_of(user1);

    start_cheat_caller_address(stabilizer.contract_address, user1);
    stabilizer.claim();
    stop_cheat_caller_address(stabilizer.contract_address);

    let expected_user1_yin_yield = (300 * WAD_ONE).into();
    let after_user1_yin_balance = yin.balance_of(user1);
    let user1_yin_yield = after_user1_yin_balance - before_user1_yin_balance;
    let error_margin = 10_256;
    assert_equalish(
        user1_yin_yield, expected_user1_yin_yield, error_margin, 'Wrong yield for user 1 #1',
    );

    expected_yin_balance_snapshot -= user1_yin_yield;
    let yield_state = stabilizer.get_yield_state();
    assert_eq!(
        yield_state.yin_balance_snapshot,
        expected_yin_balance_snapshot,
        "Wrong yin balance snapshot #2",
    );

    let user1_stake = stabilizer.get_stake(user1);
    assert_eq!(
        user1_stake.yin_per_liquidity_snapshot,
        yield_state.yin_per_liquidity,
        "Wrong yin/liquidity for user 1 #1",
    );

    // Step 5: Surplus is distributed
    let surplus: Wad = (800 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    // Step 6: Third user unstakes
    let before_user3_yin_balance = yin.balance_of(user3);

    start_cheat_caller_address(stabilizer.contract_address, user3);
    stabilizer.unstake();
    stop_cheat_caller_address(stabilizer.contract_address);

    assert(stabilizer.get_token_id_for_user(user3).is_none(), 'Wrong token id after unstaking');

    let user3_position_id = *users_position_ids.at(2);
    assert_eq!(
        positions_nft.owner_of(user3_position_id.into()), user3, "Wrong owner after unstaking",
    );

    let user3_liquidity = *users_liquidity.at(2);
    expected_total_liquidity -= user3_liquidity;
    assert_eq!(
        stabilizer.get_total_liquidity(), expected_total_liquidity, "Wrong total liquidity #3",
    );

    let expected_user3_yin_yield = (1000 * WAD_ONE).into();
    let after_user3_yin_balance = yin.balance_of(user3);
    let user3_yin_yield = after_user3_yin_balance - before_user3_yin_balance;
    let error_margin = 10_256;
    assert_equalish(
        user3_yin_yield, expected_user3_yin_yield, error_margin, 'Wrong yield for user 3',
    );

    expected_yin_balance_snapshot += surplus.into();
    expected_yin_balance_snapshot -= user3_yin_yield;
    let yield_state = stabilizer.get_yield_state();
    assert_eq!(
        yield_state.yin_balance_snapshot,
        expected_yin_balance_snapshot,
        "Wrong yin balance snapshot #3",
    );

    // Step 7: Surplus is distributed
    let surplus: Wad = (300 * WAD_ONE).into();
    create_surplus(mainnet::SHRINE, surplus);

    // Step 8: First user claims
    let before_user1_yin_balance = yin.balance_of(user1);

    start_cheat_caller_address(stabilizer.contract_address, user1);
    stabilizer.claim();
    stop_cheat_caller_address(stabilizer.contract_address);

    let expected_user1_yin_yield = (600 * WAD_ONE.into());
    let after_user1_yin_balance = yin.balance_of(user1);
    let user1_yin_yield = after_user1_yin_balance - before_user1_yin_balance;
    let error_margin = 10_256;
    assert_equalish(
        user1_yin_yield, expected_user1_yin_yield, error_margin, 'Wrong yield for user 1 #2',
    );

    expected_yin_balance_snapshot += surplus.into();
    expected_yin_balance_snapshot -= user1_yin_yield;
    let yield_state = stabilizer.get_yield_state();
    assert_eq!(
        yield_state.yin_balance_snapshot,
        expected_yin_balance_snapshot,
        "Wrong yin balance snapshot #4",
    );

    let user1_stake = stabilizer.get_stake(user1);
    assert_eq!(
        user1_stake.yin_per_liquidity_snapshot,
        yield_state.yin_per_liquidity,
        "Wrong yin/liquidity for user 1 #2",
    );
}
