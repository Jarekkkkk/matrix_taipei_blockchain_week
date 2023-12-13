module protocol::kicker{
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::Clock;
    use sui::object;

    use math::wad;
    use math::u256_common;

    use protocol::helpers;
    use protocol::assert;
    use protocol::time;
    use protocol::event;

    use protocol::auction::{Self, AuctionState};
    use protocol::deposit::{Self, DepositState};
    use protocol::loans::{Self, LoansState};
    use protocol::bucket::{Self, Bucket};
    use protocol::position::Position;

    friend protocol::pool;

    const MAX_INFLATED_PRICE: u256 = 50248449380_325617270970646528;
    const WEEK: u64 = 7 * 86400;
    const HOUR: u64 = 3600;

    const ERR_ACTIVE_AUCTION: u64 = 101;
    const ERR_BORROWER_IS_COLLATERALIZED: u64 = 102;
    const ERR_PRICE_BELOW_LUP: u64 = 103;
    const ERR_INSUFFICIENT_LIQUIDITY: u64 = 103;
    const ERR_RESERVE_AUCTION_TOO_SOON: u64 = 104;
    const ERR_NO_RESERVES: u64 = 105;

    struct KickParams has drop{
        borrower_address: address,
        limit_index: u64,
        additional_debt: u256,
        // pool_state
        pool_type: bool,
        inflator: u256,
        debt: u256
    }
    public(friend) fun new_kick_params(
        borrower_address: address,
        limit_index: u64,
        additional_debt: u256,
        pool_type: bool,
        inflator: u256,
        debt: u256
    ):KickParams{
        KickParams{
            borrower_address,
            limit_index,
            additional_debt,
            pool_type,
            inflator,
            debt
        }
    }

    public (friend) fun kick_(
        auction: &mut AuctionState,
        deposit: &DepositState,
        loans: &mut LoansState,
        params: KickParams,
        clock: &Clock,
        ctx: &TxContext
    ):(u256, u256, u256, u256){
        let liquidations = auction::liquidations(auction);

        // revert if liquidation is active
        if(table::contains(liquidations, params.borrower_address)) abort ERR_ACTIVE_AUCTION;

        let borrower = loans::borrower(loans, params.borrower_address);

        let t0_kicked_debt = loans::t0_debt(borrower);
        let collateral_pre_action = loans::collateral(borrower);

        let lup = deposit::get_Lup(deposit, params.debt + params.additional_debt);

        let borrower_debt = wad::wmul(t0_kicked_debt, params.inflator);

        if(helpers::is_collateralized(borrower_debt, collateral_pre_action, lup, params.pool_type)) abort ERR_BORROWER_IS_COLLATERALIZED;

        // neutral price = Tp * Np to Tp ratio
        // neutral price is capped at 50 * max pool price
        let neutral_price = wad::min(u256_common::mul_div(borrower_debt, loans::np_tp_ratio(borrower), collateral_pre_action), MAX_INFLATED_PRICE);
        assert::check_price_drop_below_limit(neutral_price, params.limit_index);

        let htp = wad::wmul(loans::loan_threshold_price(&loans::get_max(loans)), params.inflator);
        let reference_price = wad::min(wad::max(htp, neutral_price), MAX_INFLATED_PRICE);
        let (bond_factor, bond_size) = helpers::bond_params(borrower_debt, loans::np_tp_ratio(borrower));

        // record liquidation info
        {
            table::add(auction::liquidations_mut(auction), params.borrower_address, auction::default_liquidation());

            let liquidation = auction::liquidation_mut(auction, params.borrower_address);
            auction::update_kicker_address(liquidation, tx_context::sender(ctx));
            auction::update_kick_time(liquidation, time::get_sec(clock));
            auction::update_reference_price(liquidation, reference_price);
            auction::update_neutral_price(liquidation, neutral_price);
            auction::update_bond_size(liquidation, bond_size);
            auction::update_bond_factor(liquidation, bond_factor);
        };

        // increment number of active auctions
        auction::add_num_of_auctions(auction);

        // update auctions queue
        if(auction::head(auction) != @0x00){
            // other auctions in queue, liquidation doesn't exist or overwriting.
            let tail = auction::tail(auction);

            // initalize liquidation if not exist
            if(!table::contains(auction::liquidations(auction), tail)) table::add(auction::liquidations_mut(auction), tail, auction::default_liquidation());

            auction::update_next(auction::liquidation_mut(auction, tail), params.borrower_address);
            auction::update_prev(auction::liquidation_mut(auction, params.borrower_address), tail);
        }else{
            // first auction in queue for 1 hour grace period
            auction::update_head(auction, params.borrower_address);
        };
        auction::update_tail(auction, params.borrower_address);


        // update escrowed bonds balances and get the difference needed to cover bond (after using any kick claimable funds if any)
        let kicker = tx_context::sender(ctx);
        let amonut_to_cover_bond = {
            // update total escrowed bond
            let bond_diff = 0;
            if(!table::contains(auction::kickers(auction), kicker)){
                table::add(auction::kickers_mut(auction), kicker, auction::default_kicker());
            };
            let kicker = auction::kicker_mut(auction, kicker);
            auction::add_locked(kicker, bond_size);

            if(auction::claimable(kicker) >= bond_size){
                // no need to update total bond escrowed as bond is covered by kicker claimable (which is already tracked by accumulator)
                auction::remove_claimable(kicker, bond_size);
            }else{
                bond_diff = bond_size - auction::claimable(kicker);
                auction::update_claimable(kicker, 0);
                auction::add_total_bond_escrowed(auction, bond_diff);
            };
            bond_diff
        };

        // remove kicked loan from heap
        let idx = loans::borrower_indices(loans, params.borrower_address);
        loans::remove(loans, params.borrower_address, idx);

        event::kick(params.borrower_address, borrower_debt, collateral_pre_action, bond_size);

        (amonut_to_cover_bond, t0_kicked_debt, collateral_pre_action, lup)
    }


    public (friend) fun lender_kick<Collateral>(
        auction: &mut AuctionState,
        deposit: &DepositState,
        buckets: &Table<u64, Bucket<Collateral>>,
        loans: &mut LoansState,
        position: &Position,
        params: KickParams,
        index: u64,
        clock: &Clock,
        ctx: &TxContext
    ):(u256, u256, u256, u256){
        let bucket_price = helpers::price_at(index);

        if(bucket_price < deposit::get_Lup(deposit, params.debt)) abort ERR_PRICE_BELOW_LUP;

        let bucket = table::borrow(buckets, index);
        let lender = bucket::lender(bucket, object::id(position));

        let lender_lp = if(bucket::bankruptcy_time(bucket) < bucket::lender_deposit_time(lender)) bucket::lender_lps(lender) else 0;
        let bucket_deposit = deposit::value_at(deposit, index);

        // calculate amount lender is entitled in current bucket (based on lender LP in bucket)
        let entitled_amount = bucket::LP_to_quote_token(bucket::collateral(bucket), bucket::lps(bucket), bucket_deposit, lender_lp, bucket_price, false);

        // cap the amount entitled at bucket deposit
        entitled_amount = wad::min(entitled_amount, bucket_deposit);

        if(entitled_amount == 0) abort ERR_INSUFFICIENT_LIQUIDITY;

        // kick top borrower
        params.additional_debt = entitled_amount;
        kick_(auction, deposit, loans, params, clock, ctx)
    }

    // public (friend) fun kick_reserve_auction(
    //     auction: &AuctionState,
    //     reserve_auction: &mut ReserveAuctionState,
    //     pool_size: u256,
    //     t0_pool_debt: u256,
    //     pool_balance: u256,
    //     inflator: u256,
    //     clock: &Clock
    // ){
    //     let latest_burn_epoch = reserve_auction::latest_burn_event_epoch(reserve_auction);
    //     let burn_event = reserve_auction::burn_event(reserve_auction, latest_burn_epoch);
    //     let ts = time::get_sec(clock);

    //     // check that at least two weeks have passed since the last reserve auction completed, and that the auction was not kicked within the past 72 hours
    //     if(ts < reserve_auction::timestamp(burn_event) + 2 * WEEK
    //         || ts - reserve_auction::kicked(reserve_auction) <= 72 * HOUR
    //     ) abort ERR_RESERVE_AUCTION_TOO_SOON;

    //     let unclaimed_auction_reserve = reserve_auction::unclaimed(reserve_auction);

    //     let claimable = helpers::claimable_reserves(wad::wmul(t0_pool_debt, inflator), pool_size, auction::total_bond_escrowed(auction), unclaimed_auction_reserve, pool_balance);

    //     unclaimed_auction_reserve = unclaimed_auction_reserve + claimable;

    //     if(unclaimed_auction_reserve == 0) abort ERR_NO_RESERVES;

    //     reserve_auction::update_unclaimed(reserve_auction, unclaimed_auction_reserve);
    //     reserve_auction::update_kicked(reserve_auction, ts);

    //     // kicked in new burn event
    //     reserve_auction::new_burn_event(reserve_auction, clock);

    //     event::kick_reserve_auction(unclaimed_auction_reserve, helpers::reserve_auction_price(ts, clock), reserve_auction::latest_burn_event_epoch(reserve_auction));
    // }
}