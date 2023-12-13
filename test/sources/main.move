#[test_only]
module test::main{
    use std::string;
    use std::vector as vec;
    use sui::clock::{Self, Clock, increment_for_testing as add_time, timestamp_ms as get_time};
    use sui::coin::{ Self, Coin, mint_for_testing as mint, burn_for_testing as burn, CoinMetadata};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::math;
    use sui::table;

    use math::wad;

    use test::setup;
    use test::mock_usdc::{MOCK_USDC as USDC};
    use test::mock_usdt::{MOCK_USDT as USDT};
    use test::mock_eth::{MOCK_ETH as ETH};

    use protocol::pool_factory::{Self, PoolReg};
    use protocol::pool::{Self, Pool};
    use protocol::position::{Self, Position};
    use protocol::ema;
    use protocol::bucket;

    use protocol::constants;
    use protocol::time;

    use test::utils;

    const UNIT: u256 = 1_000_000_000_000_000_000;

    #[test]fun token_pool(){
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
        // deposit take
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
                let pool = test::take_shared<Pool<USDC, USDT>>(s);
                assert!(pool::name(&pool) == string::utf8(b"USDC-USDT"), 404);
                assert!(pool::pool_type(&pool), 404);
                assert!(pool::collateral_scale(&pool) == (math::pow(10, 12) as u256), 404);
                assert!(pool::quote_scale(&pool) == (math::pow(10, 12) as u256), 404);
                assert!(pool::interest_rate(&pool) == 10_000_000_000_000_000,404);
                //assert!(vec::length(pool::deposit_values(&pool)) == 8193 ,404);
                //assert!(vec::length(pool::deposit_scaling(&pool)) == 8193 ,404);

