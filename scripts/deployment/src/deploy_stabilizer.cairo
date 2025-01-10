use opus_compose::addresses::mainnet;
use opus_compose::stabilizer::constants::{POOL_KEY, BOUNDS};
use sncast_std::{
    declare, DeclareResultTrait, deploy, FeeSettings, EthFeeSettings, DisplayContractAddress,
};

fn main() {
    let declare_stabilizer = declare(
        "stabilizer", FeeSettings::Eth(EthFeeSettings { max_fee: Option::None }), Option::None,
    )
        .expect('failed stabilizer declare');

    let mut stabilizer_calldata: Array<felt252> = array![
        mainnet::shrine().into(),
        mainnet::equalizer().into(),
        mainnet::ekubo_positions().into(),
        mainnet::ekubo_positions_nft().into(),
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
