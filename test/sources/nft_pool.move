#[test_only]
module test::nft_pool{
    use std::string;
    use std::vector as vec;
    use sui::clock::{Self, Clock, increment_for_testing as add_time, timestamp_ms as get_time};
    use sui::coin::{ Coin, mint_for_testing as mint, burn_for_testing as burn};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::math;
    use sui::table;

    use math::wad;

    use test::setup;
    use test::mock_usdc::{MOCK_USDC as USDC};
    use test::mock_nft::{Self as nft, NFT};

    use protocol::pool_factory::{Self, PoolReg};
    use protocol::pool::{Self, Pool};
    use protocol::position::{Self, Position};

    use protocol::constants;
    use protocol::time;
    use protocol::bucket;
    use protocol::ema;

    use test::utils;

    const UNIT: u256 = 1_000_000_000_000_000_000;

    #[test]fun nft_pool(){
        let (a,_,_) = setup::people();
        let s = test::begin(a);
        // setup
        let clock = clock::create_for_testing(ctx(&mut s));
        setup::deploy_contract(&mut clock, &mut s);
        // pool
        deploy_pools(&mut s);
        // lender actions
        add_quote_tokens(&mut clock, &mut s);
        // borrower
        pledge_collateral(&mut clock, &mut s);
        kick(&mut clock, &mut s);
        bucket_take(&mut clock, &mut s);

