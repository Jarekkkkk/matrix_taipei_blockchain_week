#[test_only]
module test::setup{
    use sui::math;
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, CoinMetadata};
    use std::vector as vec;
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};

    use test::mock_nft::{Self, NFT};
    use test::mock_usdc::{Self, MOCK_USDC as USDC};
    use test::mock_usdt::{Self, MOCK_USDT as USDT};
    use test::mock_eth::{Self, MOCK_ETH as ETH};

    use protocol::pool_factory::{Self, PoolReg};

    // 6 decimals
    public fun usdc_1(): u64 { math::pow(10, 6) }
    public fun usdc_100K(): u64 { math::pow(10, 11) }
    public fun usdc_1M(): u64 { math::pow(10, 12) }
    public fun usdc_100M(): u64 { math::pow(10, 14)}
    public fun usdc_1B(): u64 { math::pow(10, 15) }
    public fun usdc_10B(): u64 { math::pow(10, 16) }
    // 9 decimals, max coin supply: 18.44B
    public fun sui_1(): u64 { math::pow(10, 9) }
    public fun sui_100K(): u64 { math::pow(10, 14) }
    public fun sui_1M(): u64 { math::pow(10, 15) }
    public fun sui_100M(): u64 { math::pow(10, 17) }
    public fun sui_1B(): u64 { math::pow(10, 18) }
    public fun sui_10B(): u64 { math::pow(10, 19) }
    // time utility
    public fun start_time(): u64 { 1672531200 }
    public fun month(): u64 { 30 * 86400 }
    public fun week(): u64 { 7 * 86400 }
    public fun day(): u64 { 86400 }
    public fun hours(): u64 { 3600 }
    public fun minutes(): u64 { 60 }
    // address
    public fun people(): (address, address, address) { (@0x000A, @0x000B, @0x000C ) }
    // Fenwick index [3696, 460] ->
    public fun i9_91_(): u64 { 3696 }
    public fun i9_81_(): u64 { 3698 }
    public fun i9_72_(): u64 { 3700 }
    public fun i9_62_(): u64 { 3702 }
    public fun i9_52_(): u64 { 3704 }


    public fun deploy_contract(clock: &mut Clock, s: &mut Scenario){
        clock::set_for_testing(clock, 1699358076_000);
        sui::tx_context::increment_epoch_timestamp(ctx(s), 1699358076_000);
        clock::set_for_testing(clock, 1699358076_000);
        deploy_coins(s);
        deploy_pool_factory(s);
    }

    fun deploy_coins(s: &mut Scenario){
        // init currency
        mock_usdc::deploy_coin(ctx(s));
        mock_usdt::deploy_coin(ctx(s));
        mock_eth::deploy_coin(ctx(s));
        // init nft
        mock_nft::deploy_nft(ctx(s));
        // mint
        let (a, b, c) = people();
        let owners = vec::singleton(a);
        vec::push_back(&mut owners, b);
        vec::push_back(&mut owners, c);

        let ctx = ctx(s);
        let (i, len) = (0, vec::length(&owners));
        while( i < len ){
            let owner = vec::pop_back(&mut owners);
            let usdc = coin::mint_for_testing<USDC>(usdc_100K(), ctx);
            let usdt = coin::mint_for_testing<USDT>(usdc_100K(), ctx);
            let eth = coin::mint_for_testing<ETH>(sui_100K(), ctx);

            transfer::public_transfer(usdc, owner);
            transfer::public_transfer(usdt, owner);
            transfer::public_transfer(eth, owner);

            i = i + 1;
        };
    }

    fun deploy_pool_factory(s: &mut Scenario){
        let (a, _, _) = people();

        pool_factory::init_for_testing(ctx(s));
        next_tx(s, a);{ // Create Pool
            let pool_reg = test::take_shared<PoolReg>(s);
            let meta_usdc = test::take_immutable<CoinMetadata<USDC>>(s);
            let meta_usdt = test::take_immutable<CoinMetadata<USDT>>(s);
            let meta_eth = test::take_immutable<CoinMetadata<ETH>>(s);

            // token pools
            // rate: 0.01
            pool_factory::create_token_pool(&mut pool_reg, &meta_usdc, &meta_usdt, 10_000_000_000_000_000, ctx(s));
            // rate: 0.1
            pool_factory::create_token_pool(&mut pool_reg, &meta_usdc, &meta_eth, 100_000_000_000_000_000, ctx(s));
            // nft pool
            // rate: 0.05
            pool_factory::create_nft_pool<USDC, NFT>(&mut pool_reg, &meta_usdc, 50_000_000_000_000_000, ctx(s));

            test::return_immutable(meta_usdc);
            test::return_immutable(meta_usdt);
            test::return_immutable(meta_eth);
            test::return_shared(pool_reg);
        };
    }
}