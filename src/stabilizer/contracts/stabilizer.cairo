#[starknet::contract]
pub mod stabilizer {
    use core::num::traits::Zero;
    use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use ekubo::interfaces::positions::{
        GetTokenInfoResult, IPositionsDispatcher, IPositionsDispatcherTrait,
    };
    use ekubo::types::bounds::Bounds;
    use ekubo::types::keys::PoolKey;
    use opus::interfaces::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::stabilizer::interfaces::stabilizer::IStabilizer;
    use opus_compose::stabilizer::math::{get_cumulative_delta, get_accumulated_yin};
    use opus_compose::stabilizer::types::{Stake, StorageBounds, StoragePoolKey, YieldState};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    //
    // Storage
    //

    #[storage]
    struct Storage {
        yin: IERC20Dispatcher,
        equalizer: IEqualizerDispatcher,
        ekubo_positions: IPositionsDispatcher,
        ekubo_positions_nft: IERC721Dispatcher,
        // Immutable parameters for the Ekubo position
        pool_key: StoragePoolKey,
        bounds: StorageBounds,
        // Total liquidity staked in this contract
        // Represented as a 128-bit value from Ekubo
        total_liquidity: u128,
        // Mapping of a user to his staked positions NFT ID.
        user_to_token_id: Map<ContractAddress, u64>,
        // Mapping of users to their staked positions
        stakes: Map<ContractAddress, Stake>,
        // YieldState struct tracking:
        // 1. snapshot of this contract's yin balance at the last call
        // 2. cumulative yin per liquidity
        yield_state: YieldState,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        Claimed: Claimed,
        Harvested: Harvested,
        YieldStateUpdated: YieldStateUpdated,
        Staked: Staked,
        Unstaked: Unstaked,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct Claimed {
        #[key]
        pub user: ContractAddress,
        pub amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct Harvested {
        pub total_liquidity: u128,
        pub amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct YieldStateUpdated {
        pub yield_state: YieldState,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct Staked {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token_id: u64,
        pub total_liquidity: u128,
        pub stake: Stake,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct Unstaked {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token_id: u64,
        pub total_liquidity: u128,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        yin: ContractAddress,
        equalizer: ContractAddress,
        ekubo_positions: ContractAddress,
        ekubo_positions_nft: ContractAddress,
        pool_key: PoolKey,
        bounds: Bounds,
    ) {
        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.equalizer.write(IEqualizerDispatcher { contract_address: equalizer });
        self.ekubo_positions.write(IPositionsDispatcher { contract_address: ekubo_positions });
        self.ekubo_positions_nft.write(IERC721Dispatcher { contract_address: ekubo_positions_nft });

        self.pool_key.write(pool_key.into());
        self.bounds.write(bounds.into());
    }

    #[abi(embed_v0)]
    impl IStabilizerImpl of IStabilizer<ContractState> {
        //
        // Getters
        //
        fn get_pool_key(self: @ContractState) -> PoolKey {
            self.pool_key.read().into()
        }

        fn get_bounds(self: @ContractState) -> Bounds {
            self.bounds.read().into()
        }

        fn get_total_liquidity(self: @ContractState) -> u128 {
            self.total_liquidity.read()
        }

        fn get_token_id_for_user(self: @ContractState, user: ContractAddress) -> Option<u64> {
            let token_id: u64 = self.user_to_token_id.read(user);
            if token_id.is_zero() {
                Option::None
            } else {
                Option::Some(token_id)
            }
        }

        // Note that this should not be used to check if a user has an active stake because
        // it is not updated when a user unstakes. Use `get_token_id_for_user` instead.
        fn get_stake(self: @ContractState, user: ContractAddress) -> Stake {
            self.stakes.read(user)
        }

        fn get_yield_state(self: @ContractState) -> YieldState {
            self.yield_state.read()
        }

        //
        // External functions
        //

        // Transfers a user's Ekubo position NFT to this contract, subject to the following:
        // 1. each address can only stake one position NFT at any one time;
        // 2. the parameters for the position NFT must correspond exactly to the parameters
        //    provided at deployment time.
        fn stake(ref self: ContractState, token_id: u64) {
            let user = get_caller_address();
            assert!(self.get_token_id_for_user(user).is_none(), "STB: Already staked");

            let ekubo_positions_nft = self.ekubo_positions_nft.read();
            assert!(ekubo_positions_nft.owner_of(token_id.into()) == user, "STB: Not owner");

            // Read position from Ekubo
            let position: GetTokenInfoResult = self
                .ekubo_positions
                .read()
                .get_token_info(
                    token_id.into(), self.pool_key.read().into(), self.bounds.read().into(),
                );
            assert!(position.liquidity.is_non_zero(), "STB: No liquidity found");

            // Get updated yield state based on total liquidity before adding this position's
            // liquidity to the total.
            let yield_state = self.harvest();

            self.yield_state.write(yield_state);
            self.user_to_token_id.write(user, token_id);

            let total_liquidity: u128 = self.total_liquidity.read() + position.liquidity;
            self.total_liquidity.write(total_liquidity);

            let stake = Stake {
                liquidity: position.liquidity,
                yin_per_liquidity_snapshot: yield_state.yin_per_liquidity,
            };
            self.stakes.write(user, stake);

            // Transfer NFT to this contract
            let stabilizer = get_contract_address();
            assert!(
                ekubo_positions_nft.get_approved(token_id.into()) == stabilizer,
                "STB: Token not approved",
            );
            ekubo_positions_nft.transfer_from(user, stabilizer, token_id.into());

            self.emit(Staked { user, token_id, stake, total_liquidity });
        }

        // Transfers an Ekubo position NFT from this contract to the user, provided the user
        // deposited the position NFT to this contract previously.
        // Any outstanding accrued yield is also transferred to the user.
        fn unstake(ref self: ContractState) {
            let user: ContractAddress = get_caller_address();
            let token_id = match self.get_token_id_for_user(user) {
                Option::Some(value) => value,
                Option::None => panic!("STB: No stake found"),
            };

            let yield_state = self.harvest();
            let (stake, yield) = self.compute_stake_and_yield(user, yield_state);

            // Perform storage updates
            // We can skip updating the user's Stake because it is constructed anew
            // if the user stakes again.
            self.user_to_token_id.write(user, Zero::zero());

            let total_liquidity: u128 = self.total_liquidity.read() - stake.liquidity;
            self.total_liquidity.write(total_liquidity);

            // Updated yield state is written to storage in `withdraw_yield`
            self.withdraw_yield(user, yield_state, yield);

            // Transfer NFT to user
            self
                .ekubo_positions_nft
                .read()
                .transfer_from(get_contract_address(), user, token_id.into());

            self.emit(Unstaked { user, token_id, total_liquidity });
        }

        // Transfer outstanding accrued yield to the user for an existing staked position.
        fn claim(ref self: ContractState) {
            let user: ContractAddress = get_caller_address();
            match self.get_token_id_for_user(user) {
                Option::Some(_) => {},
                Option::None => panic!("STB: No stake found"),
            };

            let yield_state = self.harvest();
            let (stake, yield) = self.compute_stake_and_yield(user, yield_state);

            self.stakes.write(user, stake);

            // Updated yield state is written to storage in `withdraw_yield`
            self.withdraw_yield(user, yield_state, yield);
        }
    }

    #[generate_trait]
    impl StabilizerHelpers of StabilizerHelpersTrait {
        // Account for any increase in this contract's yin balance, and distribute it to
        // existing staked liquidity by incrementing the accumulator value.
        // Note that this helper function returns the updated YieldState, and does not write it
        // to storage.
        fn harvest(ref self: ContractState) -> YieldState {
            let mut yield_state = self.yield_state.read();

            // Skip if total liquidity is zero. Otherwise, zero by division error.
            let total_liquidity = self.total_liquidity.read();
            if total_liquidity.is_zero() {
                return yield_state;
            }

            let equalizer = self.equalizer.read();
            let surplus = equalizer.equalize();
            if surplus.is_non_zero() {
                equalizer.allocate();
            }

            let yin_balance: u256 = self.yin.read().balance_of(get_contract_address());
            let accrued = yin_balance - yield_state.yin_balance_snapshot;
            if accrued.is_zero() {
                return yield_state;
            }

            let cumulative_delta: u256 = get_cumulative_delta(accrued, total_liquidity);

            yield_state.yin_balance_snapshot = yin_balance;
            yield_state.yin_per_liquidity += cumulative_delta;

            self.emit(Harvested { total_liquidity, amount: accrued });
            self.emit(YieldStateUpdated { yield_state });

            yield_state
        }

        // Compute the amount of accrued yield for a staker by multiplying the staker's
        // liquidity with the difference in the current accumulator value and the staker's
        // snapshot value.
        // Note that this function returns a tuple of the updated Stake for a user and the amount of
        // accrued yield in the form of yin.
        // Note that this helper function updates the Stake's accumulator value snapshot to the
        // latest, and does not write it to storage.
        fn compute_stake_and_yield(
            self: @ContractState, user: ContractAddress, yield_state: YieldState,
        ) -> (Stake, u256) {
            let mut stake = self.stakes.read(user);

            let cumulative_delta = yield_state.yin_per_liquidity - stake.yin_per_liquidity_snapshot;
            stake.yin_per_liquidity_snapshot = yield_state.yin_per_liquidity;

            let yield: u256 = get_accumulated_yin(stake.liquidity, cumulative_delta);

            (stake, yield)
        }

        // Helper function to withdraw accrued yield in the form of yin to a staker, and
        // update the yield state of the contract following the transfer of accrued yield from
        // this contract to a staker.
        fn withdraw_yield(
            ref self: ContractState,
            user: ContractAddress,
            mut yield_state: YieldState,
            amount: u256,
        ) {
            yield_state.yin_balance_snapshot -= amount;
            self.yield_state.write(yield_state);

            self.yin.read().transfer(user, amount);

            self.emit(YieldStateUpdated { yield_state });
            self.emit(Claimed { user, amount });
        }
    }
}
