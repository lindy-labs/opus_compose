#[starknet::contract]
pub mod archabbot {
    use core::cmp::min;
    use core::num::traits::{Bounded, Zero};
    use core::option::OptionTrait;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait};
    use opus::interfaces::abbot::IAbbot;
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, 
        IFlashBorrower, IFlashMintDispatcher, IFlashMintDispatcherTrait, ISentinelDispatcher,
        ISentinelDispatcherTrait, IShrineDispatcher, IShrineDispatcherTrait,
    };
    use opus::types::{AssetBalance, Health};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::shared::components::reentrancy_guard::reentrancy_guard_component;
    use opus_compose::shared::components::src5::{ISRC5Dispatcher, ISRC5DispatcherTrait};
    use opus_compose::chantry::interfaces::lever::ILever;
    use opus_compose::chantry::interfaces::archabbot::IArchabbot;
    use opus_compose::chantry::interfaces::rite::{
        IRITE_ID, IRiteDispatcher, IRiteDispatcherTrait,
    };
    use opus_compose::chantry::types::{
        Action, LeverDownParams, LeverUpParams, ModifyLeverAction, ModifyLeverParams,
        TroveConfig,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{RAY_ONE, Ray, WAD_ONE, Wad};

    //
    // Components
    //

    component!(path: reentrancy_guard_component, storage: reentrancy_guard, event: ReentrancyGuardEvent);

    impl ReentrancyGuardHelpers = reentrancy_guard_component::ReentrancyGuardHelpers<ContractState>;

    //
    // Constants
    //

    // The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
    // it is supposed to be returned from the onFlashLoan function by the receiver
    const ON_FLASH_MINT_SUCCESS: u256 =
        0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9_u256;

    pub const MAX_RELATIVE_THRESHOLD: u128 = RAY_ONE;
    pub const MAX_FORGE_FEE_PCT: u128 = 4 * WAD_ONE; // From Shrine
    pub const MAX_INCENTIVE: u128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFF;

    //
    // Storage
    //

    // Note that Archabbot does not keep track of troves created by Abbot previously in
    // its storage, except for `troves_count`.
    #[storage]
    struct Storage {
        #[substorage(v0)]
        reentrancy_guard: reentrancy_guard_component::Storage,
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        flash_mint: IFlashMintDispatcher,
        ekubo_router: IRouterDispatcher,
        // Total number of troves in a Shrine; monotonically increasing
        // also used to calculate the next ID (count+1) when opening a new trove
        // in essence, it serves as an index / primary key in a SQL table
        // This is initialized to the total number of troves created by Abbot previously.
        troves_count: u64,
        // the total number of troves of a particular address;
        // used to build the tuple key of `user_troves` variable
        // (user) -> (number of troves opened)
        user_troves_count: Map<ContractAddress, u64>,
        user_troves: Map<(ContractAddress, u64), u64>,
        // Smart trove ID -> owner
        trove_owner: Map<u64, ContractAddress>,
        //
        // Rite storage
        //
        trove_configs: Map<u64, TroveConfig>,
        rites: Map<u64, IRiteDispatcher>,
        // Transient variable used to lock the trove ID before a callback to
        // prevent illegal actions across trove IDs with the same rite
        // Cleared after the rite execution completes (perform/end).
        transient_trove_id: u64,
        // Counter incremented on each callback from a rite, used to verify
        // that at least one callback was made during execution.
        // Cleared together with `transient_trove_id` after execution completes.
        transient_callback_nonce: usize,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        // Component events
        ReentrancyGuardEvent: reentrancy_guard_component::Event,
        // Original Abbot events
        Deposit: Deposit,
        Withdraw: Withdraw,
        TroveOpened: TroveOpened,
        TroveClosed: TroveClosed,
        // Rite events
        ConfigUpdated: ConfigUpdated,
        RiteSet: RiteSet,
        RiteExecuted: RiteExecuted,
        RiteEnded: RiteEnded,
        // Lever events
        LeverUp: LeverUp,
        LeverDown: LeverDown,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Deposit {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub yang_amt: Wad,
        pub asset_amt: u128,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Withdraw {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub yang_amt: Wad,
        pub asset_amt: u128,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TroveOpened {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TroveClosed {
        #[key]
        pub trove_id: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct ConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: TroveConfig,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct RiteSet {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub rite: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct RiteExecuted {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub rite: ContractAddress,
        pub incentive: Wad,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct RiteEnded {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub rite: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct LeverUp {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub amount: Wad,
        pub min_asset_amount: u128,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct LeverDown {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub amount: Wad,
        pub yang_asset_amount_withdrawn: u128,
        pub yang_asset_amount_redeposited: u128,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        abbot: ContractAddress,
        flash_mint: ContractAddress,
        ekubo_router: ContractAddress,
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        let abbot = IAbbotDispatcher { contract_address: abbot };
        self.abbot.write(abbot);
        self.flash_mint.write(IFlashMintDispatcher { contract_address: flash_mint });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });

        self.troves_count.write(abbot.get_troves_count());
    }

    // Replicates existing Abbot's implementation
    #[abi(embed_v0)]
    impl IAbbotImpl of IAbbot<ContractState> {
        fn get_trove_owner(self: @ContractState, trove_id: u64) -> Option<ContractAddress> {
            let owner = self.trove_owner.read(trove_id);
            if owner.is_non_zero() {
                return Option::Some(owner);
            }
            // Delegate to legacy Abbot
            self.abbot.read().get_trove_owner(trove_id)
        }

        fn get_user_trove_ids(self: @ContractState, user: ContractAddress) -> Span<u64> {
            let mut trove_ids: Array<u64> = ArrayTrait::new();
            let legacy_trove_ids = self.abbot.read().get_user_trove_ids(user);
            for legacy_trove_id in legacy_trove_ids {
                trove_ids.append(*legacy_trove_id);
            }

            let user_troves_count: u64 = self.user_troves_count.read(user);
            for i in 0..user_troves_count {
                trove_ids.append(self.user_troves.read((user, i)));
            }
            trove_ids.span()
        }

        fn get_troves_count(self: @ContractState) -> u64 {
            self.troves_count.read()
        }

        fn get_trove_asset_balance(
            self: @ContractState, trove_id: u64, yang: ContractAddress,
        ) -> u128 {
            self.sentinel.read().convert_to_assets(yang, self.shrine.read().get_deposit(yang, trove_id))
        }

        // Create a new trove in the system with Yang deposits
        // Note that since the forge amount must be greater than zero, the Shrine would also enforce
        // that the minimum trove value has been deposited.
        fn open_trove(
            ref self: ContractState, yang_assets: Span<AssetBalance>, forge_amount: Wad, max_forge_fee_pct: Wad,
        ) -> u64 {
            assert!(yang_assets.len().is_non_zero(), "ARC: No yangs");
            assert!(forge_amount.is_non_zero(), "ARC: No debt forged");

            let new_troves_count: u64 = self.troves_count.read() + 1;
            self.troves_count.write(new_troves_count);

            let user = get_caller_address();
            let user_troves_count: u64 = self.user_troves_count.read(user);
            self.user_troves_count.write(user, user_troves_count + 1);

            let new_trove_id: u64 = new_troves_count;
            self.user_troves.write((user, user_troves_count), new_trove_id);
            self.trove_owner.write(new_trove_id, user);

            // deposit all requested Yangs into the system
            let shrine = self.shrine.read();
            let sentinel = self.sentinel.read();
            for yang_asset in yang_assets {
                self.deposit_helper(shrine, sentinel, new_trove_id, user, user, *yang_asset);
            }

            // forge Yin
            shrine.forge(user, new_trove_id, forge_amount, max_forge_fee_pct);

            self.emit(TroveOpened { user, trove_id: new_trove_id });

            new_trove_id
        }

        // close a trove, repaying its debt in full and withdrawing all the Yangs
        fn close_trove(ref self: ContractState, trove_id: u64) {
            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            let shrine = self.shrine.read();
            // melting "max Wad" to instruct Shrine to melt *all* of trove's debt
            shrine.melt(user, trove_id, Bounded::MAX);

            // withdraw each and every Yang belonging to the trove from the system
            let sentinel = self.sentinel.read();
            let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
            for yang in yangs {
                let yang_amount: Wad = shrine.get_deposit(*yang, trove_id);
                if yang_amount.is_zero() {
                    continue;
                }
                self.withdraw_helper(shrine, sentinel, trove_id, user, user, *yang, yang_amount);
            }

            self.emit(TroveClosed { trove_id });
        }

        // add Yang (an asset) to a trove
        fn deposit(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            // There is no need to check the yang address is non-zero because the
            // Sentinel does not allow a zero address yang to be added.

            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            self.deposit_helper(self.shrine.read(), self.sentinel.read(), trove_id, user, user, yang_asset);
        }

        // remove Yang (an asset) from a trove
        fn withdraw(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            // There is no need to check the yang address is non-zero because the
            // Sentinel does not allow a zero address yang to be added.

            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            let sentinel = self.sentinel.read();
            let yang_amt: Wad = sentinel.convert_to_yang(yang_asset.address, yang_asset.amount);
            self.withdraw_helper(self.shrine.read(), sentinel, trove_id, user, user, yang_asset.address, yang_amt);
        }

        // create Yin in a trove
        fn forge(ref self: ContractState, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad) {
            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);
            self.shrine.read().forge(user, trove_id, amount, max_forge_fee_pct);
        }

        // destroy Yin from a trove
        fn melt(ref self: ContractState, trove_id: u64, amount: Wad) {
            // note that caller does not need to be the trove's owner to melt
            self.shrine.read().melt(get_caller_address(), trove_id, amount);
        }
    }

    #[abi(embed_v0)]
    impl IArchabbotImpl of IArchabbot<ContractState> {
        //
        // Config
        //

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: TroveConfig) {
            let user: ContractAddress = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            let mut config = config;
            config
                .relative_threshold = min(config.relative_threshold, MAX_RELATIVE_THRESHOLD.into());
            config.max_forge_fee_pct = min(config.max_forge_fee_pct, MAX_FORGE_FEE_PCT.into());
            config.incentive = min(config.incentive, MAX_INCENTIVE.into());

            self.trove_configs.write(trove_id, config);

            self.emit(ConfigUpdated { user, trove_id, config });
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> TroveConfig {
            self.trove_configs.read(trove_id)
        }

        //
        // Rites
        //

        fn get_rite(self: @ContractState, trove_id: u64) -> ContractAddress {
            self.rites.read(trove_id).contract_address
        }

        // This function explicitly allows a user to change rites even if there is an ongoing rite
        // that has not ended so as to prevent a rite from bricking a trove for whatever reason.
        fn set_rite(ref self: ContractState, trove_id: u64, rite: ContractAddress) {
            let caller: ContractAddress = get_caller_address();
            // This also checks that the trove is a smart trove.
            // Otherwise, the owner would be zero address.
            self.assert_trove_owner(caller, trove_id);

            let rite_src5 = ISRC5Dispatcher { contract_address: rite };
            assert!(rite_src5.supports_interface(IRITE_ID), "ARC: Rite interface not supported");

            self.rites.write(trove_id, IRiteDispatcher { contract_address: rite });

            self.emit(RiteSet { user: caller, trove_id, rite });
        }

        // Note that this does not check:
        // 1. the configured max forge fee % is less than the current value;
        // 2. the LTV does not exceed the relative threhsold at the end of the rite;
        fn can_execute_rite(self: @ContractState, trove_id: u64) -> bool {
            let rite = self.rites.read(trove_id);
            self.can_execute_rite_helper(rite, trove_id)
        }

        // Can be called by anyone
        fn execute_rite(ref self: ContractState, trove_id: u64) {
            let rite = self.rites.read(trove_id);
            assert!(self.can_execute_rite_helper(rite, trove_id), "ARC: Cannot execute rite");

            assert!(self.transient_trove_id.read().is_zero(), "ARC: Another trove in execution");
            self.transient_trove_id.write(trove_id);

            rite.perform(trove_id);

            // Settle incentive
            let config: TroveConfig = self.trove_configs.read(trove_id);
            let shrine = self.shrine.read();
            let caller: ContractAddress = get_caller_address();
            if config.incentive.is_non_zero() {
                shrine.forge(caller, trove_id, config.incentive, config.max_forge_fee_pct);
            }

            // Check LTV condition if relative threshold is set
            if config.relative_threshold != RAY_ONE.into() {
                let trove_health: Health = shrine.get_trove_health(trove_id);
                let stop_ltv: Ray = trove_health.threshold * config.relative_threshold;
                assert!(trove_health.ltv <= stop_ltv, "ARC: LTV exceeds relative threshold");
            }

            self.assert_callback();
            self.clear_locks();

            self
                .emit(
                    RiteExecuted {
                        caller,
                        trove_id,
                        rite: rite.contract_address,
                        incentive: config.incentive,
                    },
                );
        }

        // Only owner can end rite
        // Note that the relative threshold is not enforced after ending a rite because
        // it may otherwise brick the ongoing rite.
        fn end_rite(ref self: ContractState, trove_id: u64) {
            let caller = get_caller_address();
            self.assert_trove_owner(caller, trove_id);

            assert!(self.transient_trove_id.read().is_zero(), "ARC: Another trove in execution");
            self.transient_trove_id.write(trove_id);

            let rite = self.rites.read(trove_id);
            rite.end(trove_id);

            self.assert_callback();
            self.clear_locks();

            self
                .emit(
                    RiteEnded {
                        caller: get_caller_address(), trove_id, rite: rite.contract_address,
                    },
                );
        }

        // Batch callback function to be called by `rite.perform(...)` and `rite.end(...)`
        // Checks the caller is the rite specified for the smart trove.
        // Checks the trove ID locked in the initial rite call.
        fn on_rite_actions(ref self: ContractState, trove_id: u64, actions: Span<Action>) {
            let caller: ContractAddress = get_caller_address();
            let rite = self.rites.read(trove_id);
            assert!(caller == rite.contract_address, "ARC: Caller not rite");
            assert!(self.transient_trove_id.read() == trove_id, "ARC: Execution not started");

            let shrine = self.shrine.read();
            let sentinel = self.sentinel.read();
            let trove_owner: ContractAddress = self.get_trove_owner(trove_id).expect('ARC: No trove owner');
            let archabbot: ContractAddress = get_contract_address();
            for action in actions {
                self.execute_action(shrine, sentinel, trove_id, trove_owner, archabbot, rite.contract_address, *action);
            }

            let current_nonce = self.transient_callback_nonce.read();
            self.transient_callback_nonce.write(current_nonce + 1);
        }
    }

    #[abi(embed_v0)]
    impl ILeverImpl of ILever<ContractState> {
        // Take on leverage to acquire a specific collateral for a Trove
        // 1. Flash mint yin to this contract
        // 2. Purchase collateral asset with flash-minted yin via Ekubo
        // 3. Deposit purchased collateral asset to caller's trove
        // 4. Borrow yin from caller's trove and mint to this contract
        fn up(ref self: ContractState, amount: Wad, lever_up_params: LeverUpParams) {
            let user: ContractAddress = get_caller_address();
            let trove_id: u64 = lever_up_params.trove_id;
            self.assert_trove_owner(user, trove_id);

            let mut call_data: Array<felt252> = array![];
            let modify_lever_params = ModifyLeverParams {
                user, action: ModifyLeverAction::LeverUp(lever_up_params),
            };
            modify_lever_params.serialize(ref call_data);

            self
                .flash_mint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    amount.into(),
                    call_data.span(),
                );
        }

        // Unwind a position for a specific collateral for a Trove
        // 1. Flash mint yin to this contract
        // 2. Repay yin for trove
        // 3. Withdraw collateral asset from trove
        // 4. Purchase yin with withdrawn collateral asset via Ekubo
        // 5. Transfer remainder collateral asset to user
        fn down(ref self: ContractState, amount: Wad, lever_down_params: LeverDownParams) {
            let user: ContractAddress = get_caller_address();
            let trove_id: u64 = lever_down_params.trove_id;
            self.assert_trove_owner(user, trove_id);

            let modify_lever_params = ModifyLeverParams {
                user, action: ModifyLeverAction::LeverDown(lever_down_params),
            };
            let mut call_data: Array<felt252> = array![];
            modify_lever_params.serialize(ref call_data);

            self
                .flash_mint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    amount.into(),
                    call_data.span(),
                );
        }
    }

    // Lever actions are not subject to the relative threshold since they are
    // manually initiated by the user.
    #[abi(embed_v0)]
    impl IFlashBorrowerImpl of IFlashBorrower<ContractState> {
        // The flash mint contract that is used should not charge any fee.
        fn on_flash_loan(
            ref self: ContractState,
            initiator: ContractAddress, // this contract
            token: ContractAddress, // yin
            amount: u256,
            fee: u256,
            mut call_data: Span<felt252>,
        ) -> u256 {
            assert!(
                get_caller_address() == self.flash_mint.read().contract_address,
                "ARC: Illegal callback",
            );
            let archabbot: ContractAddress = get_contract_address();
            assert!(initiator == archabbot, "ARC: Initiator must be Archabbot");

            let ModifyLeverParams {
                user, action,
            } = Serde::<ModifyLeverParams>::deserialize(ref call_data).unwrap();

            let shrine = self.shrine.read();
            let yin = IERC20Dispatcher { contract_address: token };
            let sentinel = self.sentinel.read();
            let router = self.ekubo_router.read();
            let router_clear = IClearDispatcher { contract_address: router.contract_address };

            match action {
                ModifyLeverAction::LeverUp(params) => {
                    let LeverUpParams { trove_id, max_ltv, yang, max_forge_fee_pct, min_asset_amount, swaps } = params;

                    // Transfer yin to Ekubo's router and swap for collateral
                    yin.transfer(router.contract_address, amount);
                    router.multi_multihop_swap(swaps);

                    // Withdraw the collateral asset from Ekubo's router to this contract.
                    let asset_amt: u256 = router_clear
                        .clear_minimum(
                            EkuboERC20Dispatcher { contract_address: yang },
                            min_asset_amount.into(),
                        );

                    // Deposit purchased collateral to trove
                    self.approve_token_for_gate(sentinel, yang, asset_amt);
                    let asset_amt_128: u128 = asset_amt.try_into().unwrap();
                    self.deposit_helper(shrine, sentinel, trove_id, user, initiator, AssetBalance { address: yang, amount: asset_amt_128 });

                    // Borrow yin from trove and send to this contract to repay the flash mint
                    shrine
                        .forge(initiator, trove_id, amount.try_into().unwrap(), max_forge_fee_pct);

                    let trove_health: Health = shrine.get_trove_health(trove_id);
                    assert!(trove_health.ltv <= max_ltv, "ARC: Exceeds max LTV");

                    self
                        .emit(
                            LeverUp {
                                user,
                                trove_id,
                                amount: amount.try_into().unwrap(),
                                yang,
                                min_asset_amount,
                            },
                        );
                },
                ModifyLeverAction::LeverDown(params) => {
                    let LeverDownParams { trove_id, max_ltv, yang, yang_amt, swaps } = params;
                    let yang_erc20 = IERC20Dispatcher { contract_address: yang };

                    // Use the flash minted yin to repay the trove's debt
                    shrine.melt(archabbot, trove_id, amount.try_into().unwrap());

                    // Withdraw collateral to this contract
                    let asset_amt: u128 = self.withdraw_helper(shrine, sentinel, trove_id, user, initiator, yang, yang_amt);

                    // Transfer collateral to Ekubo's router and swap for yin
                    yang_erc20.transfer(router.contract_address, asset_amt.into());
                    router.multi_multihop_swap(swaps);

                    // Sanity check to ensure the amount of yin flash minted has been purchased
                    // and can be withdrawn
                    let cleared_amount = router_clear
                        .clear_minimum(EkuboERC20Dispatcher { contract_address: token }, amount);
                    // Transfer any excess to user
                    if cleared_amount > amount {
                        yin.transfer(user, cleared_amount - amount);
                    }

                    // Re-deposit any remainder collateral
                    let remainder_asset: u128 = router_clear
                        .clear_minimum_to_recipient(
                            EkuboERC20Dispatcher { contract_address: yang }, 0, archabbot,
                        )
                        .try_into()
                        .unwrap();
                    if remainder_asset.is_non_zero() {
                        self.approve_token_for_gate(sentinel, yang, remainder_asset.into());
                        self.deposit_helper(shrine, sentinel, trove_id, user, archabbot, AssetBalance {
                            address: yang, amount: remainder_asset,
                        });
                    }

                    let trove_health: Health = shrine.get_trove_health(trove_id);
                    assert!(trove_health.ltv <= max_ltv, "ARC: Exceeds max LTV");

                    self
                        .emit(
                            LeverDown {
                                user,
                                trove_id,
                                amount: amount.try_into().unwrap(),
                                yang,
                                yang_asset_amount_withdrawn: asset_amt,
                                yang_asset_amount_redeposited: remainder_asset,
                            },
                        );
                },
            }

            ON_FLASH_MINT_SUCCESS
        }
    }

    #[generate_trait]
    impl ArchabbotHelpers of ArchabbotHelpersTrait {
        //
        // Abbot helpers
        //
        
        fn assert_trove_owner(self: @ContractState, user: ContractAddress, trove_id: u64) {
            assert!(self.get_trove_owner(trove_id) == Option::Some(user), "ARC: Not trove owner")
        }

        // Modifications from Abbot:
        // - `depositor` has been added as a call arg to distinguish from the trove owner 
        //   for lever and rite actions
        // - Sentinel and Shrine dispatchers are passed as calldata to save gas when called
        //   multiple times in the same transaction
        fn deposit_helper(
            ref self: ContractState, 
            shrine: IShrineDispatcher,
            sentinel: ISentinelDispatcher,
            trove_id: u64, 
            user: ContractAddress, 
            depositor: ContractAddress, 
            yang_asset: AssetBalance
        ) {
            // reentrancy guard is used as a precaution
            self.reentrancy_guard.start();

            let yang_amt: Wad = sentinel.enter(yang_asset.address, depositor, yang_asset.amount);
            shrine.deposit(yang_asset.address, trove_id, yang_amt);

            self.emit(Deposit { user, trove_id, yang: yang_asset.address, yang_amt, asset_amt: yang_asset.amount });

            self.reentrancy_guard.end();
        }

        // Modifications from Abbot:
        // - `recipient` has been added as a call arg to distinguish from the trove owner 
        //   for lever and rite actions
        // - Sentinel and Shrine dispatchers are passed as calldata to save gas when called
        //   multiple times in the same transaction
        fn withdraw_helper(
            ref self: ContractState, 
            shrine: IShrineDispatcher,
            sentinel: ISentinelDispatcher,
            trove_id: u64, 
            user: ContractAddress, 
            recipient: ContractAddress, 
            yang: ContractAddress, 
            yang_amt: Wad,
        ) -> u128 {
            // reentrancy guard is used as a precaution
            self.reentrancy_guard.start();

            let asset_amt: u128 = sentinel.exit(yang, recipient, yang_amt);
            shrine.withdraw(yang, trove_id, yang_amt);

            self.emit(Withdraw { user, trove_id, yang, yang_amt, asset_amt });

            self.reentrancy_guard.end();
            asset_amt
        }

        //
        // Rite helpers
        //

        fn assert_callback(self: @ContractState) {
            // Guarantee that at least one callback was executed
            assert!(!self.transient_callback_nonce.read().is_zero(), "ARC: Callback not executed");
        }

        fn can_execute_rite_helper(
            self: @ContractState, rite: IRiteDispatcher, trove_id: u64,
        ) -> bool {
            if rite.contract_address.is_zero() {
                false
            } else {
                rite.is_ready(trove_id)
            }
        }

        fn clear_locks(ref self: ContractState) {
            self.transient_trove_id.write(Zero::zero());
            self.transient_callback_nonce.write(Zero::zero());
        }

        fn execute_action(
            ref self: ContractState,
            shrine: IShrineDispatcher,
            sentinel: ISentinelDispatcher,
            trove_id: u64,
            trove_owner: ContractAddress,
            archabbot: ContractAddress,
            rite_address: ContractAddress,
            action: Action,
        ) {
            match action {
                Action::Forge(amount) => {
                    // Forge to Rite directly
                    let config: TroveConfig = self.trove_configs.read(trove_id);
                    shrine.forge(rite_address, trove_id, amount, config.max_forge_fee_pct);
                },
                Action::Melt(amount) => { 
                    // Melt from Archabbot
                    shrine.melt(archabbot, trove_id, amount);
                },
                Action::Deposit(asset_balance) => {
                    // Deposit collateral already sent by Rite to Archabbot
                    self
                        .approve_token_for_gate(
                            sentinel,
                            asset_balance.address,
                            asset_balance.amount.into(),
                        );
                    self.deposit_helper(shrine, sentinel, trove_id, trove_owner, archabbot, asset_balance);
                },
                Action::Withdraw(asset_balance) => {
                    // Withdraw collateral to Rite directly
                    let yang_amt: Wad = sentinel.convert_to_yang(asset_balance.address, asset_balance.amount);
                    self.withdraw_helper(shrine, sentinel, trove_id, trove_owner, rite_address, asset_balance.address, yang_amt);
                },
                Action::None => (),
            };
        }

        fn approve_token_for_gate(
            ref self: ContractState,
            sentinel: ISentinelDispatcher,
            token: ContractAddress,
            amount: u256,
        ) {
            // Invalid yangs will be caught in `sentinel.enter(...)`
            let gate = sentinel.get_gate_address(token);
            IERC20Dispatcher { contract_address: token }.approve(gate, amount);
        }
    }
}
