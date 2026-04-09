#[starknet::component]
pub mod EkuboDcaComponent {
    use core::num::traits::Zero;
    use ekubo::interfaces::extensions::twamm::OrderKey;
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::types::keys::PoolKey;
    use opus::types::AssetBalance;
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus_compose::vicariate::contracts::rites::dca::types::{
        ConsolidatedOrderData, DcaDurationTrait, DcaOrder, DcaOrderDuration, OrderStatus, OrderType,
    };
    use opus_compose::vicariate::contracts::rites::dca::utils::dca_utils;
    use opus_compose::vicariate::contracts::rites::types::{EkuboPoolParams, EkuboPoolParamsTrait};
    use opus_compose::vicariate::interfaces::prior::{IPriorDispatcher, IPriorDispatcherTrait};
    use opus_compose::vicariate::types::Action;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};

    #[storage]
    pub struct Storage {
        pub ekubo_positions: IPositionsDispatcher,
        pub twamm_orders: Map<u64, DcaOrder>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        TwammOrderClosed: TwammOrderClosed,
        TwammOrderCreated: TwammOrderCreated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TwammOrderCreated {
        #[key]
        pub trove_id: u64,
        #[key]
        pub asset: ContractAddress,
        pub order_id: u64,
        pub order_type: OrderType,
        pub fee: u128,
        pub order_duration: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TwammOrderClosed {
        #[key]
        pub trove_id: u64,
        #[key]
        pub asset: ContractAddress,
        pub order_id: u64,
        pub order_type: OrderType,
        pub remaining_sell_token: u128,
        pub purchased_buy_token: u128,
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn get_consolidated_order_data(
            self: @ComponentState<TContractState>,
            yin: ContractAddress,
            asset: ContractAddress,
            order: DcaOrder,
        ) -> ConsolidatedOrderData {
            let mut consolidated = ConsolidatedOrderData {
                order_key: Option::None, order_status: OrderStatus::None, order_info: Option::None,
            };
            if order.position_id.is_zero() {
                return consolidated;
            }

            let order_key: OrderKey = dca_utils::get_order_key_from_order(order, yin, asset);
            let ekubo_positions = self.ekubo_positions.read();
            let order_info = ekubo_positions.get_order_info(order.position_id, order_key);

            consolidated.order_key = Option::Some(order_key);
            consolidated.order_info = Option::Some(order_info);

            let is_ongoing: bool = order_info.remaining_sell_amount.is_non_zero();
            if is_ongoing {
                consolidated.order_status = OrderStatus::Ongoing;
                return consolidated;
            }

            let has_withdrawn: bool = order_info.purchased_amount.is_zero();
            if has_withdrawn {
                consolidated.order_status = OrderStatus::CompletedAndWithdrawn;
            } else {
                consolidated.order_status = OrderStatus::CompletedNotWithdrawn;
            }

            consolidated
        }

        fn has_ended(
            self: @ComponentState<TContractState>,
            yin: ContractAddress,
            asset: ContractAddress,
            trove_id: u64,
        ) -> bool {
            let order: DcaOrder = self.twamm_orders.read(trove_id);
            if order.position_id.is_zero() {
                return true;
            }

            let consolidated = self.get_consolidated_order_data(yin, asset, order);
            match consolidated.order_status {
                OrderStatus::Ongoing => false,
                _ => true,
            }
        }

        // Closes a TWAMM order and withdraws the proceeds to Prior directly.
        fn close_order(
            ref self: ComponentState<TContractState>,
            yin: IERC20Dispatcher,
            prior: IPriorDispatcher,
            trove_id: u64,
            asset: ContractAddress,
            order: DcaOrder,
            force_closure: bool,
            rite_id: ByteArray,
        ) {
            let ConsolidatedOrderData {
                order_key, order_status, order_info,
            } = self.get_consolidated_order_data(yin.contract_address, asset, order);

            let ekubo_positions = self.ekubo_positions.read();

            let mut remaining_sell_token: u128 = Zero::zero();
            let mut purchased_buy_token: u128 = Zero::zero();

            match order_status {
                OrderStatus::None |
                OrderStatus::CompletedAndWithdrawn => {
                    let action = Action::None;
                    prior.on_rite_actions(trove_id, array![action].span());
                    return;
                },
                OrderStatus::CompletedNotWithdrawn => {},
                OrderStatus::Ongoing => {
                    assert!(force_closure, "{}: Ongoing order", rite_id);

                    let order_key = order_key.unwrap();
                    let order_info = order_info.unwrap();
                    remaining_sell_token = ekubo_positions
                        .decrease_sale_rate_to(
                            order.position_id,
                            order_key,
                            order_info.sale_rate,
                            prior.contract_address,
                        );
                },
            }

            // Withdraw purchased tokens directly to Prior
            let order_key = order_key.unwrap();
            purchased_buy_token = ekubo_positions
                .withdraw_proceeds_from_sale_to(
                    order.position_id, order_key, prior.contract_address,
                );

            let mut actions: Array<Action> = Default::default();
            match order.order_type {
                OrderType::BuyAsset => {
                    let action = Action::Deposit(
                        AssetBalance { address: asset, amount: purchased_buy_token },
                    );
                    actions.append(action);
                },
                OrderType::SellAsset => {
                    let action = Action::Melt(purchased_buy_token.into());
                    actions.append(action);
                },
                OrderType::None => { return; },
            }

            if remaining_sell_token.is_non_zero() {
                match order.order_type {
                    OrderType::BuyAsset => {
                        let action = Action::Melt(remaining_sell_token.into());
                        actions.append(action);
                    },
                    OrderType::SellAsset => {
                        let action = Action::Deposit(
                            AssetBalance { address: asset, amount: remaining_sell_token },
                        );
                        actions.append(action);
                    },
                    OrderType::None => { return; },
                };
            }

            prior.on_rite_actions(trove_id, actions.span());

            self.twamm_orders.write(trove_id, Default::default());

            self
                .emit(
                    TwammOrderClosed {
                        trove_id,
                        asset,
                        order_id: order.position_id,
                        order_type: order.order_type,
                        remaining_sell_token,
                        purchased_buy_token,
                    },
                );
        }

        fn create_order(
            ref self: ComponentState<TContractState>,
            yin: IERC20Dispatcher,
            prior: IPriorDispatcher,
            trove_id: u64,
            asset: ContractAddress,
            pool_params: EkuboPoolParams,
            order_type: OrderType,
            order_duration: DcaOrderDuration,
            order_amount: u128,
            rite_id: ByteArray,
        ) {
            // Should be unreachable
            if order_amount.is_zero() {
                return;
            }

            let pool_key: PoolKey = pool_params.into_pool_key(asset, yin.contract_address);

            let ekubo_positions = self.ekubo_positions.read();

            let mut sell_token: ContractAddress = Zero::zero();
            let mut buy_token: ContractAddress = Zero::zero();
            match order_type {
                OrderType::BuyAsset => {
                    let action = Action::Forge(order_amount.into());
                    prior.on_rite_actions(trove_id, array![action].span());
                    yin.transfer(ekubo_positions.contract_address, order_amount.into());

                    sell_token = yin.contract_address;
                    buy_token = asset;
                },
                OrderType::SellAsset => {
                    let action = Action::Withdraw(
                        AssetBalance { address: asset, amount: order_amount },
                    );
                    prior.on_rite_actions(trove_id, array![action].span());
                    IERC20Dispatcher { contract_address: asset }
                        .transfer(ekubo_positions.contract_address, order_amount.into());

                    sell_token = asset;
                    buy_token = yin.contract_address;
                },
                OrderType::None => {
                    // Should be unreachable because Prior already checked if
                    // rite is ready for execution
                    return;
                },
            }

            let start_time: u64 = get_block_timestamp();
            let end_time: u64 = order_duration.to_valid_end_time(start_time);
            let order_key = OrderKey {
                sell_token, buy_token, fee: pool_key.fee, start_time: 0, end_time,
            };

            let (position_id, _sale_rate) = ekubo_positions
                .mint_and_increase_sell_amount(order_key, order_amount);

            self
                .set_order(
                    trove_id, DcaOrder { position_id, fee: pool_key.fee, end_time, order_type },
                );

            self
                .emit(
                    TwammOrderCreated {
                        trove_id,
                        asset,
                        order_id: position_id,
                        order_type,
                        fee: pool_key.fee,
                        order_duration: order_duration.to_seconds(),
                    },
                );
        }

        fn set_ekubo_positions(
            ref self: ComponentState<TContractState>, positions: ContractAddress,
        ) {
            self.ekubo_positions.write(IPositionsDispatcher { contract_address: positions });
        }

        fn get_order(self: @ComponentState<TContractState>, trove_id: u64) -> DcaOrder {
            self.twamm_orders.read(trove_id)
        }

        fn set_order(ref self: ComponentState<TContractState>, trove_id: u64, order: DcaOrder) {
            self.twamm_orders.write(trove_id, order);
        }

        fn clear_order(ref self: ComponentState<TContractState>, trove_id: u64) {
            self.twamm_orders.write(trove_id, Default::default());
        }
    }
}
