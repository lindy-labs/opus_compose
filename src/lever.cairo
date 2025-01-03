#[starknet::contract]
pub mod lever {
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::router_lite::{IRouterLiteDispatcher, IRouterLiteDispatcherTrait,};
    use opus::interfaces::{
        IAbbotDispatcher, IAbbotDispatcherTrait, IFlashBorrower, IFlashMintDispatcher,
        IFlashMintDispatcherTrait, ISentinelDispatcher, ISentinelDispatcherTrait, IShrineDispatcher,
        IShrineDispatcherTrait
    };
    use opus_lever::interface::ILever;
    use opus_lever::types::{LeverDownParams, LeverUpParams, ModifyLeverAction, ModifyLeverParams};
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


    //
    // Storage
    //

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        flash_mint: IFlashMintDispatcher,
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
        ekubo_router: ContractAddress
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.flash_mint.write(IFlashMintDispatcher { contract_address: flash_mint });
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
        fn up(ref self: ContractState, amount: Wad, lever_up_params: LeverUpParams) {
            let caller: ContractAddress = get_caller_address();
            assert(
                caller == self
                    .abbot
                    .read()
                    .get_trove_owner(lever_up_params.trove_id)
                    .expect('Non-existent trove'),
                'LEV: Not trove owner'
            );

            // Calldata:
            // - Whether the action is taking on leverage or not (i.e. unwinding)
            // - User calling this function, who is also the trove owner
            // - Trove ID
            // - Address of collateral asset
            // - Maximum forge fee pct for user
            let mut call_data: Array<felt252> = array![];
            let modify_lever_params = ModifyLeverParams {
                caller, action: ModifyLeverAction::LeverUp(lever_up_params)
            };
            modify_lever_params.serialize(ref call_data);

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
        fn down(ref self: ContractState, amount: Wad, lever_down_params: LeverDownParams) {
            let caller: ContractAddress = get_caller_address();
            assert(
                caller == self
                    .abbot
                    .read()
                    .get_trove_owner(lever_down_params.trove_id)
                    .expect('Non-existent trove'),
                'LEV: Not trove owner'
            );

            // Calldata:
            // - Whether the action is taking on leverage or not (i.e. unwinding)
            // - User calling this function, who is also the trove owner
            // - Trove ID
            // - Address of collateral asset
            // - Amount of collateral's yang to withdraw
            let modify_lever_params = ModifyLeverParams {
                caller, action: ModifyLeverAction::LeverDown(lever_down_params)
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
            let lever_params: ModifyLeverParams = Serde::<
                ModifyLeverParams
            >::deserialize(ref call_data)
                .unwrap();

            let shrine = self.shrine.read();
            let cash = IERC20Dispatcher { contract_address: shrine.contract_address };
            let sentinel = self.sentinel.read();
            let router = self.ekubo_router.read();
            let router_clear = IClearDispatcher { contract_address: router.contract_address };

            match lever_params.action {
                ModifyLeverAction::LeverUp(params) => {
                    let yang_erc20 = IERC20Dispatcher { contract_address: params.yang };

                    cash.transfer(router.contract_address, amount);
                    router.multi_multihop_swap(params.swaps);
                    // Sanity check to ensure the collateral asset has been purchased and can be
                    // withdrawn
                    let yang_asset_amt: u256 = router_clear.clear_minimum(yang_erc20, 1);

                    // Deposit collateral asset to trove
                    yang_erc20.approve(sentinel.get_gate_address(params.yang), yang_asset_amt);

                    let yang_amt: Wad = sentinel
                        .enter(
                            params.yang, get_contract_address(), yang_asset_amt.try_into().unwrap()
                        );
                    shrine.deposit(params.yang, params.trove_id, yang_amt);

                    self
                        .emit(
                            LeverDeposit {
                                user: lever_params.caller,
                                trove_id: params.trove_id,
                                yang: params.yang,
                                yang_amt,
                                asset_amt: yang_asset_amt.try_into().unwrap()
                            }
                        );

                    // Borrow CASH from trove and send to this contract to repay the flash mint
                    shrine
                        .forge(
                            initiator,
                            params.trove_id,
                            amount.try_into().unwrap(),
                            params.max_forge_fee_pct
                        );
                },
                ModifyLeverAction::LeverDown(params) => {
                    let yang_erc20 = IERC20Dispatcher { contract_address: params.yang };

                    // Use the flash minted CASH to repay the trove's debt
                    self.abbot.read().melt(params.trove_id, amount.try_into().unwrap());

                    // Withdraw collateral to this contract
                    let yang_asset_amt: u128 = sentinel
                        .exit(params.yang, initiator, params.yang_amt);
                    shrine.withdraw(params.yang, params.trove_id, params.yang_amt);
                    self
                        .emit(
                            LeverWithdraw {
                                user: lever_params.caller,
                                trove_id: params.trove_id,
                                yang: params.yang,
                                yang_amt: params.yang_amt,
                                asset_amt: yang_asset_amt
                            }
                        );

                    // Swap collateral for exact amount of flash minted CASH
                    yang_erc20.transfer(router.contract_address, yang_asset_amt.into());

                    router.multi_multihop_swap(params.swaps);

                    // Sanity check to ensure the amount of CASH flash minted has been purchased
                    // and can be withdrawn
                    router_clear.clear_minimum(cash, amount);
                    let cash_amount = cash.balanceOf(get_contract_address());

                    // Transfer any excess CASH back to the caller.
                    if cash_amount > amount {
                        cash.transfer(lever_params.caller, cash_amount - amount);
                    }
                    router_clear.clear_minimum_to_recipient(yang_erc20, 1, lever_params.caller);
                },
            };

            ON_FLASH_MINT_SUCCESS
        }
    }
    // #[generate_trait]
// impl LeverHelpers of LeverHelpersTrait {}
}

