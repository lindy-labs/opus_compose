use ekubo::types::keys::PoolKey;
use opus_compose::vicariate::contracts::rites::auto_topup::types::AutoTopupConfig;
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IAutoTopupRite<TContractState> {
    fn get_auto_topup_config(self: @TContractState, trove_id: u64) -> AutoTopupConfig;
    fn set_pool_key(ref self: TContractState, asset: ContractAddress, pool_key: PoolKey);
    fn set_trove_config(ref self: TContractState, trove_id: u64, config: AutoTopupConfig);
    fn get_forge_amount(self: @TContractState, trove_id: u64) -> Wad;
}

#[starknet::contract]
pub mod auto_topup_rite {
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
    use opus_compose::vicariate::contracts::rites::auto_topup::auto_topup_rite::IAutoTopupRite;
    use opus_compose::vicariate::contracts::rites::auto_topup::types::AutoTopupConfig;
    use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
    use opus_compose::vicariate::interfaces::rite::IRite;
    use opus_compose::vicariate::types::Action;
    use opus_compose::vicariate::utils::sqrt_ratio_limit::calculate_sqrt_ratio_limit;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use wadray::{RAY_PERCENT, Ray, Wad};

    pub const MAX_SLIPPAGE: u128 = RAY_PERCENT * 20;

    #[derive(Copy, Drop)]
    pub struct SwapParams {
        forge_amount: Wad,
        swap_data: Option<(RouteNode, TokenAmount)>,
    }

    #[storage]
    struct Storage {
        yin: IERC20Dispatcher,
        prior: IPriorDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterDispatcher,
        auto_topup_configs: Map<u64, AutoTopupConfig>, // ATU trove ID -> config
        // Mapping of ERC-20 to the key of the pool to swap against.
        // Swaps are made against a single pool to guarantee on-chain execution.
        pool_keys: Map<ContractAddress, StoragePoolKey>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AutoTopupConfigUpdated: AutoTopupConfigUpdated,
        TopupExecuted: TopupExecuted,
        PoolKeySet: PoolKeySet,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct AutoTopupConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: AutoTopupConfig,
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
    pub impl IAutoTopupRiteImpl of IAutoTopupRite<ContractState> {
        fn get_auto_topup_config(self: @ContractState, trove_id: u64) -> AutoTopupConfig {
            self.auto_topup_configs.read(trove_id)
        }

        fn get_forge_amount(self: @ContractState, trove_id: u64) -> Wad {
            let config = self.auto_topup_configs.read(trove_id);
            let swap_params: SwapParams = self
                .preview_topup(
                    trove_id, config.tracked_asset, config.topup_amount, config.slippage,
                );
            swap_params.forge_amount
        }

        fn set_pool_key(ref self: ContractState, asset: ContractAddress, pool_key: PoolKey) {
            let cash = self.yin.read().contract_address;
            assert!(
                minmax(pool_key.token0, pool_key.token1) == minmax(asset, cash),
                "ATU: Invalid pool key assets",
            );
            self.pool_keys.write(asset, pool_key.into());

            self.emit(PoolKeySet { asset, pool_key });
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: AutoTopupConfig) {
            let user = get_caller_address();
            let prior_abbot = IAbbotDispatcher {
                contract_address: self.prior.read().contract_address,
            };
            assert!(
                prior_abbot.get_trove_owner(trove_id).expect('ATU: Trove not found') == user,
                "ATU: Not owner",
            );

            assert!(
                self.pool_keys.read(config.tracked_asset).token0.is_non_zero(), "ATU: No swap path",
            );
            assert!(
                config.topup_amount.is_zero() // Topup is disabled
                    || config
                        .topup_amount >= config
                        .min_tracked_asset_balance // Prevent multiple topups
                        ,
                "ATU: Invalid topup amount",
            );
            assert!(config.destination.is_non_zero(), "ATU: Invalid destination");
            assert!(
                config.slippage.is_non_zero() && config.slippage <= MAX_SLIPPAGE.into(),
                "ATU: Slippage out of acceptable range",
            );

            self.auto_topup_configs.write(trove_id, config);

            self.emit(AutoTopupConfigUpdated { user, trove_id, config });
        }
    }

