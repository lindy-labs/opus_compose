#[starknet::contract]
pub mod lever {
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use ekubo::router_lite::{
        IRouterLiteDispatcher, IRouterLiteDispatcherTrait, RouteNode, TokenAmount
    };
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, IFlashBorrower, IFlashMintDispatcher,
        IFlashMintDispatcherTrait, ISentinelDispatcher, ISentinelDispatcherTrait, IShrineDispatcher,
        IShrineDispatcherTrait
    };
    use opus_lever::interface::ILever;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use wadray::Wad;

    //
    // Constants
    //

    // The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
    // it is supposed to be returned from the onFlashLoan function by the receiver
    const ON_FLASH_MINT_SUCCESS: u256 =
        0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9_u256;

    const USDC: felt252 = 0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8;

    const POOL_FEE: u128 = 170141183460469235273462165868118016; // 0.05% pool fee
    const TICK_SPACING: u128 = 1000; // 0.1% tick fee

    //
    // Storage
    //

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        flash_mint: IFlashMintDispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_router: IRouterLiteDispatcher
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        LeverDeposit: LeverDeposit,
        LeverWithdraw: LeverWithdraw
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct LeverDeposit {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub yang_amt: Wad,
        pub asset_amt: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct LeverWithdraw {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub trove_id: u64,
        #[key]
        pub yang: ContractAddress,
        pub yang_amt: Wad,
        pub asset_amt: u128
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
        ekubo_core: ContractAddress,
        ekubo_router: ContractAddress
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.flash_mint.write(IFlashMintDispatcher { contract_address: flash_mint });
        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_router.write(IRouterLiteDispatcher { contract_address: ekubo_router });
    }

    //
    // External Lever functions
    //

    #[abi(embed_v0)]
    impl ILeverImpl of ILever<ContractState> {
        // Take a long position on a specific collateral for a Trove
        // Steps are as follows:
        // 1. Flash mint CASH to this contract
        // 2. Purchase collateral asset with flash-minted CASH via Ekubo
        // 3. Deposit purchased collateral asset to caller's trove
        // 4. Borrow CASH from caller's trove
        fn up(
            ref self: ContractState,
            trove_id: u64,
            amount: Wad,
            yang: ContractAddress,
            max_forge_fee_pct: Wad
        ) {
            let caller: ContractAddress = get_caller_address();
            assert(
                caller == self.abbot.read().get_trove_owner(trove_id).expect('Non-existent trove'),
                'LEV: Not trove owner'
            );

            // Calldata:
            // - Whether the action is taking on leverage or not (i.e. unwinding)
            // - User calling this function, who is also the trove owner
            // - Trove ID
            // - Address of collateral asset
            // - Maximum forge fee pct for user
            let mut call_data: Array<felt252> = array![
                true.into(), caller.into(), trove_id.into(), yang.into(), max_forge_fee_pct.into()
            ];
            self
                .flash_mint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    amount.into(),
                    call_data.span()
                );
        }

        // Unwind a position for a specific collateral for a Trove
        // Steps are as follows:
        // 1. Flash mint CASH to this contract
        // 2. Repay CASH for trove
        // 3. Withdraw collateral asset from trove
        // 4. Purchase CASH with withdrawn collateral asset via Ekubo
        // 5. Transfer remainder collateral asset to user
        fn down(
            ref self: ContractState,
            trove_id: u64,
            amount: Wad,
            yang: ContractAddress,
            yang_amt: Wad
        ) {
            let caller: ContractAddress = get_caller_address();
            assert(
                caller == self.abbot.read().get_trove_owner(trove_id).expect('Non-existent trove'),
                'LEV: Not trove owner'
            );

            // Calldata:
            // - Whether the action is taking on leverage or not (i.e. unwinding)
            // - User calling this function, who is also the trove owner
            // - Trove ID
            // - Address of collateral asset
            // - Amount of collateral's yang to withdraw
            let mut call_data: Array<felt252> = array![
                false.into(), caller.into(), trove_id.into(), yang.into(), yang_amt.into()
            ];
            self
                .flash_mint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    amount.into(),
                    call_data.span()
                );
        }
    }

    #[abi(embed_v0)]
    impl IFlashBorrowerImpl of IFlashBorrower<ContractState> {
        // This contract needs to call `shrine.forge` and `shrine.deposit` directly to get around
        // the checks in Abbot that the caller is the trove owner.
        fn on_flash_loan(
            ref self: ContractState,
            initiator: ContractAddress,
            token: ContractAddress,
            amount: u256,
            fee: u256,
            mut call_data: Span<felt252>
        ) -> u256 {
            let lever_up: bool = match *call_data.pop_front().unwrap() {
                0 => false,
                _ => true
            };
            let caller: ContractAddress = (*call_data.pop_front().unwrap()).try_into().unwrap();
            let trove_id: u64 = (*call_data.pop_front().unwrap()).try_into().unwrap();
            let yang = (*call_data.pop_front().unwrap()).try_into().unwrap();
            let yang_erc20 = IERC20Dispatcher { contract_address: yang };

            let usdc: ContractAddress = USDC.try_into().unwrap();

            let shrine = self.shrine.read();
            let cash = IERC20Dispatcher { contract_address: shrine.contract_address };
            let sentinel = self.sentinel.read();
            let router = self.ekubo_router.read();
            let router_clear = IClearDispatcher { contract_address: router.contract_address };

            if lever_up {
                let max_forge_fee_pct: u128 = (*call_data.pop_front().unwrap()).try_into().unwrap();

                cash.transfer(router.contract_address, amount);
                let route: Array<RouteNode> = array![
                    self.construct_route_node(token, usdc), self.construct_route_node(usdc, yang)
                ];
                router
                    .multihop_swap(
                        route,
                        TokenAmount {
                            token, amount: i129 { mag: amount.try_into().unwrap(), sign: false }
                        }
                    );
                // Sanity check to ensure the collateral asset has been purchased and can be
                // withdrawn
                let yang_asset_amt: u256 = router_clear.clear_minimum(yang_erc20, 1);

                // Deposit collateral asset to trove
                yang_erc20.approve(sentinel.get_gate_address(yang), yang_asset_amt);

                let yang_amt: Wad = sentinel
                    .enter(yang, get_contract_address(), yang_asset_amt.try_into().unwrap());
                shrine.deposit(yang, trove_id, yang_amt);

                self
                    .emit(
                        LeverDeposit {
                            user: caller,
                            trove_id,
                            yang,
                            yang_amt,
                            asset_amt: yang_asset_amt.try_into().unwrap()
                        }
                    );

                // Borrow CASH from trove and send to this contract to repay the flash mint
                shrine
                    .forge(
                        initiator, trove_id, amount.try_into().unwrap(), max_forge_fee_pct.into()
                    );
            } else {
                let yang_amt: u128 = (*call_data.pop_front().unwrap()).try_into().unwrap();
                let yang_amt: Wad = yang_amt.into();

                // Use the flash minted CASH to repay the trove's debt
                self.abbot.read().melt(trove_id, amount.try_into().unwrap());

                // Withdraw collateral to this contract
                let yang_asset_amt: u128 = sentinel.exit(yang, initiator, yang_amt);
                shrine.withdraw(yang, trove_id, yang_amt);
                self
                    .emit(
                        LeverWithdraw {
                            user: caller, trove_id, yang, yang_amt, asset_amt: yang_asset_amt
                        }
                    );

                // Swap collateral for exact amount of flash minted CASH
                yang_erc20.transfer(router.contract_address, yang_asset_amt.into());

                // Since we want an exact output of the flash minted amount of CASH, we construct
                // the route in reverse, and specify the amount of CASH we want as output by setting
                // the sign of the mag to true.
                // (see
                // https://github.com/EkuboProtocol/abis/blob/edb6de8c9baf515f1053bbab3d86825d54a63bc3/src/router_lite.cairo#L32C12-L32C13)

                let route: Array<RouteNode> = array![
                    self.construct_route_node(usdc, token), self.construct_route_node(yang, usdc)
                ];
                router
                    .multihop_swap(
                        route,
                        TokenAmount {
                            token, amount: i129 { mag: amount.try_into().unwrap(), sign: true }
                        }
                    );

                // Sanity check to ensure the amount of CASH flash minted has been purchased
                // and can be withdrawn
                router_clear.clear_minimum(cash, amount);
                router_clear.clear_minimum_to_recipient(yang_erc20, 1, caller);
            }

            ON_FLASH_MINT_SUCCESS
        }
    }

    #[generate_trait]
    impl LeverHelpers of LeverHelpersTrait {
        // Constructs the route for swapping the flash minted amount for collateral.
        // To simplify, the swaps will default to the 0.05% pool fee / 1% tick spacing pools
        // for these pairs.
        fn construct_route_node(
            self: @ContractState, token_to_sell: ContractAddress, token_to_buy: ContractAddress
        ) -> RouteNode {
            let (token0, token1) = if token_to_sell < token_to_buy {
                (token_to_sell, token_to_buy)
            } else {
                (token_to_buy, token_to_sell)
            };

            let pool_key = PoolKey {
                token0, token1, fee: POOL_FEE, tick_spacing: TICK_SPACING, extension: Zero::zero(),
            };

            // Note that the `quote` function on the Router currently reverts, and Starknet does not
            // support catching reverts at the moment. Hence, we need to call Core for the pool
            // price.
            // https://discord.com/channels/1119209474369003600/1119212138955821127/1239574394221625424
            let pool_price = self.ekubo_core.read().get_pool_price(pool_key);

            // Simple heuristic to ensure the swap succeeds
            let sqrt_ratio_limit = if token0 == token_to_sell {
                pool_price.sqrt_ratio / 2
            } else {
                pool_price.sqrt_ratio * 2
            };

            RouteNode { pool_key, sqrt_ratio_limit, skip_ahead: 0 }
        }
    }
}
