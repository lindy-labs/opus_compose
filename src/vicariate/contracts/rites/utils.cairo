pub mod rites_utils {
    use starknet::ContractAddress;

    pub fn assert_caller_is_prior(
        caller: ContractAddress, prior: ContractAddress, rite_id: ByteArray,
    ) {
        assert!(caller == prior, "{}: Caller is not Prior", rite_id);
    }
}