                test::return_shared(pool);
            };
            {
                let pool = test::take_shared<Pool<USDC, ETH>>(s);

                assert!(pool::name(&pool) == string::utf8(b"USDC-ETH"), 404);
                assert!(pool::pool_type(&pool), 404);
                assert!(pool::quote_scale(&pool) == (math::pow(10, 12) as u256), 404);
                assert!(pool::collateral_scale(&pool) == (math::pow(10, 10) as u256), 404);
                assert!(pool::interest_rate(&pool) == 100_000_000_000_000_000,404);
                //assert!(vec::length(pool::deposit_values(&pool)) == 8193 ,404);
                //assert!(vec::length(pool::deposit_scaling(&pool)) == 8193 ,404);

                test::return_shared(pool);
            };
            test::return_shared(pool_reg);
        }
    }

    fun add_quote_tokens(clock: &mut Clock, s: &mut Scenario){
        let (a, _, _) = setup::people();

        next_tx(s,a);{ // Lender A deposit (2000) USDT at (9.91)
            {
                let pool = test::take_shared<Pool<USDC, USDT>>(s);

                let position = pool::open_position(&pool, ctx(s));
                let lp = pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_(), mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
                assert!(lp == 2000 * UNIT, 404);
                let (lps, deposit_time) = pool::position_info(&position, setup::i9_91_());
                assert!(lps == 2000 * UNIT, 404);
                assert!(deposit_time == time::get_sec(clock), 404);

                position::transfer(position, a);

                test::return_shared(pool);
            };
        };

        add_time(clock, 13 * setup::hours() * 1000);

        next_tx(s,a);{
            let pool = test::take_shared<Pool<USDC, USDT>>(s);
            let position = test::take_from_sender<Position>(s);
            let deposit = 2_000_u256;

            // [Assert]
            assert!(pool::quote_balance(&pool) == (deposit as u64) * math::pow(10,6), 404);
            // interest_rate isn't changed as we haven't passed 12 hours yet
            assert!(pool::interest_rate(&pool) == 0_010000000000000000, 404);
            assert!(pool::meaningful_deposit(&pool) == deposit * UNIT, 404);
            // inflator
            assert!(pool::inflator(&pool) == UNIT, 404);
            // bucket
            assert!(table::length(pool::buckets_borrow(&pool)) == 1, 404);
            assert!(bucket::lps(pool::bucket_at(&pool, setup::i9_91_())) == deposit * UNIT, 404);
            assert!(ema::deposit_ema(pool::ema_state(&pool)) == deposit * UNIT, 404);
            // Fenwick Tree
            assert!(pool::deposit_size(&pool) == deposit * UNIT, 404);

            // [ACTION]- Lender A deposit (2000) USDT at (9.86)
            let lp = pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_() + 1, mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
            assert!(lp == 2_000 * UNIT, 404);

            test::return_shared(pool);
            test::return_to_sender(s, position);
        };

        add_time(clock, 13 * setup::hours() * 1000);

        next_tx(s,a);{ // Lender A deposit 2000 USDT respectively at price(9.72, 9.62, 9.52)
            let pool = test::take_shared<Pool<USDC, USDT>>(s);
            let position = test::take_from_sender<Position>(s);

            // [ASSERT]
            assert!(pool::meaningful_deposit(&pool) == 4_000 * UNIT, 404);
            assert!(pool::deposit_size(&pool) == 4_000 * UNIT, 404);
            // MAU < TU; calculate rate by multipling current rate by 0.9
            assert!(pool::interest_rate(&pool) == 0_009000000000000000, 404);

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
            assert!(pool::interest_rate(&pool) == 8_100_000_000_000_000, 404);
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
            let pool = test::take_shared<Pool<USDC, USDT>>(s);

            // LUP stay at price 9.62 index of 3702
            pool::draw_debt(&mut pool, 962 * math::pow(10,6), setup::i9_62_(), mint<USDT>(100 * math::pow(10, 6), ctx(s)),clock, ctx(s));

            // [ASSERT]
            // common
            assert!(pool::get_Htp(&pool) == 9_624810000000000000, 404);
            assert!(pool::get_Mau(&pool) == 0, 404); // debt in latest action didn't count, therefore we got MAU at 0 and TU at 1
            assert!(pool::get_Tu(&pool) == 1000000000000000000, 404);
            assert!(pool::collateral_balance(&pool) == 100 * math::pow(10,6), 404);
            assert!(pool::quote_balance(&pool) == ( 10_000 - 962 ) * math::pow(10,6), 404);
            assert!(pool::deposit_size(&pool) == 10_000 * UNIT, 404);
            // pool_balance_state
            assert!(pool::pledged_collateral(&pool) == 100000000000000000000, 404);
            assert!(pool::t0_debt(&pool) == 962_481000000000000000, 404);
            // interest state
            assert!(pool::interest_rate(&pool) == 8100000000000000, 404);
            assert!(pool::debt(&pool) == 962481000000000000000, 404);
            assert!(pool::meaningful_deposit(&pool) == 10000 * UNIT, 404);
            assert!(pool::t0_debt2_to_collateral(&pool) == 9263696753610000000000, 404);
            assert!(pool::debt_col(&pool) == 9263696753610000000000, 404); // t0_debt2_to_collateral * inflator
            assert!(pool::lup_t0_debt(&pool) == 9545101985295040088896, 404); // lup * non_auctioned_t0_debt
            // borrower (Loans)
            assert!(pool::borrower_t0_debt(&pool, b) == 962481000000000000000, 404);
            assert!(pool::borrower_collateral(&pool, b) == 100 * UNIT, 404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1085000000000000000, 404);
            assert!(pool::borrower_indices(&pool, b) == 1, 404);
            assert!(pool::borrower_collateralization(&pool, b, clock) == 1030377206764176339, 404);
            // loans ( Heap Tree)
            assert!(vec::length(pool::loans(&pool)) == 2, 404);

            test::return_shared(pool);
        };

        next_tx(s,b);{
            assert!(burn(test::take_from_sender<Coin<USDC>>(s)) == 962 * math::pow(10,6), 404);
        };

        add_time(clock, setup::hours() * 1000);

        next_tx(s, b);{
            let pool = test::take_shared<Pool<USDC, USDT>>(s);
            let metadata = test::take_immutable<CoinMetadata<USDT>>(s);

             // [Action] borrow half of liquidity of pool
            let (lup_index, required) = utils::cal_desired_collateral_amount(&pool, 5000_000000, 1_010_000_000_000_000_000, coin::get_decimals(&metadata), clock);
            // deducted the last time's borrow
            assert!(required == 509_217090, 404);

            pool::draw_debt(&mut pool, 5_000 * math::pow(10,6), lup_index, mint<USDT>(required, ctx(s)), clock, ctx(s));

            // [ASSERT]
            // Borrower: debt_0 = 5_000 + 962 + origination fee
            assert!(pool::borrower_t0_debt(&pool, b) == 5964976374402823485905, 404);
            assert!(pool::borrower_collateral(&pool, b) == 609_217090000000000000, 404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1085000000000000000, 404);
            assert!(pool::borrower_indices(&pool, b) == 1, 404);
            assert!(pool::borrower_collateralization(&pool, b, clock) == 1002811331792116331, 404);
            // common
            assert!(pool::get_Lup(&pool) == 9_818751856078723036, 404);
            assert!(pool::get_Htp(&pool) == 9_791225472623756623, 404);
            assert!(pool::get_Mau(&pool) == 0_015676777256922562, 404);
            assert!(pool::get_Tu(&pool) == 0_970518363018167184, 404);
            assert!(pool::collateral_balance(&pool) == 609217090, 404);
            assert!(pool::quote_balance(&pool) == ( 10_000 - (5000 + 962) ) * math::pow(10,6), 404);
            assert!(pool::deposit_size(&pool) == 10_000 * UNIT, 404);
            // inflator
            assert!(pool::inflator(&pool) == 1000000924657961741, 404);
            // pool_balance_state
            assert!(pool::pledged_collateral(&pool) == 609_217090000000000000, 404);
            assert!(pool::t0_debt(&pool) == 5964976374402823485905, 404);
            // interest state
            assert!(pool::interest_rate(&pool) == 0_008100000000000000, 404);
            assert!(pool::debt(&pool) == 5964981889965719674440, 404);
            // !!! IMPORTANT
            assert!(pool::meaningful_deposit(&pool) == 6000_000453882517032000, 404); // take account for scaling
            assert!(pool::t0_debt2_to_collateral(&pool) == 58404374616581837894261, 404);
            assert!(pool::debt_col(&pool) == 58404428620651827620622, 404);
            assert!(pool::lup_t0_debt(&pool) == 58568622847633455043731, 404);
            // Reserve Auction
            assert!(pool::total_interest_earned(&pool) == 756470861723273, 404);
            // loans
            assert!(vec::length(pool::loans(&pool)) == 2, 404);

            test::return_shared(pool);
            test::return_immutable(metadata);
        };

        next_tx(s,b);{
            assert!(burn(test::take_from_sender<Coin<USDC>>(s)) == 5000 * math::pow(10,6), 404);
        };
    }

    fun kick(clock: &mut Clock, s: &mut Scenario){
        let (_, b, c) = setup::people();

        next_tx(s, b);{
            let pool = test::take_shared<Pool<USDC,USDT>>(s);
            let metadata = test::take_immutable<CoinMetadata<USDT>>(s);

             // [Action] borrow half of liquidity of pool
            let (lup_index, required) = utils::cal_desired_collateral_amount(&pool, 5962_000000, 1_005_000_000_000_000_000, coin::get_decimals(&metadata), clock);
            let left_can_borrowed = required - 595_000000;

            pool::draw_debt(&mut pool, left_can_borrowed, lup_index, coin::zero<USDT>(ctx(s)),clock, ctx(s));

            test::return_shared(pool);
            test::return_immutable(metadata);
        };

        add_time(clock, setup::month() * 1000);

        next_tx(s,b);{
            let pool = test::take_shared<Pool<USDC,USDT>>(s);

            // under collateralization
            assert!(pool::borrower_collateralization(&pool, b, clock) < wad::wad(1), 404);

            test::return_shared(pool);
        };

        next_tx(s,c);{
            let pool = test::take_shared<Pool<USDC,USDT>>(s);
            let (_, size) = pool::bond_params(&pool, b, clock);
            let value = size / pool::quote_scale(&pool) + 1;

            pool::kick(&mut pool, b, constants::max_fenwick_index(), mint((value as u64), ctx(s)), clock, ctx(s));

            // [Assert]
            // 0. borrower
            assert!(pool::borrower_t0_debt(&pool, b) == 5980_225496060101735946, 404);
            assert!(pool::borrower_indices(&pool, b) == 0, 404); //remove borrower's indice
            assert!(pool::borrower_collateral(&pool, b) == 609_217090000000000000,404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1085000000000000000, 404);
            // 1. reserve
            assert!(pool::collateral_balance(&pool) == 609217090, 404);
            assert!(pool::quote_balance(&pool) == 4073624302, 404);
            // 2. intere_state
            assert!(pool::interest_rate(&pool) == 0_008910000000000000, 404);
            assert!(pool::debt(&pool) == 0, 404); // all the debt has been moved to auction
            assert!(pool::meaningful_deposit(&pool) == 4015_786289395215235914, 404); // all deposit deducted by 'debt_in_auction'
            // 3. pool_balance.t0_debt_in_auction
            assert!(pool::pledged_collateral(&pool) == 609217090000000000000, 404);
            assert!(pool::t0_debt_in_auction(&pool) == 5980225496060101735946, 404);
            assert!(pool::t0_debt(&pool) == 5980_225496060101735946, 404);
            // 4. Auction
            assert!(pool::num_of_auctions(&pool) == 1, 404);
            assert!(pool::head(&pool) == b, 404);
            assert!(pool::tail(&pool) == b, 404);
            assert!(pool::total_bond_escrowed(&pool) == 50865816540140670495, 404);
            // 5. liquidation
            assert!(pool::liquidation_kicker(&pool, b) == c, 404);
            assert!(pool::liquidation_bond_factor(&pool, b) == 0_008500000000000000, 404);
            assert!(pool::liquidation_kick_time(&pool, b) == time::get_sec(clock), 404);
            assert!(pool::liquidation_prev(&pool, b) == @0x00, 404);
            assert!(pool::liquidation_reference_price(&pool, b) == 10657731016715554498, 404);
            assert!(pool::liquidation_next(&pool, b) == @0x00, 404);
            assert!(pool::liquidation_bond_size(&pool, b) == 50_865816540140670495, 404);
            assert!(pool::liquidation_neutral_price(&pool, b) == 10_657731016715554498, 404);
            // 6. kicker
            assert!(pool::kicker_claimable(&pool, c) == 0, 404);
            assert!(pool::kicker_locked(&pool, c) == 50_865816540140670495, 404); // equals to bond_size

            test::return_shared(pool);
        };
    }

    fun bucket_take(clock: &mut Clock, s: &mut Scenario){
        let (a, b, c) = setup::people();

        // auction price back to neutral price after 6 hours
        add_time(clock, 7 * setup::hours() * 1000);

        next_tx(s, a);{
            let pool = test::take_shared<Pool<USDC,USDT>>(s);
            let position = test::take_from_sender<Position>(s);

            // current auction price
            assert!(pool::liquidation_auction_price(&pool, b, clock) == 7536153873981766268, 404);

            // [Action] lender use the deposit in bucket to take
            // use all 4000 tokens to pay the debt
            pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_(), mint<USDC>(4_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
            pool::bucket_take(&mut pool, &mut position, b, true, setup::i9_91_(), clock, ctx(s));

            // [Assertion]
            // Pools
            assert!(pool::pledged_collateral(&pool) == 0_621136000000000000, 404);
            assert!(pool::t0_debt_in_auction(&pool) == 0, 404);
            assert!(pool::t0_debt(&pool) == 0, 404);
            // Lender
            let (lp_bal, deposit_time) = pool::lender_info(&pool, &position, setup::i9_91_());
            assert!(lp_bal == 5997725378565663187384, 404);
            assert!(deposit_time == 1702072476, 404);
            let (lp_bal, deposit_time) = pool::kicker_lender(&pool, c, setup::i9_91_());
            assert!(lp_bal == 51273074507299893651, 404);
            assert!(deposit_time == 1702072476, 404);
            // Bucket
            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 16_881634889437107835, 404);
            assert!(lp_bal == 6048998453072963081035, 404);
            assert!(collateral_balance == 608595954000000000000, 404);
            assert!(rate == 1000568978919137452, 404);
            // Kicker
            assert!(pool::kicker_claimable(&pool, c) == 50_865816540140670495, 404);
            assert!(pool::kicker_locked(&pool, c) == 0, 404);
            // Borrower
            assert!(pool::borrower_t0_debt(&pool, b) == 0, 404);
            assert!(pool::borrower_indices(&pool, b) == 0, 404);
            assert!(pool::borrower_collateral(&pool, b) == 0_621136000000000000,404);
            assert!(pool::borrower_np_tp_ratio(&pool, b) == 1_087196398167656819, 404);
            // Auction
            assert!(pool::num_of_auctions(&pool) == 0, 404);
            assert!(pool::head(&pool) == @0x00, 404);
            assert!(pool::tail(&pool) == @0x00, 404);
            assert!(pool::total_bond_escrowed(&pool) == 50_865816540140670495, 404);

            test::return_shared(pool);
            test::return_to_sender(s, position);
        };

        next_tx(s,a);{ // Move quote tokens
            let pool = test::take_shared<Pool<USDC,USDT>>(s);
            let position = test::take_from_sender<Position>(s);

            pool::move_quote_coins(&mut pool, &mut position, 2000 * UNIT, setup::i9_91_(), setup::i9_72_(), get_time(clock) + 1000, false, clock, ctx(s));

            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 0, 404);
            assert!(lp_bal == 6032126418015796449067, 404);
            assert!(collateral_balance == 608595954000000000000, 404);
            assert!(rate == 1000568978919137452, 404);

            test::return_to_sender(s, position);
            test::return_shared(pool);
        };

        next_tx(s,a);{ // Remove quote tokens
            let pool = test::take_shared<Pool<USDC,USDT>>(s);
            let position = test::take_from_sender<Position>(s);

            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_81_());
            assert!(cur_deposit == 2001137957822982288000, 404);
            assert!(lp_bal == 2000000000000000000000, 404);
            assert!(collateral_balance == 0, 404);
            assert!(rate == 1_000568978911491144, 404);

            pool::remove_quote_coins(&mut pool, &mut position, 2001137957822982288000, setup::i9_81_(), clock, ctx(s));

            let (_, cur_deposit, lp_bal, collateral_balance, _, _, rate) = pool::bucket_info(&pool, setup::i9_81_());
            assert!(cur_deposit == 0, 404);
            assert!(lp_bal == 0, 404);
            assert!(collateral_balance == 0, 404);
            assert!(rate == 1_000000000000000000, 404);

            let (lps, deposit_time) = pool::position_info(&position, setup::i9_81_());
            assert!(lps == 0, 404);
            assert!(deposit_time == 0, 404);

            test::return_shared(pool);
            test::return_to_sender(s, position);
        };

        next_tx(s,a);{
            let quote = test::take_from_sender<Coin<USDC>>(s);
            assert!(burn(quote) == 2001_137958, 404);
        };

        next_tx(s,c);{ // kicker withdraw the rewards and stamp loan the postion nft
            let pool = test::take_shared<Pool<USDC,USDT>>(s);
            let position = pool::open_position(&pool, ctx(s));

            pool::kicker_claim_rewards(&mut pool, &mut position, 50_865816540140670495, ctx(s));

            assert!(pool::kicker_claimable(&pool, c) == 0, 404);

            position::transfer(position, c);

            test::return_shared(pool);
        };

        next_tx(s,c);{
            let quote = test::take_from_sender<Coin<USDC>>(s);
            assert!(burn(quote) == 50_865817, 404);
        };

        add_time(clock, setup::day() * 1000);

        next_tx(s,b);{
            let pool = test::take_shared<Pool<USDC, USDT>>(s);

            // pre-borrow
            let (debt, collateral, t0_np) = pool::borrower_info(&pool, b, clock);
            assert!(debt == 0, 404);
            assert!(collateral == 0_621136000000000000, 404);
            assert!(t0_np == 0, 404);

            pool::draw_debt(&mut pool, 972 * math::pow(10,6), setup::i9_72_(), mint<USDT>(100 * math::pow(10, 6), ctx(s)),clock, ctx(s));

            let (debt, collateral, t0_np) = pool::borrower_info(&pool, b, clock);
            assert!(debt == 972_507365618901739172, 404);
            assert!(collateral == 100_621136000000000000, 404);
            assert!(t0_np == 10_507566486513051385, 404);

            test::return_shared(pool);
        };

        add_time(clock, setup::day() * 1000);
        next_tx(s,b);{ // repay debt
            let pool = test::take_shared<Pool<USDC, USDT>>(s);

            // LUP stay at price 9.62 index of 3702
            let coin = mint(975 * math::pow(10,6), ctx(s));
            let collater_to_pull = 100 * math::pow(10, 6);
            pool::repay_debt(&mut pool, b, coin, collater_to_pull, setup::i9_72_(), clock, ctx(s));
            let (debt, collateral, t0_np) = pool::borrower_info(&pool, b, clock);
            assert!(debt == 0, 404);
            assert!(collateral == 0_621136000000000000, 404);
            assert!(t0_np == 0, 404);

            test::return_shared(pool);
        };
        next_tx(s,b);{// return the difference of overpay
            let quote = test::take_from_sender<Coin<USDC>>(s);
            assert!(burn(quote) == 2_471268, 404);
        };

        add_time(clock, setup::day() * 1000);
        next_tx(s,c);{ // add collateral
            let pool = test::take_shared<Pool<USDC, USDT>>(s);
            let position = test::take_from_sender<Position>(s);
            // exist claimable collateral
            let (_, cur_deposit, lp_bal, collateral_balance, _, _, _) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 0, 404);
            assert!(lp_bal == 6032_126418015796449067, 404);
            assert!(collateral_balance == 608_595954000000000000, 404);

            assert!(pool::position_lps(&position, setup::i9_91_()) == 51_273074507299893651,404);

            pool::add_collateral(&mut pool, &mut position, mint<USDT>(100_000000,ctx(s)), setup::i9_91_(), time::get_sec(clock) + 1000, clock, ctx(s));

            assert!(pool::position_lps(&position, setup::i9_91_()) == 1042_427612812987750568,404);

            let (_, cur_deposit, lp_bal, collateral_balance, _, _, _) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 0, 404);
            assert!(lp_bal == 7023_280956321484305984, 404);
            assert!(collateral_balance == 708_595954000000000000, 404);

            test::return_to_sender(s,position);
            test::return_shared(pool);
        };

        add_time(clock, setup::day() * 1000);
        next_tx(s,c);{ // remove collateral
            let pool = test::take_shared<Pool<USDC, USDT>>(s);
            let position = test::take_from_sender<Position>(s);

            pool::remove_collateral(&mut pool, &mut position, 710_000000,setup::i9_91_(), clock, ctx(s));

            // position
            assert!(pool::position_lps(&position, setup::i9_91_()) == 0, 404);

            // bucket
            let (_, cur_deposit, lp_bal, collateral_balance, _, _, _) = pool::bucket_info(&pool, setup::i9_91_());
            assert!(cur_deposit == 0, 404);
            assert!(lp_bal == 5980_853343508496555416, 404);
            assert!(collateral_balance == 603_422888395624342058, 404);

            test::return_to_sender(s,position);
            test::return_shared(pool);
        };

        add_time(clock, setup::day() * 1000);
        next_tx(s,c);{
            let pool = test::take_shared<Pool<USDC, USDT>>(s);

            let (reserves, claimable_reserves, claimable_reserves_remaining, auction_price, time_remaining) = pool::pool_reserves_info(&pool, clock);
            assert!(reserves == 7543539756527467575, 404);
            assert!(claimable_reserves == 7543533741921748332, 404);
            assert!(claimable_reserves_remaining == 0, 404);
            assert!(auction_price == 0, 404);
            assert!(time_remaining == 0, 404);

            pool::kick_reserve_auction(&mut pool, clock);

            let (reserves, claimable_reserves, claimable_reserves_remaining, auction_price, time_remaining) = pool::pool_reserves_info(&pool, clock);
            assert!(reserves == 0_000006014605719243, 404);
            assert!(claimable_reserves == 0, 404);
            assert!(claimable_reserves_remaining == 7_543533741921748332, 404);
            assert!(auction_price == 1000000000_000000000000000000, 404);
            assert!(time_remaining == 259200, 404);
            let (_, unclaimed, _, _) = pool::reserves_info(&pool);
            assert!(unclaimed == 7_543533741921748332, 404);

            // past over an hour, price should be cut in half
            add_time(clock, time::hours() * 1000);
            let (reserves, claimable_reserves, claimable_reserves_remaining, auction_price, time_remaining) = pool::pool_reserves_info(&pool, clock);
            assert!(reserves == 0_000006014605719243, 404);
            assert!(claimable_reserves == 0, 404);
            assert!(claimable_reserves_remaining == 7_543533741921748332, 404);
            assert!(auction_price == 500000000_000000000000000000, 404);
            assert!(time_remaining == 255600, 404);
            let (_, unclaimed, _, _) = pool::reserves_info(&pool);
            assert!(unclaimed == 7_543533741921748332, 404);

            test::return_shared(pool);
        };

        next_tx(s,c);{
            let pool = test::take_shared<Pool<USDC, USDT>>(s);

            pool::take_reserves(&mut pool, 7_543533, mint(3771766500_000000000, ctx(s)), clock, ctx(s));

            test::return_shared(pool);
        };
        next_tx(s,c);{// return the difference of overpay
            let quote = test::take_from_sender<Coin<USDC>>(s);
            assert!(burn(quote) == 7_543533, 404);
        };

        next_tx(s,c);{
            let pool = test::take_shared<Pool<USDC, USDT>>(s);
            let position_from = test::take_from_sender<Position>(s);
            let position = pool::open_position(&pool, ctx(s));

            pool::add_quote_coins(&mut pool, &mut position, setup::i9_91_() + 2, mint<USDC>(2_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));

            pool::add_quote_coins(&mut pool, &mut position_from, setup::i9_91_() + 2, mint<USDC>(4_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));
            pool::add_quote_coins(&mut pool, &mut position_from, setup::i9_91_(), mint<USDC>(7_000 * math::pow(10, 6), ctx(s)), get_time(clock), false, clock, ctx(s));

            position::transfer(position, c);
            test::return_to_sender(s, position_from);
            test::return_shared(pool);
        };

        next_tx(s,c);{
            let pool = test::take_shared<Pool<USDC, USDT>>(s);
            let position_from = test::take_from_sender<Position>(s);
            let position_to = test::take_from_sender<Position>(s);

            pool::merge_position(&mut pool, &mut position_to, position_from);

            test::return_to_sender(s, position_to);
            test::return_shared(pool);
        }
    }
}