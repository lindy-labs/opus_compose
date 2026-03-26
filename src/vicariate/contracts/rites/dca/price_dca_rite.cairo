use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IPriceDcaRite<TContractState> {
    fn set_pool_key(ref self: TContractState, asset: ContractAddress, pool_key: PoolKey);
}

#[starknet::contract]
pub mod price_dca_rite {
    use starknet::get_block_timestamp;
use core::cmp::minmax;
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::extensions::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::router::{
        IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount,
    };
    use ekubo::types::delta::Delta;
    use ekubo::types::keys::PoolKey;
    use ekubo::types::pool_price::PoolPrice;
    use opus::interfaces::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use opus_compose::constants;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::stabilizer::types::StoragePoolKey;
    use opus_compose::vicariate::contracts::rites::dca::types::PriceDcaConfig;
    use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
    use opus_compose::vicariate::interfaces::rite::IRite;
    use opus_compose::vicariate::types::Action;
    use opus_compose::vicariate::utils::sqrt_ratio_limit::calculate_sqrt_ratio_limit;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use super::IPriceDcaRite;
    use wadray::{RAY_PERCENT, Ray, Wad};

    const CASH_DECIMALS: u8 = 18;
    pub const TWAP_DURATION: u64 = 5 * 60;

    #[storage]
    struct Storage {
        yin: IERC20Dispatcher,
        prior: IPriorDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterDispatcher,
        ekubo_oracle: IOracleDispatcher,
        price_dca_configs: Map<u64, PriceDcaConfig>, // ADCA trove ID -> config
        // Mapping of ERC-20 to the key of the pool to swap against.
        // Swaps are made against a single pool to guarantee on-chain execution.
        pool_keys: Map<ContractAddress, StoragePoolKey>,
        // Mapping of smart trove ID to Ekubo NFT ID
        // TODO: Should it be reset to zero after order is stopped/completed?
        twamm_orders: Map<u64, u128>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        PriceDcaConfigUpdated: PriceDcaConfigUpdated,
        PoolKeySet: PoolKeySet,
        TwammOrderCreated: TwammOrderCreated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PriceDcaConfigUpdated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        pub config: PriceDcaConfig,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PoolKeySet {
        #[key]
        pub asset: ContractAddress,
        pub pool_key: PoolKey,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TwammOrderCreated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub asset: ContractAddress,
        // This need not be indexed since it is unique for each order
        pub order_id: u128,
        pub dca_duration: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        yin: ContractAddress,
        prior: ContractAddress,
        ekubo_router: ContractAddress,
        ekubo_core: ContractAddress,
        ekubo_oracle: ContractAddress,
    ) {
        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.prior.write(IPriorDispatcher { contract_address: prior });

        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_router.write(IRouterDispatcher { contract_address: ekubo_router });
        self.ekubo_oracle.write(IOracleDispatcher { contract_address: ekubo_oracle });
    }

    #[abi(embed_v0)]
    pub impl IPriceDcaRiteImpl of IPriceDcaRite<ContractState> {
        fn set_pool_key(ref self: ContractState, asset: ContractAddress, pool_key: PoolKey) {
            let cash = self.yin.read().contract_address;
            assert!(
                minmax(pool_key.token0, pool_key.token1) == minmax(asset, cash),
                "ADCA: Invalid pool key assets",
            );

            assert!(pool_key.tick_spacing == constants::EKUBO_TWAMM_TICK_SPACING, "ADCA: Wrong tick spacing");

            self.pool_keys.write(asset, pool_key.into());

            self.emit(PoolKeySet { asset, pool_key });
        }
    }

    #[abi(embed_v0)]
    pub impl IRiteImpl of IRite<ContractState> {
        fn get_rite_id(self: @ContractState) -> felt252 {
            'PRICE_DCA'
        }

        fn get_trove_config(self: @ContractState, trove_id: u64) -> Span<felt252> {
            let config = self.price_dca_configs.read(trove_id);
            let mut serialized_config: Array<felt252> = Default::default();
            config.serialize(ref serialized_config);
            serialized_config.span()
        }

        fn set_trove_config(ref self: ContractState, trove_id: u64, config: Span<felt252>) {
            let mut config = config;
            let config: PriceDcaConfig = Serde::<PriceDcaConfig>::deserialize(ref config).expect('ADCA: Invalid config');

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

            self.price_dca_configs.write(trove_id, config);

            self.emit(PriceDcaConfigUpdated { user, trove_id, config });
        }

        fn is_ready(self: @ContractState, trove_id: u64) -> bool {
            let config = self.price_dca_configs.read(trove_id);
            // Zero order amounts are used as a flag for disabling price-DCA
            let buy_is_enabled: bool = config.buy_amount.is_non_zero();
            let sell_is_enabled: bool = config.sell_amount.is_non_zero();
            if !buy_is_enabled && !sell_is_enabled {
                return false;
            }

            let asset_price: Wad = self.get_asset_price(config.asset, config.period);
            let should_buy: bool = buy_is_enabled && asset_price <= config.buy_price;
            let should_sell: bool = sell_is_enabled && asset_price >= config.sell_price;

            if should_buy || should_sell {
                let existing_order: u128 = self.twamm_orders.read(trove_id);
                // TODO: Check if there is an existing order
            }

            false
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

            let config = self.price_dca_configs.read(trove_id);

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
    impl PriceDcaRiteHelpers of PriceDcaRiteHelpersTrait {
        // Returns the price of the asset in CASH
        fn get_asset_price(self: @ContractState, asset: ContractAddress, period: u64) -> Wad {
            let oracle = self.ekubo_oracle.read();
            let price_x128: u256 = oracle.get_price_x128_over_last(
                    asset,
                    self.yin.read().contract_address,
                    period
                );

            convert_ekubo_oracle_price_to_wad(
                price_x128, 
                IERC20Dispatcher { contract_address: asset }.decimals(), 
                CASH_DECIMALS,
            )
        }
    }
}
