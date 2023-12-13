module protocol::assert{
    use sui::clock::Clock;
    use sui::table;

    use protocol::deposit::{Self, DepositState};
    use protocol::loans::{Self, LoansState};
    use protocol::auction::{Self, AuctionState};
    use protocol::helpers;
    use protocol::time;

    use math::wad;

    const ERR_EXPIRY_TX: u64 = 100;
    const ERR_LIMIT_INDEX_EXCEEDED: u64 = 101;
    const ERR_AMOUNT_LESS_THAN_MIN_DEBT:u64 = 102;
    const ERR_DUST_AMOUNT_NOT_EXCEEDED: u64 = 103;
    const ERR_AUCTION_NOT_CLEARED: u64 = 104;
    const ERR_REMOVE_LIQUIDITY_LOCKED_BY_AUCTION_DEBT: u64 = 105;


    public fun check_expiry(expiry: u64, clock: &Clock){
        if(time::get_sec(clock) > expiry) abort ERR_EXPIRY_TX;
    }

    public fun check_on_min_debt(
        loans_state: &LoansState,
        pool_debt: u256,
        borrower_debt: u256,
        quote_dust: u256
    ){
        if(borrower_debt != 0){
            if(borrower_debt < quote_dust) abort ERR_DUST_AMOUNT_NOT_EXCEEDED;
            let loans_count = loans::no_of_loans(loans_state);
            if(loans_count > 10){
                // add borrow restriction after 10 loans
                if(borrower_debt < helpers::min_debt_amount(pool_debt, loans_count)) abort ERR_AMOUNT_LESS_THAN_MIN_DEBT;
            }
        }
    }

    public fun check_price_drop_below_limit(new_price: u256, limit_index: u64){
        if(new_price < helpers::price_at(limit_index)) abort ERR_LIMIT_INDEX_EXCEEDED;
    }

    public fun check_auction_clearable(
        auction_state: &AuctionState,
        loans_state: &LoansState,
        clock: &Clock
    ){
        let head = auction::head(auction_state);
        if(table::contains(auction::liquidations(auction_state), head)){
            let kick_time = auction::kick_time(auction::liquidation(auction_state, head));
            if(kick_time > 0){
                if(time::get_sec(clock) - kick_time > 72 * time::hours()) abort ERR_AUCTION_NOT_CLEARED;

                if(loans::borrower_contains(loans_state, head)){
                    let borrower = loans::borrower(loans_state, head);
                    if(loans::t0_debt(borrower) != 0 && loans::collateral(borrower) == 0) abort ERR_AUCTION_NOT_CLEARED;
                }
            }
       }
    }

    public fun check_auction_debt_locked(
        deposit: &DepositState,
        t0_debt_in_auction: u256,
        index: u64, // index LP is going to removed
        inflator: u256
    ){
        if(t0_debt_in_auction > 0){
            if(index > deposit::find_index_of_sum(deposit, wad::wmul(t0_debt_in_auction, inflator))) abort ERR_REMOVE_LIQUIDITY_LOCKED_BY_AUCTION_DEBT;
        }
    }
}