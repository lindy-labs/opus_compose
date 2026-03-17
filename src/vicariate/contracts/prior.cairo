#[starknet::contract]
pub mod prior {
    use core::num::traits::Zero;
    use core::option::OptionTrait;
    use opus::interfaces::abbot::IAbbot;
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, ICaretakerDispatcher, ICaretakerDispatcherTrait,
        ISentinelDispatcher, ISentinelDispatcherTrait, IShrineDispatcher, IShrineDispatcherTrait,
    };
    use opus::types::{AssetBalance, Health};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::vicariate::interfaces::prior::IPrior;
    use opus_compose::vicariate::interfaces::rite::{IRiteDispatcher, IRiteDispatcherTrait};
    use opus_compose::vicariate::types::{Action, SmartTroveConfig};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{RAY_ONE, Ray, Wad};
    use crate::vicariate::interfaces::rite::IRite;

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        caretaker: ICaretakerDispatcher,
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
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        SmartTroveCreated: SmartTroveCreated,
        ConfigUpdated: ConfigUpdated,
        TopupExecuted: TopupExecuted,
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
    pub struct TopupExecuted {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub borrow_amount: Wad,
        pub topup_amount: u128,
        pub destination: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        abbot: ContractAddress,
        caretaker: ContractAddress,
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.caretaker.write(ICaretakerDispatcher { contract_address: caretaker });
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

            // Transfer yang from user to this contract
            let yang_erc20 = IERC20Dispatcher { contract_address: yang_asset.address };
            yang_erc20.transfer_from(caller, get_contract_address(), yang_asset.amount.into());

            // Approve Gate for yang
            let gate_address = self.sentinel.read().get_gate_address(yang_asset.address);
            yang_erc20.approve(gate_address, yang_asset.amount.into());

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
            assert!(config.relative_threshold <= RAY_ONE.into(), "PRI: Invalid relative threshold");

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

            let rite = IRiteDispatcher { contract_address: rite };
            self.can_execute_rite_helper(rite, trove_id);

            self.rites.write(trove_id, rite);
        }

        // Note that this does not check that the LTV does not exceed the relative threhsold
        // at the end of the rite.
        fn can_execute_rite(self: @ContractState, trove_id: u64) -> bool {
            let rite = self.rites.read(trove_id);
            self.can_execute_rite_helper(rite, trove_id)
        }

        fn execute_rite(ref self: ContractState, trove_id: u64) {
            let rite = self.rites.read(trove_id);
            assert!(self.can_execute_rite_helper(rite, trove_id), "PRI: Cannot execute rite");

            rite.perform(trove_id);

            // Check LTV condition if relative_threshold is set
            let config: SmartTroveConfig = self.smart_trove_configs.read(trove_id);
            let trove_health: Health = self.shrine.read().get_trove_health(trove_id);
            let stop_ltv: Ray = trove_health.threshold * config.relative_threshold;
            assert!(trove_health.ltv <= stop_ltv, "PRI: LTV exceeds relative threshold");
        }

        // Callback function to be called by `rite.perform(...)`
        // Checks that the caller is the rite specified for the smart trove
        fn on_execute_rite(ref self: ContractState, trove_id: u64, action: Action) {
            let caller: ContractAddress = get_caller_address();
            let rite = self.rites.read(trove_id);
            assert!(caller == rite.contract_address, "PRI: Caller not rite");

            match action {
                Action::Forge(amount) => {
                    let config: SmartTroveConfig = self.smart_trove_configs.read(trove_id);
                    self.forge(trove_id, amount, config.max_forge_fee_pct);

                    // Transfer to rite
                    IERC20Dispatcher { contract_address: self.shrine.read().contract_address }
                        .transfer(rite.contract_address, amount.into());
                },
                Action::Melt(amount) => { self.melt(trove_id, amount); },
                Action::Deposit(asset_balance) => {
                    // Approve Gate for yang
                    let gate_address = self.sentinel.read().get_gate_address(asset_balance.address);
                    let yang_erc20 = IERC20Dispatcher { contract_address: asset_balance.address };
                    yang_erc20.approve(gate_address, asset_balance.amount.into());

                    self.abbot.read().deposit(trove_id, asset_balance);
                },
                Action::Withdraw(asset_balance) => {
                    self.abbot.read().withdraw(trove_id, asset_balance);

                    IERC20Dispatcher { contract_address: asset_balance.address }
                        .transfer(rite.contract_address, asset_balance.amount.into());
                },
            };
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

    #[generate_trait]
    impl PriorHelpers of PriorHelpersTrait {
        fn assert_smart_trove_owner(self: @ContractState, user: ContractAddress, trove_id: u64) {
            assert!(self.smart_trove_owners.read(trove_id) == user, "PRI: Not owner");
        }

        fn can_execute_rite_helper(
            self: @ContractState, rite: IRiteDispatcher, trove_id: u64,
        ) -> bool {
            let can_execute: bool = rite.is_ready(trove_id);

            let config: SmartTroveConfig = self.smart_trove_configs.read(trove_id);
            let forge_fee_pct: Wad = self.shrine.read().get_forge_fee_pct();
            if forge_fee_pct > config.max_forge_fee_pct {
                return false;
            }

            can_execute
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

            let gate = sentinel.get_gate_address(yang_asset.address);
            yang.approve(gate, yang_asset.amount.into());
        }
    }
}