    #[abi(embed_v0)]
    pub impl IRiteImpl of IRite<ContractState> {
        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.auto_topup_configs.read(trove_id);
            // Zero topup amount is used as a flag for disabling auto-topup
            if config.topup_amount.is_zero() {
                return false;
            }

            let tracked_balance = IERC20Dispatcher { contract_address: config.tracked_asset }
                .balance_of(config.destination);
            tracked_balance < config.min_tracked_asset_balance.into()
        }

        fn perform(ref self: ContractState, trove_id: u64) {
            let prior = self.prior.read();
            let caller: ContractAddress = get_caller_address();
            // Prior should have checked that the rite can be executed
            assert!(caller == prior.contract_address, "ATU: Caller not Prior");

            let config = self.auto_topup_configs.read(trove_id);
            let swap_params: SwapParams = self
                .preview_topup(
                    trove_id, config.tracked_asset, config.topup_amount, config.slippage,
                );

            prior.on_execute_rite(trove_id, Action::Forge(swap_params.forge_amount));

            let cash = self.yin.read();

            if let Some((route_node, token_amount)) = swap_params.swap_data {
                let ekubo_router = self.ekubo_router.read();
                cash.transfer(ekubo_router.contract_address, swap_params.forge_amount.into());
                ekubo_router.swap(route_node, token_amount);

                IClearDispatcher { contract_address: ekubo_router.contract_address }
                    .clear_minimum_to_recipient(
                        EkuboERC20Dispatcher { contract_address: config.tracked_asset },
                        0,
                        config.destination,
                    );
            } else {
                cash.transfer(config.destination, swap_params.forge_amount.into());
            }

            self
                .emit(
                    TopupExecuted {
                        caller,
                        trove_id,
                        forge_amount: swap_params.forge_amount,
                        tracked_asset: config.tracked_asset,
                        topup_amount: config.topup_amount,
                        destination: config.destination,
                    },
                );
        }
    }

    #[generate_trait]
    impl AutoTopupRiteHelpers of AutoTopupRiteHelpersTrait {
        fn preview_topup(
            self: @ContractState,
            trove_id: u64,
            tracked_asset: ContractAddress,
            topup_amount: u128,
            slippage: Ray,
        ) -> SwapParams {
            let cash = self.yin.read().contract_address;
            let pool_key: PoolKey = self.pool_keys.read(tracked_asset).into();
            assert!(tracked_asset == cash || pool_key.token0.is_non_zero(), "ATU: No swap path");

            if tracked_asset == cash {
                SwapParams { forge_amount: topup_amount.into(), swap_data: Option::None }
            } else {
                let ekubo_core = self.ekubo_core.read();
                let ekubo_router = self.ekubo_router.read();

                let pool_price: PoolPrice = ekubo_core.get_pool_price(pool_key);
                let cash_is_token0: bool = pool_key.token0 == cash;
                let sqrt_ratio_limit = calculate_sqrt_ratio_limit(
                    pool_price.sqrt_ratio, slippage, cash_is_token0,
                );
                let route_node = RouteNode { pool_key, sqrt_ratio_limit, skip_ahead: 0 };
                let token_amount = TokenAmount {
                    token: tracked_asset, amount: topup_amount.into(),
                };
                let quote_delta: Delta = ekubo_router.quote_swap(route_node, token_amount);
                let cash_amount: u128 = if cash_is_token0 {
                    (-quote_delta.amount0).try_into().unwrap()
                } else {
                    (-quote_delta.amount1).try_into().unwrap()
                };
                SwapParams {
                    forge_amount: cash_amount.into(),
                    swap_data: Option::Some((route_node, token_amount)),
                }
            }
        }
    }
}
