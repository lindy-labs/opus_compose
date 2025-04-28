use opus_compose::addresses::mainnet;
use opus_compose::stabilizer::constants::{BOUNDS, POOL_KEY};
use sncast_std::{
    DeclareResultTrait, DisplayContractAddress, EthFeeSettings, FeeSettings, declare, deploy,
};

fn main() {
    let declare_stabilizer = declare(
        "stabilizer", FeeSettings::Eth(EthFeeSettings { max_fee: Option::None }), Option::None,
    )
        .expect('failed stabilizer declare');

    let mut stabilizer_calldata: Array<felt252> = array![
        mainnet::SHRINE.into(),
        mainnet::EQUALIZER.into(),
        mainnet::EKUBO_POSITIONS.into(),
        mainnet::EKUBO_POSITIONS_NFT.into(),
    ];
    POOL_KEY().serialize(ref stabilizer_calldata);
    BOUNDS().serialize(ref stabilizer_calldata);

    let deploy_stabilizer = deploy(
        *declare_stabilizer.class_hash(),
        stabilizer_calldata,
        Option::None,
        true,
        FeeSettings::Eth(EthFeeSettings { max_fee: Option::None }),
        Option::None,
    )
        .expect('failed stabilizer deploy');
    let stabilizer_addr = deploy_stabilizer.contract_address;

    // Print summary table of deployed contracts
    println!("-------------------------------------------------\n");
    println!("Deployed addresses");
    println!("Stabilizer: {}", stabilizer_addr);
}
