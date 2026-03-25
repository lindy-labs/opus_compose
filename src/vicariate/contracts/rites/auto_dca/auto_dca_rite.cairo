use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IAutoDcaRite<TContractState> {
    fn set_pool_key(ref self: TContractState, asset: ContractAddress, pool_key: PoolKey);
}

#[starknet::contract]
pub mod auto_dca_rite {
    use core::cmp::minmax;
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::router::{
        IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount,
    };
    use ekubo::types::delta::Delta;
    use ekubo::types::keys::PoolKey;
    use ekubo::types::pool_price::PoolPrice;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::stabilizer::types::StoragePoolKey;
    use opus_compose::vicariate::contracts::rites::auto_dca::types::AutoDcaConfig;
    use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
    use opus_compose::vicariate::interfaces::rite::IRite;
    use opus_compose::vicariate::types::Action;
    use opus_compose::vicariate::utils::sqrt_ratio_limit::calculate_sqrt_ratio_limit;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use super::IAutoDcaRite;
    use wadray::{RAY_PERCENT, Ray, Wad};

    #[storage]
    struct Storage {
        yin: IERC20Dispatcher,
        prior: IPriorDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterDispatcher,
        auto_dca_configs: Map<u64, AutoDcaConfig>, // ADCA trove ID -> config
        // Mapping of ERC-20 to the key of the pool to swap against.
        // Swaps are made against a single pool to guarantee on-chain execution.
        pool_keys: Map<ContractAddress, StoragePoolKey>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AutoDcaConfigUpdated: AutoDcaConfigUpdated,
        TopupExecuted: TopupExecuted,
        PoolKeySet: PoolKeySet,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct AutoDcaConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: AutoDcaConfig,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TopupExecuted {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub forge_amount: Wad,
        pub tracked_asset: ContractAddress,
        pub topup_amount: u128,
        pub destination: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PoolKeySet {
        #[key]
        pub asset: ContractAddress,
        pub pool_key: PoolKey,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        yin: ContractAddress,
        prior: ContractAddress,
        ekubo_router: ContractAddress,
        ekubo_core: ContractAddress,
    ) {
        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.prior.write(IPriorDispatcher { contract_address: prior });

        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });
    }

    #[abi(embed_v0)]
    pub impl IAutoDcaRiteImpl of IAutoDcaRite<ContractState> {
        fn set_pool_key(ref self: ContractState, asset: ContractAddress, pool_key: PoolKey) {
            let cash = self.yin.read().contract_address;
            assert!(
                minmax(pool_key.token0, pool_key.token1) == minmax(asset, cash),
                "ADCA: Invalid pool key assets",
            );
            // TODO: Assert DCA pool
            self.pool_keys.write(asset, pool_key.into());

            self.emit(PoolKeySet { asset, pool_key });
        }
    }

    #[abi(embed_v0)]
    pub impl IRiteImpl of IRite<ContractState> {
        fn get_rite_id(self: @ContractState) -> felt252 {
            'AUTO_DCA'
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> Span<felt252> {
            let config = self.auto_dca_configs.read(trove_id);
            let mut serialized_config: Array<felt252> = Default::default();
            config.serialize(ref serialized_config);
            serialized_config.span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            let mut config = config;
            let config: AutoDcaConfig = Serde::<AutoDcaConfig>::deserialize(ref config).expect('ADCA: Invalid config');

            let user = get_caller_address();
            let prior_abbot = IAbbotDispatcher {
                contract_address: self.prior.read().contract_address,
            };
            assert!(
                prior_abbot.get_trove_owner(trove_id).expect('ADCA: Trove not found') == user,
                "ADCA: Not owner",
            );

            assert!(config.asset.is_non_zero(), "ADCA: Invalid asset");
            if config.buy_price.is_non_zero() {
                assert!(
                    self.pool_keys.read(config.asset).token0.is_non_zero(), "ADCA: No swap path",
                );
                assert!(
                    config.sell_price.is_zero() // Sell DCA is disabled
                        || config.sell_price > config.buy_price
                            ,
                    "ADCA: Invalid sell price",
                );
                // TODO: Sanity check duration
            }

            self.auto_dca_configs.write(trove_id, config);

            self.emit(AutoDcaConfigUpdated { user, trove_id, config });
        }

        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.auto_dca_configs.read(trove_id);
            // Zero buy price is used as a flag for disabling auto-DCA
            if config.buy_price.is_zero() {
                return false;
            }

            // TODO
            true
        }

        fn has_ended(self: @ContractState, trove_id: u64) -> bool {
            true
            // TODO
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            // Prior should have checked that the rite can be executed
            assert!(caller == prior.contract_address, "ADCA: Caller not Prior");

            let config = self.auto_dca_configs.read(trove_id);

            //prior.on_rite_action(trove_id, Action::Forge(swap_params.forge_amount));

            //let cash = self.yin.read();

            //if let Some((route_node, token_amount)) = swap_params.swap_data {
            //    let ekubo_router = self.ekubo_router.read();
            //    cash.transfer(ekubo_router.contract_address, swap_params.forge_amount.into());
            //    ekubo_router.swap(route_node, token_amount);

            //    IClearDispatcher { contract_address: ekubo_router.contract_address }
            //        .clear_minimum_to_recipient(
            //            EkuboERC20Dispatcher { contract_address: config.tracked_asset },
            //            0,
            //            config.destination,
            //        );
            //} else {
            //    cash.transfer(config.destination, swap_params.forge_amount.into());
            //}

            //self
            //    .emit(
            //        TopupExecuted {
            //            caller,
            //            trove_id,
            //            forge_amount: swap_params.forge_amount,
            //            tracked_asset: config.tracked_asset,
            //            topup_amount: config.topup_amount,
            //            destination: config.destination,
            //        },
            //    );
        }

        fn end(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            assert!(caller == prior.contract_address, "ADCA: Caller not Prior");

            prior.on_rite_action(trove_id, Action::None);
        }
    }

    #[generate_trait]
    impl AutoDcaRiteHelpers of AutoDcaRiteHelpersTrait {
        
    }
}
