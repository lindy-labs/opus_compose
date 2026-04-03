#[starknet::contract]
pub mod prior {
    use core::cmp::min;
    use core::num::traits::Zero;
    use core::option::OptionTrait;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait};
    use opus::interfaces::abbot::IAbbot;
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, ICaretakerDispatcher, ICaretakerDispatcherTrait,
        IFlashBorrower, IFlashMintDispatcher, IFlashMintDispatcherTrait, ISentinelDispatcher,
        ISentinelDispatcherTrait, IShrineDispatcher, IShrineDispatcherTrait,
    };
    use opus::types::{AssetBalance, Health};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::vicariate::interfaces::lever::ILever;
    use opus_compose::vicariate::interfaces::prior::IPrior;
    use opus_compose::vicariate::interfaces::rite::{IRiteDispatcher, IRiteDispatcherTrait};
    use opus_compose::vicariate::types::{
        Action, LeverDownParams, LeverUpParams, ModifyLeverAction, ModifyLeverParams,
        SmartTroveConfig,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{RAY_ONE, Ray, WAD_ONE, Wad};

    //
    // Constants
    //

    // The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
    // it is supposed to be returned from the onFlashLoan function by the receiver
    const ON_FLASH_MINT_SUCCESS: u256 =
        0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9_u256;

    // Extracted from Shrine
    pub const MAX_RELATIVE_THRESHOLD: u128 = RAY_ONE;
    pub const MAX_FORGE_FEE_PCT: u128 = 4 * WAD_ONE;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        caretaker: ICaretakerDispatcher,
        flash_mint: IFlashMintDispatcher,
        ekubo_router: IRouterDispatcher,
        // Total smart troves count (monotonically increasing)
        smart_troves_count: u64,
        smart_trove_ids: Map<u64, u64>,
        // Number of smart troves per user
        // Starts from index 1
        user_smart_troves_count: Map<ContractAddress, u64>,
        user_smart_troves: Map<(ContractAddress, u64), u64>, // (user, index) -> PRI trove ID
        // Smart trove ID -> owner
        smart_trove_owners: Map<u64, ContractAddress>,
        smart_trove_configs: Map<u64, SmartTroveConfig>,
        rites: Map<u64, IRiteDispatcher>,
        // Transient variable used to lock the trove ID before a callback to
        // prevent illegal actions across trove IDs with the same rite
        // Cleared after the rite execution completes (perform/end).
        transient_trove_id: u64,
        // Counter incremented on each callback from a rite, used to verify
        // that at least one callback was made during execution.
        // Cleared together with transient_trove_id after execution completes.
        transient_action_nonce: u64,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        SmartTroveCreated: SmartTroveCreated,
        ConfigUpdated: ConfigUpdated,
        RiteSet: RiteSet,
        // Lever events
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct SmartTroveCreated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct ConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub relative_threshold: Ray,
        pub max_forge_fee_pct: Wad,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct RiteSet {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub rite: ContractAddress,
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
        caretaker: ContractAddress,
        flash_mint: ContractAddress,
        ekubo_router: ContractAddress,
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.caretaker.write(ICaretakerDispatcher { contract_address: caretaker });
        self.flash_mint.write(IFlashMintDispatcher { contract_address: flash_mint });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });
    }

    #[abi(embed_v0)]
    impl IAbbotImpl of IAbbot<ContractState> {
        fn get_trove_owner(self: @ContractState, trove_id: u64) -> Option<ContractAddress> {
            let owner = self.smart_trove_owners.read(trove_id);
            if owner.is_zero() {
                Option::None
            } else {
                Option::Some(owner)
            }
        }

        fn get_user_trove_ids(self: @ContractState, user: ContractAddress) -> Span<u64> {
            let mut trove_ids: Array<u64> = ArrayTrait::new();
            let user_troves_count: u64 = self.user_smart_troves_count.read(user);
            for i in 0..user_troves_count {
                trove_ids.append(self.user_smart_troves.read((user, i + 1)));
            }
            trove_ids.span()
        }

        fn get_troves_count(self: @ContractState) -> u64 {
            self.smart_troves_count.read()
        }

        fn get_trove_asset_balance(
            self: @ContractState, trove_id: u64, yang: ContractAddress,
        ) -> u128 {
            assert!(self.smart_trove_owners.read(trove_id).is_non_zero(), "PRI: Not PRI trove");
            self.abbot.read().get_trove_asset_balance(trove_id, yang)
        }

        fn open_trove(
            ref self: ContractState,
            yang_assets: Span<AssetBalance>,
            forge_amount: Wad,
            max_forge_fee_pct: Wad,
        ) -> u64 {
            let user = get_caller_address();

            let sentinel = self.sentinel.read();
            let prior: ContractAddress = get_contract_address();
            for yang_asset in yang_assets {
                self.deposit_setup(sentinel, prior, user, *yang_asset);
            }

            let trove_id: u64 = self
                .abbot
                .read()
                .open_trove(yang_assets, forge_amount, max_forge_fee_pct);

            let new_smart_troves_count: u64 = self.smart_troves_count.read() + 1;
            self.smart_troves_count.write(new_smart_troves_count);
            self.smart_trove_ids.write(new_smart_troves_count, trove_id);

            let new_user_smart_troves_count: u64 = self.user_smart_troves_count.read(user) + 1;
            self.user_smart_troves_count.write(user, new_user_smart_troves_count);
            self.user_smart_troves.write((user, new_user_smart_troves_count), trove_id);
            self.smart_trove_owners.write(trove_id, user);

            IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
                .transfer(user, forge_amount.into());

            self.emit(SmartTroveCreated { user, trove_id });
            trove_id
        }

        fn close_trove(ref self: ContractState, trove_id: u64) {
            let caller = get_caller_address();
            self.assert_smart_trove_owner(caller, trove_id);

            // Close trove in Abbot
            self.abbot.read().close_trove(trove_id);
        }

        fn deposit(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            let caller: ContractAddress = get_caller_address();
            self.assert_smart_trove_owner(caller, trove_id);

            self.deposit_setup(self.sentinel.read(), get_contract_address(), caller, yang_asset);

            self.abbot.read().deposit(trove_id, yang_asset);
        }

        fn withdraw(ref self: ContractState, trove_id: u64, yang_asset: AssetBalance) {
            let caller: ContractAddress = get_caller_address();
            self.assert_smart_trove_owner(caller, trove_id);

            self.abbot.read().withdraw(trove_id, yang_asset);

            IERC20Dispatcher { contract_address: yang_asset.address }
                .transfer(caller, yang_asset.amount.into());
        }

        fn forge(ref self: ContractState, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad) {
            let caller = get_caller_address();
            self.assert_smart_trove_owner(caller, trove_id);
            self.abbot.read().forge(trove_id, amount, max_forge_fee_pct);

            IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
                .transfer(caller, amount.into());
        }

        // User needs to approve this Abbot for transfer
        fn melt(ref self: ContractState, trove_id: u64, amount: Wad) {
            let caller = get_caller_address();
            IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
                .transfer_from(caller, get_contract_address(), amount.into());
            self.abbot.read().melt(trove_id, amount);
        }
    }

    #[abi(embed_v0)]
    impl IPriorImpl of IPrior<ContractState> {
        //
        // Config
        //

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: SmartTroveConfig) {
            let user: ContractAddress = get_caller_address();
            self.assert_smart_trove_owner(user, trove_id);

            let mut config = config;
            config
                .relative_threshold = min(config.relative_threshold, MAX_RELATIVE_THRESHOLD.into());
            config.max_forge_fee_pct = min(config.max_forge_fee_pct, MAX_FORGE_FEE_PCT.into());

            self.smart_trove_configs.write(trove_id, config)
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> SmartTroveConfig {
            self.smart_trove_configs.read(trove_id)
        }

        fn get_trove_id_by_index(self: @ContractState, index: u64) -> u64 {
            self.smart_trove_ids.read(index)
        }

        //
        // Rites
        //

        fn get_rite(self: @ContractState, trove_id: u64) -> ContractAddress {
            self.rites.read(trove_id).contract_address
        }

        fn set_rite(ref self: ContractState, trove_id: u64, rite: ContractAddress) {
            let caller: ContractAddress = get_caller_address();
            // This also checks that the trove is a smart trove.
            // Otherwise, the owner would be zero address.
            self.assert_smart_trove_owner(caller, trove_id);

            // Assert that is no ongoing rite
            let previous_rite: IRiteDispatcher = self.rites.read(trove_id);
            if previous_rite.contract_address.is_non_zero() {
                assert!(previous_rite.has_ended(trove_id), "PRI: Rite ongoing");
            }

            let rite = IRiteDispatcher { contract_address: rite };
            self.can_execute_rite_helper(rite, trove_id);

            self.rites.write(trove_id, rite);

            self.emit(RiteSet { user: caller, trove_id, rite: rite.contract_address });
        }

        // Note that this does not check that the LTV does not exceed the relative threhsold
        // at the end of the rite.
        fn can_execute_rite(self: @ContractState, trove_id: u64) -> bool {
            let rite = self.rites.read(trove_id);
            self.can_execute_rite_helper(rite, trove_id)
        }

        // Can be called by anyone
        fn execute_rite(ref self: ContractState, trove_id: u64) {
            let rite = self.rites.read(trove_id);
            assert!(self.can_execute_rite_helper(rite, trove_id), "PRI: Cannot execute rite");

            assert!(self.transient_trove_id.read().is_zero(), "PRI: Another trove in execution");
            self.transient_trove_id.write(trove_id);

            rite.perform(trove_id);

            // Check LTV condition if relative_threshold is set
            let config: SmartTroveConfig = self.smart_trove_configs.read(trove_id);
            let trove_health: Health = self.shrine.read().get_trove_health(trove_id);
            let stop_ltv: Ray = trove_health.threshold * config.relative_threshold;
            assert!(trove_health.ltv <= stop_ltv, "PRI: LTV exceeds relative threshold");

            self.assert_callback();
            self.clear_locks();
        }

        // Only owner can end rite
        // Note that the relative threshold is not enforced after ending a rite because
        // it may otherwise brick the ongoing rite.
        fn end_rite(ref self: ContractState, trove_id: u64) {
            let caller = get_caller_address();
            self.assert_smart_trove_owner(caller, trove_id);

            assert!(self.transient_trove_id.read().is_zero(), "PRI: Another trove in execution");
            self.transient_trove_id.write(trove_id);

            let rite = self.rites.read(trove_id);
            rite.end(trove_id);

            self.assert_callback();
            self.clear_locks();
        }

        // Batch callback function to be called by `rite.perform(...)` and `rite.end(...)`
        // Checks the caller is the rite specified for the smart trove.
        // Checks the trove ID locked in the initial rite call.
        fn on_rite_actions(ref self: ContractState, trove_id: u64, actions: Span<Action>) {
            let caller: ContractAddress = get_caller_address();
            let rite = self.rites.read(trove_id);
            assert!(caller == rite.contract_address, "PRI: Caller not rite");
            assert!(self.transient_trove_id.read() == trove_id, "PRI: Execution not started");

            for action in actions {
                self.execute_action(trove_id, rite.contract_address, self.abbot.read(), *action);
            }

            let current_nonce = self.transient_action_nonce.read();
            self.transient_action_nonce.write(current_nonce + 1);
        }

        //
        // Backwards compatibility with Abbot and Caretaker
        //

        // Mirror Caretaker's release function due to ownership check on primary Abbot
        fn release(ref self: ContractState, trove_id: u64) -> Span<AssetBalance> {
            let caller: ContractAddress = get_caller_address();
            self.assert_smart_trove_owner(caller, trove_id);

            let released_assets: Span<AssetBalance> = self.caretaker.read().release(trove_id);
            for asset in released_assets {
                IERC20Dispatcher { contract_address: *asset.address }
                    .transfer(caller, (*asset.amount).into());
            }

            released_assets
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
            self.assert_smart_trove_owner(user, lever_up_params.trove_id);

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
            self.assert_smart_trove_owner(user, lever_down_params.trove_id);

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
                "PRI: Illegal callback",
            );
            assert!(initiator == get_contract_address(), "PRI: Initiator must be lever");

            let ModifyLeverParams {
                user, action,
            } = Serde::<ModifyLeverParams>::deserialize(ref call_data).unwrap();

            let yin = IERC20Dispatcher { contract_address: token };
            let abbot = self.abbot.read();
            let sentinel = self.sentinel.read();
            let router = self.ekubo_router.read();
            let router_clear = IClearDispatcher { contract_address: router.contract_address };

            match action {
                ModifyLeverAction::LeverUp(params) => {
                    let LeverUpParams { trove_id, yang, swaps } = params;
                    let config = self.smart_trove_configs.read(trove_id);

                    // Transfer yin to Ekubo's router and swap for collateral
                    yin.transfer(router.contract_address, amount);
                    router.multi_multihop_swap(swaps);

                    // Withdraw the collateral asset from Ekubo's router to this contract.
                    let asset_amt: u256 = router_clear
                        .clear_minimum(EkuboERC20Dispatcher { contract_address: yang }, 1);

                    // Deposit purchased collateral to trove
                    self.approve_token_for_gate(sentinel, yang, asset_amt);
                    abbot
                        .deposit(
                            trove_id,
                            AssetBalance { address: yang, amount: asset_amt.try_into().unwrap() },
                        );

                    // Borrow yin from trove and send to this contract to repay the flash mint
                    abbot.forge(trove_id, amount.try_into().unwrap(), config.max_forge_fee_pct);
                },
                ModifyLeverAction::LeverDown(params) => {
                    let LeverDownParams { trove_id, yang_asset, swaps } = params;
                    let yang_erc20 = IERC20Dispatcher { contract_address: yang_asset.address };

                    // Use the flash minted yin to repay the trove's debt
                    abbot.melt(trove_id, amount.try_into().unwrap());

                    // Withdraw collateral to this contract
                    abbot.withdraw(trove_id, yang_asset);

                    // Transfer collateral to Ekubo's router and swap for yin
                    yang_erc20.transfer(router.contract_address, yang_asset.amount.into());
                    router.multi_multihop_swap(swaps);

                    // Sanity check to ensure the amount of yin flash minted has been purchased
                    // and can be withdrawn
                    router_clear
                        .clear_minimum(EkuboERC20Dispatcher { contract_address: token }, amount);
                    let yin_amount = yin.balance_of(initiator);

                    // Transfer any excess yin back to the user.
                    if yin_amount > amount {
                        yin.transfer(user, yin_amount - amount);
                    }
                    // Transfer any remainder collateral to the user
                    router_clear
                        .clear_minimum_to_recipient(
                            EkuboERC20Dispatcher { contract_address: yang_asset.address }, 0, user,
                        );
                },
            }

            ON_FLASH_MINT_SUCCESS
        }
    }

    #[generate_trait]
    impl PriorHelpers of PriorHelpersTrait {
        //
        // Assertions
        //

        fn assert_smart_trove_owner(self: @ContractState, user: ContractAddress, trove_id: u64) {
            assert!(self.smart_trove_owners.read(trove_id) == user, "PRI: Not owner");
        }

        fn assert_callback(self: @ContractState) {
            // Guarantee that at least one callback was executed
            assert!(!self.transient_action_nonce.read().is_zero(), "PRI: Callback not executed");
        }

        //
        // View helpers
        //

        fn can_execute_rite_helper(
            self: @ContractState, rite: IRiteDispatcher, trove_id: u64,
        ) -> bool {
            let can_execute: bool = rite.is_ready(trove_id);
            if can_execute {
                let config: SmartTroveConfig = self.smart_trove_configs.read(trove_id);
                let forge_fee_pct: Wad = self.shrine.read().get_forge_fee_pct();
                if forge_fee_pct > config.max_forge_fee_pct {
                    return false;
                }
                true
            } else {
                false
            }
        }

        //
        // State-modifying helpers
        //

        fn clear_locks(ref self: ContractState) {
            self.transient_trove_id.write(Zero::zero());
            self.transient_action_nonce.write(Zero::zero());
        }

        fn execute_action(
            ref self: ContractState,
            trove_id: u64,
            rite_address: ContractAddress,
            abbot: IAbbotDispatcher,
            action: Action,
        ) {
            match action {
                Action::Forge(amount) => {
                    let config: SmartTroveConfig = self.smart_trove_configs.read(trove_id);
                    abbot.forge(trove_id, amount, config.max_forge_fee_pct);

                    // Transfer to rite
                    IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
                        .transfer(rite_address, amount.into());
                },
                Action::Melt(amount) => { abbot.melt(trove_id, amount); },
                Action::Deposit(asset_balance) => {
                    self
                        .approve_token_for_gate(
                            self.sentinel.read(),
                            asset_balance.address,
                            asset_balance.amount.into(),
                        );
                    abbot.deposit(trove_id, asset_balance);
                },
                Action::Withdraw(asset_balance) => {
                    abbot.withdraw(trove_id, asset_balance);

                    IERC20Dispatcher { contract_address: asset_balance.address }
                        .transfer(rite_address, asset_balance.amount.into());
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

        fn deposit_setup(
            ref self: ContractState,
            sentinel: ISentinelDispatcher,
            prior: ContractAddress,
            user: ContractAddress,
            yang_asset: AssetBalance,
        ) {
            let yang = IERC20Dispatcher { contract_address: yang_asset.address };
            yang.transfer_from(user, prior, yang_asset.amount.into());

            self.approve_token_for_gate(sentinel, yang_asset.address, yang_asset.amount.into());
        }
    }
}