        clock::destroy_for_testing(clock);
        test::end(s);
    }

    fun deploy_pools(s: &mut Scenario){
        let (a, _, _) = setup::people();
        next_tx(s,a);{
            let pool_reg = test::take_shared<PoolReg>(s);
            assert!(pool_factory::pools_length(&pool_reg) == 3, 404);
            {
                let pool = test::take_shared<Pool<USDC, NFT>>(s);
                assert!(pool::name(&pool) == string::utf8(b"USDC-NFT"), 404);
                assert!(!pool::pool_type(&pool), 404);
                assert!(pool::quote_scale(&pool) == (math::pow(10, 12) as u256), 404);
                assert!(pool::collateral_scale(&pool) == 1, 404);
                assert!(pool::interest_rate(&pool) == 50_000_000_000_000_000, 404);
                //assert!(vec::length(pool::deposit_values(&pool)) == 8193 ,404);
                //assert!(vec::length(pool::deposit_scaling(&pool)) == 8193 ,404);

                test::return_shared(pool);
            };
            test::return_shared(pool_reg);
        }
    }

    fun add_quote_tokens(clock: &mut Clock, s: &mut Scenario){
        let (a, _, _) = setup::people();

        next_tx(s,a);{ // Lender A deposit (2000) USDC at (9.91)
            {
                let pool = test::take_shared<Pool<USDC, NFT>>(s);

                let position = pool::open_position(&pool, ctx(s));
                let lp = pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_(), mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
                assert!(lp == 2000 * UNIT, 404);
                position::transfer(position, a);

                test::return_shared(pool);
            };
        };

        add_time(clock, 13 * setup::hours() * 1000);

        next_tx(s,a);{
            let pool = test::take_shared<Pool<USDC, NFT>>(s);
            let position = test::take_from_sender<Position>(s);
            let deposit = 2_000_u256;

            // [Assert]
            assert!(pool::quote_balance(&pool) == (deposit as u64) * math::pow(10,6), 404);
            // interest_rate isn't changed as we haven't passed 12 hours yet
            assert!(pool::interest_rate(&pool) == 0_050000000000000000, 404);
            assert!(pool::meaningful_deposit(&pool) == deposit * UNIT, 404);
            // inflator
            assert!(pool::inflator(&pool) == UNIT, 404);
            // bucket
            assert!(table::length(pool::buckets_borrow(&pool)) == 1, 404);
            assert!(bucket::lps(pool::bucket_at(&pool, setup::i9_91_())) == deposit * UNIT, 404);
            assert!(ema::deposit_ema(pool::ema_state(&pool)) == deposit * UNIT, 404);
            // Fenwick Tree
            assert!(pool::deposit_size(&pool) == deposit * UNIT, 404);

            // [ACTION]- Lender A deposit (2000) NFT at (9.86)
            let lp = pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_() + 1, mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
            assert!(lp == 2_000 * UNIT, 404);

            test::return_shared(pool);
            test::return_to_sender(s, position);
        };

        add_time(clock, 13 * setup::hours() * 1000);

        next_tx(s,a);{ // Lender A deposit 2000 NFT respectively at price(9.72, 9.62, 9.52)
            let pool = test::take_shared<Pool<USDC, NFT>>(s);
            let position = test::take_from_sender<Position>(s);

            // [ASSERT]
            assert!(pool::meaningful_deposit(&pool) == 4_000 * UNIT, 404);
            assert!(pool::deposit_size(&pool) == 4_000 * UNIT, 404);
            // MAU < TU; calculate rate by multipling current rate by 0.9
            assert!(pool::interest_rate(&pool) == 0_045000000000000000, 404);

            // [ACTION]
            let lp = pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_() + 2, mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
            assert!(lp == 2_000 * UNIT, 404);
            let lp = pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_() + 3, mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
            assert!(lp == 2_000 * UNIT, 404);
            let lp = pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_() + 4, mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
            assert!(lp == 2_000 * UNIT, 404);

            // [Assert]
            // common
            assert!(pool::meaningful_deposit(&pool) == 2_000 * 5 * UNIT, 404);
            assert!(pool::interest_rate(&pool) == 0_040500000000000000, 404);
            assert!(pool::get_Lup(&pool) == protocol::constants::max_price(), 404);
            assert!(pool::get_Htp(&pool) == 0, 404);
            assert!(pool::deposit_size(&pool) == 2_000 * 5 * UNIT, 404);

            test::return_shared(pool);
            test::return_to_sender(s, position);
        };
    }

    fun pledge_collateral(clock: &mut Clock, s: &mut Scenario){
        let (_, b, _) = setup::people();

        next_tx(s,b);{
            let pool = test::take_shared<Pool<USDC, NFT>>(s);

            // LUP stay at price 9.62 index of 3702
            pool::draw_debt_nft<USDC, NFT>(&mut pool, 9_620000, setup::i9_62_(), vector[nft::new(ctx(s))],clock, ctx(s));

            // [ASSERT]
            // common
            assert!(pool::get_Lup(&pool) == 9_917184843435912074, 404);
            assert!(pool::get_Htp(&pool) == 9_627492500000000001, 404);
            assert!(pool::get_Mau(&pool) == 0, 404); // debt in latest action didn't count, therefore we got MAU at 0 and TU at 1
            assert!(pool::get_Tu(&pool) == 1000000000000000000, 404);
            assert!(pool::collateral_balance(&pool) == 0, 404);
            assert!(pool::quote_balance(&pool) == ( 10000_000000 - 9_620000 ), 404);
            assert!(pool::deposit_size(&pool) == 10_000 * UNIT, 404);
            // pool_balance_state
            assert!(pool::pledged_collateral(&pool) == 1000000000000000000, 404);
            assert!(pool::t0_debt(&pool) == 9_627492500000000001, 404);
            // interest state
            assert!(pool::interest_rate(&pool) == 0_040500000000000000, 404);
            assert!(pool::debt(&pool) == 9627492500000000001, 404);
            assert!(pool::meaningful_deposit(&pool) == 10_000 * UNIT, 404);
            assert!(pool::t0_debt2_to_collateral(&pool) == 92688611837556250019, 404);
            assert!(pool::debt_col(&pool) == 92688611837556250019, 404); // t0_debt2_to_collateral * inflator
            assert!(pool::lup_t0_debt(&pool) == 95477622701292917733, 404); // lup * non_auctioned_t0_debt
            // borrower (Loans)
            assert!(pool::borrower_t0_debt(&pool, b) == 9_627492500000000001, 404);
            assert!(pool::borrower_collateral(&pool, b) == 1* UNIT, 404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1140623058987490536, 404);
            assert!(pool::borrower_indices(&pool, b) == 1, 404);
            assert!(pool::borrower_collateralization(&pool, b, clock) == 1030090113644431514, 404);
            // loans ( Heap Tree)
            assert!(vec::length(pool::loans(&pool)) == 2, 404);

            test::return_shared(pool);
        };

        next_tx(s,b);{
            assert!(burn(test::take_from_sender<Coin<USDC>>(s)) == 9_620000, 404);
        };

        add_time(clock, setup::hours() * 1000);

        next_tx(s, b);{
            let pool = test::take_shared<Pool<USDC, NFT>>(s);
             // [Action] borrow half of liquidity of pool
            let (lup_index, required) = utils::cal_desired_collateral_amount(&pool, 55_000000, 1_010_000_000_000_000_000, 0, clock);
            // deducted the last time's borrow
            assert!(required == 6, 404);

            let nfts = vector<NFT>[];
            let i = 0;
            while( i < required){
                vec::push_back(&mut nfts, nft::new(ctx(s)));
                i = i + 1;
            };

            pool::draw_debt_nft<USDC, NFT>(&mut pool, 59_600000, lup_index, nfts, clock, ctx(s));

            // [ASSERT]
            // Borrower
            assert!(pool::borrower_t0_debt(&pool, b) == 69_273635968852031911, 404);
            assert!(pool::borrower_collateral(&pool, b) == 7_000000000000000000, 404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1_140623058987490536, 404);
            assert!(pool::borrower_indices(&pool, b) == 1, 404);
            assert!(pool::borrower_collateralization(&pool, b, clock) == 1_002112448464782939, 404);
            // common
            assert!(pool::get_Lup(&pool) == 9_917184843435912074, 404);
            assert!(pool::get_Htp(&pool) == 9_896279463077071981, 404);
            assert!(pool::get_Mau(&pool) == 0_0156811464813531, 404);
            assert!(pool::get_Tu(&pool) == 0_970788853085898000, 404);
            assert!(pool::collateral_balance(&pool) == 0, 404);
            assert!(pool::quote_balance(&pool) == 9930780000, 404);
            assert!(pool::deposit_size(&pool) == 10_000 * UNIT, 404);
            // inflator
            assert!(pool::inflator(&pool) == 1_000004623298358642, 404);
            // pool_balance_state
            assert!(pool::pledged_collateral(&pool) == 7_000000000000000000, 404);
            assert!(pool::t0_debt(&pool) == 69_273635968852031911, 404);
            // interest state
            assert!(pool::interest_rate(&pool) == 0_040500000000000000, 404);
            assert!(pool::debt(&pool) == 69_273956241539503868, 404);
            assert!(pool::meaningful_deposit(&pool) == 2000_000007566830946000, 404); // take account for scaling
            assert!(pool::t0_debt2_to_collateral(&pool) == 685548091477861427699, 404);
            assert!(pool::debt_col(&pool) == 685551260971227527451, 404);
            assert!(pool::lup_t0_debt(&pool) == 686999452679996205306, 404);
            // Reserve Auction
            assert!(pool::total_interest_earned(&pool) == 37834154732125, 404);
            // loans
            assert!(vec::length(pool::loans(&pool)) == 2, 404);

            test::return_shared(pool);
        };

        next_tx(s,b);{
            assert!(burn(test::take_from_sender<Coin<USDC>>(s)) == 59_600000, 404);
        };
    }

    fun kick(clock: &mut Clock, s: &mut Scenario){
        let (_, b, c) = setup::people();

        add_time(clock, setup::month() * 1000);

        next_tx(s,b);{
            let pool = test::take_shared<Pool<USDC,NFT>>(s);

            // under collateralization
            assert!(pool::borrower_collateralization(&pool, b, clock) < wad::wad(1), 404);

            test::return_shared(pool);
        };

        next_tx(s,c);{
            let pool = test::take_shared<Pool<USDC,NFT>>(s);
            let (_, size) = pool::bond_params(&pool, b, clock);
            let value = size / pool::quote_scale(&pool) + 1;

            pool::kick(&mut pool, b, constants::max_fenwick_index(), mint((value as u64), ctx(s)), clock, ctx(s));

            // [Assert]
            // 0. borrower
            assert!(pool::borrower_t0_debt(&pool, b) == 69_273635968852031911, 404);
            assert!(pool::borrower_indices(&pool, b) == 0, 404); //remove borrower's indice
            assert!(pool::borrower_collateral(&pool, b) == 7_000000000000000000,404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1_140623058987490536, 404);
            // 1. reserve
            assert!(pool::collateral_balance(&pool) == 0, 404);
            assert!(pool::quote_balance(&pool) == 9931_757400, 404);
            // 2. intere_state
            assert!(pool::interest_rate(&pool) == 0_036450000000000000, 404);
            assert!(pool::debt(&pool) == 0, 404); // all the debt has been moved to auction
            assert!(pool::meaningful_deposit(&pool) == 9930_495062662570338704, 404); // all deposit deducted by 'debt_in_auction'
            // 3. pool_balance.t0_debt_in_auction
            assert!(pool::pledged_collateral(&pool) == 7_000000000000000000, 404);
            assert!(pool::t0_debt_in_auction(&pool) == 69_273635968852031911, 404);
            assert!(pool::t0_debt(&pool) == 69_273635968852031911, 404);
            // 4. Auction
            assert!(pool::num_of_auctions(&pool) == 1, 404);
            assert!(pool::head(&pool) == b, 404);
            assert!(pool::tail(&pool) == b, 404);
            assert!(pool::total_bond_escrowed(&pool) == 0_977399690312320424, 404);
            // 5. liquidation
            assert!(pool::liquidation_kicker(&pool, b) == c, 404);
            assert!(pool::liquidation_bond_factor(&pool, b) == 0_014062305898749053, 404);
            assert!(pool::liquidation_kick_time(&pool, b) == time::get_sec(clock), 404);
            assert!(pool::liquidation_prev(&pool, b) == @0x00, 404);
            assert!(pool::liquidation_reference_price(&pool, b) == 11_325562034364695136, 404);
            assert!(pool::liquidation_next(&pool, b) == @0x00, 404);
            assert!(pool::liquidation_bond_size(&pool, b) == 0_977399690312320424, 404);
            assert!(pool::liquidation_neutral_price(&pool, b) == 11_325562034364695136, 404);
            // 6. kicker
            assert!(pool::kicker_claimable(&pool, c) == 0, 404);
            assert!(pool::kicker_locked(&pool, c) == 0_977399690312320424, 404); // equals to bond_size
            // 7. Bucket
            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 2000_196343309456450000, 404);
            assert!(lp_bal == 2000_000000000000000000, 404);
            assert!(collateral_balance == 0, 404);
            assert!(rate == 1_000098171654728225, 404);

            test::return_shared(pool);
        };
    }

    fun bucket_take(clock: &mut Clock, s: &mut Scenario){
        let (a, b, c) = setup::people();

        // auction price back to neutral price after 6 hours
        add_time(clock, 7 * setup::hours() * 1000);

        next_tx(s, a);{
            let pool = test::take_shared<Pool<USDC,NFT>>(s);
            let position = test::take_from_sender<Position>(s);

            // current auction price

            assert!(pool::liquidation_auction_price(&pool, b, clock) == 8008381715248186512, 404);

            // [Action] lender use the deposit in bucket to take
            pool::bucket_take(&mut pool, &mut position, b, true, setup::i9_91_(), clock, ctx(s));

            // [Assertion]
            // Pools
            assert!(pool::pledged_collateral(&pool) == 0, 404);
            assert!(pool::t0_debt_in_auction(&pool) == 1059309380435928751, 404);
            assert!(pool::t0_debt(&pool) == 1059309380435928751, 404);
            // Lender
            let (lp_bal, deposit_time) = pool::lender_info(&pool, &position, setup::i9_91_());
            assert!(lp_bal == 2000_000000000000000000, 404);
            assert!(deposit_time == 1699358076, 404);
            let (lp_bal, deposit_time) = pool::kicker_lender(&pool, c, setup::i9_91_());
            assert!(lp_bal == 0_976113413460990503, 404);
            assert!(deposit_time == 1702072476, 404);
            // Bucket
            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 1931_752603711988424192, 404);
            assert!(lp_bal == 2000_976113413460990503, 404);
            assert!(collateral_balance == 7_000000000000000000, 404);
            assert!(rate == 1_000098344103789988, 404);
            // Kicker
            assert!(pool::kicker_claimable(&pool, c) == 0, 404);
            assert!(pool::kicker_locked(&pool, c) == 0_977399690312320424, 404);
            // Borrower
            assert!(pool::borrower_t0_debt(&pool, b) == 1_059309380435928751, 404);
            assert!(pool::borrower_indices(&pool, b) == 0, 404);
            assert!(pool::borrower_collateral(&pool, b) == 0,404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1_140623058987490536, 404);
            // Auction
            assert!(pool::num_of_auctions(&pool) == 1, 404);
            assert!(pool::head(&pool) == b, 404);
            assert!(pool::tail(&pool) == b, 404);
            assert!(pool::total_bond_escrowed(&pool) == 0_977399690312320424, 404);

            test::return_shared(pool);
            test::return_to_sender(s, position);
        };

        next_tx(s,a);{
            let pool = test::take_shared<Pool<USDC,NFT>>(s);

            pool::settle(&mut pool, b, 5, clock, ctx(s));

            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 1930_976678585711738054, 404); // use deposit in bucket to pay the default debt
            assert!(lp_bal == 2000_976113413460990503, 404);
            assert!(collateral_balance == 7_000000000000000000, 404);
            assert!(rate == 0_999710570796015195, 404);
            // Kicker
            assert!(pool::kicker_claimable(&pool, c) == 0_977399690312320424, 404);
            assert!(pool::kicker_locked(&pool, c) == 0, 404);
            // Borrower
            assert!(pool::borrower_t0_debt(&pool, b) == 0, 404);
            assert!(pool::borrower_indices(&pool, b) == 0, 404);
            assert!(pool::borrower_collateral(&pool, b) == 0,404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1140623058987490536, 404);
            // Auction
            assert!(pool::num_of_auctions(&pool) == 0, 404);
            assert!(pool::head(&pool) == @0x00, 404);
            assert!(pool::tail(&pool) == @0x00, 404);
            assert!(pool::total_bond_escrowed(&pool) == 0_977399690312320424, 404);

            test::return_shared(pool);
        };

        add_time(clock, setup::day() * 1000);

        next_tx(s,c);{ // add collateral
            let pool = test::take_shared<Pool<USDC, NFT>>(s);
            let position = pool::open_position(&pool, ctx(s));
            // exist claimable collateral
            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_91_());

            assert!(lp_bal == 2000_976113413460990503, 404);
            assert!(collateral_balance == 7_000000000000000000, 404);
            assert!(rate == 0_999710570796015195, 404);

            let nft = vector[nft::new(ctx(s)), nft::new(ctx(s)), nft::new(ctx(s)), nft::new(ctx(s)), nft::new(ctx(s))];
            pool::add_collateral_nft(&mut pool, &mut position, nft, setup::i9_91_(), time::get_sec(clock) + 1000, clock);

            assert!(pool::position_lps(&position, setup::i9_91_()) == 49_600279986733544139,404);

            let (_, cur_deposit, lp_bal, collateral_balance, _, _, _) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 1930_976678585711738054, 404);
            assert!(lp_bal == 2050_576393400194534642, 404);
            assert!(collateral_balance == 12_000000000000000000, 404);

            position::transfer(position, c);
            test::return_shared(pool);
        };

        add_time(clock, setup::day() * 1000);
        next_tx(s,c);{ // remove collateral
            let pool = test::take_shared<Pool<USDC, NFT>>(s);
            let position = test::take_from_sender<Position>(s);

            pool::remove_collateral_nft(&mut pool, &mut position, 5, setup::i9_91_(), clock, ctx(s));

            // position
            assert!(pool::position_lps(&position, setup::i9_91_()) == 0, 404);
            // bucket
            let (_, cur_deposit, lp_bal, collateral_balance, _, _, _) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 1930_976678585711738054, 404);
            assert!(lp_bal == 2000_976113413460990503, 404);
            assert!(collateral_balance == 7_000000000000000000, 404);

            test::return_to_sender(s,position);
            test::return_shared(pool);
        };

        add_time(clock, setup::day() * 1000);
        next_tx(s,c);{ // add collateral
            let pool = test::take_shared<Pool<USDC, NFT>>(s);
            let position = pool::open_position(&pool, ctx(s));

            // deposit 1 NFT at i9_91
            pool::add_collateral_nft(&mut pool, &mut position, vector[nft::new(ctx(s))], setup::i9_91_(), time::get_sec(clock) + 1000, clock);
            // deposit 2 NFT at i9_91 + 1
            pool::add_collateral_nft(&mut pool, &mut position, vector[nft::new(ctx(s)), nft::new(ctx(s))], setup::i9_91_() + 1, time::get_sec(clock) + 1000, clock);
            // deposit 3 NFT at i9_91 + 2
            pool::add_collateral_nft(&mut pool, &mut position, vector[nft::new(ctx(s)), nft::new(ctx(s)), nft::new(ctx(s))], setup::i9_91_() + 2, time::get_sec(clock) + 1000, clock);

            position::transfer(position, c);
            test::return_shared(pool);
        };

        add_time(clock, setup::day() * 1000);
        next_tx(s,c);{
            let pool = test::take_shared<Pool<USDC, NFT>>(s);
            let position = test::take_from_sender<Position>(s);

            pool::merge_or_remove_collateral(&mut pool, &mut position, vector[setup::i9_91_(), setup::i9_91_() + 1, setup::i9_91_() + 2], setup::i9_91_() + 3, 6, clock, ctx(s));

            test::return_to_sender(s,position);
            test::return_shared(pool);
        };
    }
}