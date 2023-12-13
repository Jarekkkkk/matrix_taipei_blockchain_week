module protocol::pool{
    use std::string::String;
    use std::vector as vec;
    use std::option::{Self, Option};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::clock::{Clock};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object_bag::{Self, ObjectBag};
    use sui::vec_map;
    // lib-math
    use math::int::{Self};
    use math::ud60x18;
    use math::sd59x18;
    use math::u256_common;
    use math::wad;
    // protocol-lib
    use protocol::time;
    use protocol::constants;
    use protocol::helpers;
    use protocol::assert;
    use protocol::event;
    //state
    use protocol::interest::{Self, InterestState, InflatorState};
    use protocol::deposit::{Self, DepositState};
    use protocol::ema::{Self, EmaState};
    use protocol::loans::{Self, LoansState, Borrower, Loan};
    use protocol::bucket::{Self, Bucket};
    use protocol::auction::{Self, AuctionState};
    use protocol::position::{Self, Position};
    use protocol::sdb::{Self, SDB};
    // action
    use protocol::lender;
    use protocol::borrower;
    use protocol::kicker;
    // use protocol::taker;
    // use protocol::settler;

    friend protocol::pool_factory;

    const ERR_ZERO_COIN_VALUE: u64 = 101;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 102;
    const ERR_INSUFFICIENT_ESCROWED_BOND: u64 = 103;
    const ERR_OUT_OF_INDEX: u64 = 104;
    const ERR_NOT_TOKEN_POOL: u64 = 105;
    const ERR_NOT_NFT_POOL: u64 = 106;
    const ERR_INCORRECT_POSITION: u64 = 107;
    const ERR_INSUFFICIENT_LIQUIDITY: u64 = 108;
    const ERR_POSITION_LIQUIDITY_REMAINED: u64 = 109;
    const ERR_UNMATCHED_POOL: u64 = 110;

    const WAD: u256 = 1000000000000000000;
    const ONE_THIRD: u256 = 333_333_333_333_333_334;
    const CUBIC_ROOT_1000000: u256 = 100_000_000_000_000_000_000;

    struct Pool<phantom Quote, phantom Collateral> has key{
        // Static state
        id: UID,
        name: String,
        /// true when pool is in pair of tokens, false when it's NFT pool
        pool_type: bool,
        // assets
        quote_balance: Balance<Quote>,
        collateral_balance: Balance<Collateral>,
        collateral_nft: ObjectBag,
        borrower_nft_ids: Table<address, vector<ID>>,
        // all deposited NFTs in pool
        claimable_nfts: vector<ID>,
        /// scales the amount to 18 decimals number
        collateral_scale: u256,
        quote_scale: u256,
        // Customized State
        inflator_state: InflatorState,
        interest_state: InterestState,
        loans_state: LoansState,
        auction_state: AuctionState,
        pool_balance_state: PoolBalanceState,
        deposit_state: DepositState,
        ema_state: EmaState,
        buckets: Table<u64, Bucket<Collateral>>,
        // since we are unable to store burncap for each pool, we will locked up tokens here
        burnt_sdb: Balance<SDB>
    }

    // [VIEW]
    public fun name<Quote, Collateral>(self: &Pool<Quote, Collateral>):String{
        self.name
    }
    public fun pool_type<Quote, Collateral>(self: &Pool<Quote, Collateral>):bool{
        self.pool_type
    }
    public fun collateral_balance<Quote, Collateral>(self: &Pool<Quote, Collateral>):u64{
        balance::value(&self.collateral_balance)
    }
    public fun quote_balance<Quote, Collateral>(self: &Pool<Quote, Collateral>):u64{
        balance::value(&self.quote_balance)
    }
    public fun collateral_scale<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        self.collateral_scale
    }
    public fun quote_scale<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        self.quote_scale
    }
    // Utils
    public fun pool_prices_info<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        clock: &Clock
    ):(u256, u64, u256, u64, u256, u64){
        let hpb_indx = deposit::find_index_of_sum(&self.deposit_state, 1);
        let hpb = helpers::price_at(hpb_indx);

        let ( _, max_threshold_price, _ ) = loans_info(self);
        let htp = max_threshold_price;
        let htp_index = if(htp >= constants::min_price()) helpers::index_of(htp) else constants::max_fenwick_index();

        let (debt, _, _, _) = debt_info(self, clock);
        let lup_index = deposit::find_index_of_sum(&self.deposit_state, debt);
        let lup = helpers::price_at(lup_index);

        (hpb, hpb_indx, htp, htp_index, lup, lup_index)
    }
    public fun debt_info<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        clock: &Clock
    )
    :(u256, u256, u256, u256){
        let t0_debt = self.pool_balance_state.t0_debt;
        let inflator = interest::inflator(&self.inflator_state);

        let debt = wad::ceilWmul(t0_debt, interest::pending_inflator(&self.inflator_state, &self.interest_state, clock));
        let accrued_debt = wad::ceilWmul(t0_debt, inflator);
        let debt_in_auction = wad::ceilWmul(self.pool_balance_state.t0_debt_in_auction, inflator);
        (debt, accrued_debt, debt_in_auction, interest::t0_debt2_to_collateral(&self.interest_state))
    }
    public fun loans_info<Quote, Collateral>(self: &Pool<Quote, Collateral>)
    :(address, u256, u64){
        let max_loan = loans::get_max(&self.loans_state);
        (loans::loan_borower(&max_loan), wad::wmul(loans::loan_threshold_price(&max_loan), interest::inflator(&self.inflator_state)), loans::no_of_loans(&self.loans_state))
    }
    public fun auction_info<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address)
    :(address, u256, u256, u64, u256, u256, address, address, address){
        let (kicker, bond_factor, kick_time, prev, reference_price, next, bond_size, neutral_price) = auction::liquidation_info(auction::liquidation(&self.auction_state, borrower));
        (
            kicker,
            bond_factor,
            bond_size,
            kick_time,
            reference_price,
            neutral_price,
            auction::head(&self.auction_state),
            prev,
            next,
        )
    }
    public fun auction_status<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        borrower: address,
        clock: &Clock
    ):(u64, u256, u256, bool, u256, u256){
        let (_, _, _, kick_time, reference_price, neutral_price, _, _, _) = auction_info(self, borrower);

        let debt_to_cover = 0;
        let collateral = 0;
        let is_collateralized = false;
        let price = 0;
        if(kick_time != 0){
            let (debt_to_cover_, collateral_, _) = borrower_info(self, borrower, clock);
            debt_to_cover = debt_to_cover_;
            collateral = collateral_;

            let (debt, _, _, _) = debt_info(self, clock);
            let lup = helpers::price_at(deposit::find_index_of_sum(&self.deposit_state, debt));
            is_collateralized = helpers::is_collateralized(debt, collateral, lup, self.pool_type);

            price = helpers::auction_price(reference_price, kick_time, clock);
        };
        (kick_time, collateral, debt_to_cover, is_collateralized, price, neutral_price)
    }
    public fun pool_loans_info<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        clock: &Clock
    ):(u256, u64, address, u256, u256){
        let pool_size = deposit_size(self);
        let (max_borrower, _, loans_count) = loans_info(self);

        let inflator_last_update = interest::inflator_last_update(&self.inflator_state);
        let interest_rate = interest::interest_rate(&self.interest_state);

        let pending_inflator = interest::pending_inflator(&self.inflator_state, &self.interest_state, clock);
        let pending_factor = interest::pending_interest_factor(interest_rate, time::get_sec(clock) - inflator_last_update);

        (pool_size, loans_count, max_borrower, pending_inflator, pending_factor)
    }
    public fun pool_utilization_info<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        clock: &Clock
    ):(u256, u256, u256, u256){
        let (debt, _, _, _) = debt_info(self, clock);
        let (_, _, no_of_loans) = loans_info(self);

        let min_debt_amount = helpers::min_debt_amount(debt, no_of_loans);
        let collateralization = collateralization_(debt, pledged_collateral(self), helpers::price_at(deposit_index(self, debt)));

        (min_debt_amount, collateralization, get_Mau(self), get_Tu(self))
    }
    public fun bucket_info<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        index: u64
    ):(u256, u256, u256, u256, u64, u256, u256){
        let bucket = table::borrow(&self.buckets, index);
        let scale = deposit::scale(&self.deposit_state, index);
        let price = helpers::price_at(index);
        let quote_tokens = wad::wmul(scale, deposit::unscaled_value_at(&self.deposit_state, index));
        let exchange_rate = bucket::get_exchange_rate(bucket,quote_tokens, price);

        (price, quote_tokens, bucket::lps(bucket), bucket::collateral(bucket), bucket::bankruptcy_time(bucket), scale, exchange_rate)
    }
    public fun borrower_info<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        borrower: address,
        clock: &Clock
    ):(u256, u256, u256){
        let (t0_debt, collateral, np_tp_ratio) = loans::borrower_state(loans::borrower(&self.loans_state, borrower));
        let pending_inflator = interest::pending_inflator(&self.inflator_state, &self.interest_state, clock);
        let debt = wad::wmul(t0_debt, pending_inflator);
        let t0_np = u256_common::mul_div(t0_debt, np_tp_ratio, collateral);

        (debt, collateral, t0_np)
    }
    public fun get_Lup<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        deposit::get_Lup(&self.deposit_state, interest::debt(&self.interest_state))
    }
    public fun get_Htp<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        let (_, htp, _) = loans_info(self);
        htp
    }
    public fun get_Mau<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        ema::utilization(&self.ema_state)
    }
    public fun get_Tu<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        if(ema::lup_t0_debt_ema(&self.ema_state) != 0) wad::wdiv(ema::debt_col_ema(&self.ema_state), ema::lup_t0_debt_ema(&self.ema_state)) else 1_000_000_000_000_000_000
    }
    public fun lender_interest_margin<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        lender_interest_margin_(get_Mau(self))
    }
    public fun borrower_collateralization<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        borrower: address,
        clock: &Clock
    ): u256{
        let price = get_Lup(self);
        let (debt, collateral, _) = borrower_info(self, borrower, clock);

        let encumberance = if(price == 0 || debt == 0) 0 else wad::wdiv(debt, price);
        if(encumberance == 0) wad::wad(1) else wad::wdiv(collateral, encumberance)
    }
    public fun bond_params<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address, clock: &Clock):(u256, u256){
        let borrower = loans::borrower(&self.loans_state, borrower);
        let inflator = interest::pending_inflator(&self.inflator_state, &self.interest_state, clock);
        helpers::bond_params(wad::wmul(loans::t0_debt(borrower), inflator), loans::np_tp_ratio(borrower))
    }
    public fun loan_info<Quote, Collateral>(self: &Pool<Quote, Collateral>, index: u64):(address, u256){
        let loan = loans::get_by_index(&self.loans_state, index);
        (loans::loan_borower(&loan), loans::loan_threshold_price(&loan))
    }
    public fun lender_info<Quote, Collateral>(self: &Pool<Quote, Collateral>, position_: &Position, index: u64):(u256, u64){
        let bucket = table::borrow(&self.buckets, index);
        let position = object::id(position_);
        if(!bucket::is_lender(bucket, position)) return (0, 0);
        let lender = bucket::lender(bucket, position);

        let deposit_time = bucket::lender_deposit_time(lender);
        let lp_bal = if(bucket::bankruptcy_time(bucket) < deposit_time) bucket::lender_lps(lender) else 0;

        (lp_bal, deposit_time)
    }
    public fun position_info(position: &Position, index: u64):(u256, u64){
        let lender_ = sui::vec_map::try_get(position::positions(position), &index);
        if(option::is_some(&lender_)){
            let lender = option::destroy_some(lender_);
            (bucket::lender_lps(&lender), bucket::lender_deposit_time(&lender))
        }else{
            (0, 0)
        }
    }
    public fun kicker_info<Quote, Collateral>(self: &Pool<Quote, Collateral>, kicker: address):(u256, u256){
        let kicker = auction::kicker(&self.auction_state, kicker);
        (auction::claimable(kicker), auction::locked(kicker))
    }
    // DepositState
    public fun deposit_borrow<Quote, Collateral>(self: &Pool<Quote, Collateral>):&DepositState{
        &self.deposit_state
    }
    // public fun deposit_values<Quote, Collateral>(self: &Pool<Quote, Collateral>):&vector<u256>{
    //     deposit::values(&self.deposit_state)
    // }
    // public fun deposit_scaling<Quote, Collateral>(self: &Pool<Quote, Collateral>):&vector<u256>{
    //     deposit::scaling(&self.deposit_state)
    // }
    public fun deposit_up_to_index<Quote, Collateral>(self:&Pool<Quote,Collateral>, index: u64):u256{
        deposit::prefix_sum(&self.deposit_state, index)
    }
    public fun deposit_index<Quote, Collateral>(self: &Pool<Quote, Collateral>, debt: u256):u64{
        deposit::find_index_of_sum(&self.deposit_state, debt)
    }
    public fun deposit_size<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        deposit::tree_sum(&self.deposit_state)
    }
    // buckets
    public fun buckets_borrow<Quote, Collateral>(self: &Pool<Quote, Collateral>):&Table<u64, Bucket<Collateral>>{
        &self.buckets
    }
    public fun bucket_at<Quote, Collateral>(self: &Pool<Quote, Collateral>, idx: u64):&Bucket<Collateral>{
        table::borrow(&self.buckets, idx)
    }
    public fun bucket_exchange_rate<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        index: u64
    ):u256{
        bucket::get_exchange_rate(table::borrow(&self.buckets, index), deposit::value_at(&self.deposit_state, index), helpers::price_at(index))
    }
    // Ema state
    public fun ema_state<Quote, Collateral>(self: &Pool<Quote, Collateral>):&EmaState{
        &self.ema_state
    }
    public fun emas_info<Quote, Collateral>(self: &Pool<Quote, Collateral>)
    :(u256, u256, u256, u256, u64){
        ema::ema_state(&self.ema_state)
    }
    // Loans state
    public fun loans<Quote, Collateral>(self: &Pool<Quote, Collateral>):&vector<Loan>{
        loans::loans(&self.loans_state)
    }
    public fun borrower<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):&Borrower{
        loans::borrower(&self.loans_state, borrower)
    }
    public fun borrower_indices<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address): u64{
        loans::borrower_indices(&self.loans_state, borrower)
    }
    public fun borrower_t0_debt<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address): u256{
        loans::t0_debt(loans::borrower(&self.loans_state, borrower))
    }
    public fun borrower_collateral<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address): u256{
        loans::collateral(loans::borrower(&self.loans_state, borrower))
    }
    public fun borrower_np_tp_ratio<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address): u256{
        loans::np_tp_ratio(loans::borrower(&self.loans_state, borrower))
    }
    // inflator
    public fun inflator<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        interest::inflator(&self.inflator_state)
    }
    public fun inflator_last_update<Quote, Collateral>(self: &Pool<Quote, Collateral>):u64{
        interest::inflator_last_update(&self.inflator_state)
    }
    // interest rate
    public fun interest_rate<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        interest::interest_rate(&self.interest_state)
    }
    public fun debt<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        interest::debt(&self.interest_state)
    }
    public fun meaningful_deposit<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        interest::meaningful_deposit(&self.interest_state)
    }
    public fun t0_debt2_to_collateral<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        interest::t0_debt2_to_collateral(&self.interest_state)
    }
    public fun debt_col<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        interest::debt_col(&self.interest_state)
    }
    public fun lup_t0_debt<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        interest::lup_t0_debt(&self.interest_state)
    }
    // // reserve auction
    // public fun total_interest_earned<Quote, Collateral>(self: &Pool<Quote, Collateral>): u256{
    //     reserve_auction::total_interest_earned(&self.reserve_auction_state)
    // }
    // auction
    public fun num_of_auctions<Quote, Collateral>(self: &Pool<Quote, Collateral>):u64{
        auction::num_of_auctions(&self.auction_state)
    }
    public fun head<Quote, Collateral>(self: &Pool<Quote, Collateral>):address{
        auction::head(&self.auction_state)
    }
    public fun tail<Quote, Collateral>(self: &Pool<Quote, Collateral>):address{
        auction::tail(&self.auction_state)
    }
    public fun total_bond_escrowed<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        auction::total_bond_escrowed(&self.auction_state)
    }
    public fun liquidation_auction_price<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        borrower: address,
        clock: &Clock
    ):u256{
        auction::auction_price(&self.auction_state, borrower, clock)
    }
    public fun liquidation_kicker<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):address{
        auction::liquidation_kicker(auction::liquidation(&self.auction_state, borrower))
    }
    public fun liquidation_bond_factor<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):u256{
        auction::bond_factor(auction::liquidation(&self.auction_state, borrower))
    }
    public fun liquidation_kick_time<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):u64{
        auction::kick_time(auction::liquidation(&self.auction_state, borrower))
    }
    public fun liquidation_prev<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):address{
        auction::prev(auction::liquidation(&self.auction_state, borrower))
    }
    public fun liquidation_reference_price<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):u256{
        auction::reference_price(auction::liquidation(&self.auction_state, borrower))
    }
    public fun liquidation_next<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):address{
        auction::next(auction::liquidation(&self.auction_state, borrower))
    }
    public fun liquidation_bond_size<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):u256{
        auction::bond_size(auction::liquidation(&self.auction_state, borrower))
    }
    public fun liquidation_neutral_price<Quote, Collateral>(self: &Pool<Quote, Collateral>, borrower: address):u256{
        auction::neutral_price(auction::liquidation(&self.auction_state, borrower))
    }
    public fun kicker_lender<Quote, Collateral>(pool: &Pool<Quote, Collateral>, kicker: address, index: u64):(u256, u64){
        auction::kicker_lender(auction::kicker(&pool.auction_state, kicker), index)
    }
    public fun kicker_claimable<Quote, Collateral>(self: &Pool<Quote, Collateral>, kicker: address):u256{
        auction::claimable(auction::kicker(&self.auction_state, kicker))
    }
    public fun kicker_locked<Quote, Collateral>(self: &Pool<Quote, Collateral>, kicker: address):u256{
        auction::locked(auction::kicker(&self.auction_state, kicker))
    }

    struct PoolBalanceState has store{
        // [WAD] total collateral pledged in pool
        pledged_collateral: u256,
        // [WAD] Total debt in auction used to restrict LPB holder from withdrawing
        t0_debt_in_auction: u256,
        // [WAD] Pool debt as if the whole amount was incurred upon the first loan
        t0_debt: u256
    }
    // Pool Balance
    public fun pledged_collateral<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        self.pool_balance_state.pledged_collateral
    }
    public fun t0_debt_in_auction<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        self.pool_balance_state.t0_debt_in_auction
    }
    public fun t0_debt<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        self.pool_balance_state.t0_debt
    }
    // Position
    public fun position_lps(position: &Position, index: u64):u256{
        let lender_opt = position::lender(position, &index);
        if(option::is_some(&lender_opt)){
            bucket::lender_lps(&option::destroy_some(lender_opt))
        }else{
            0
        }
    }

    // Args in memory only
    struct PoolStateArg has drop{
        // is Coin or NFT pools
        pool_type: bool,
        // [WAD] t0 debt in pool
        t0_debt:u256,
        // [WAD] t0 debt in auction within pool
        t0_debt_in_auction: u256,
        // [WAD] total debt in pool, accrued in current block
        debt: u256,
        // [WAD] total collateral pledged in pool
        collateral: u256,
        // [WAD] current pool inflator
        inflator: u256,
        // true if new interest already accrued in current block
        is_new_interest_accrued: bool,
        // [WAD] pool's current interest rate
        i_rate: u256,
        // [WAD] quote token scale of the pool. Same as quote token dust.
        quote_token_scale: u256
    }

    fun default_pool_state<Quote, Collateral>(self: &Pool<Quote, Collateral>):PoolStateArg{
        PoolStateArg{
            pool_type: self.pool_type,
            t0_debt: self.pool_balance_state.t0_debt,
            t0_debt_in_auction: self.pool_balance_state.t0_debt_in_auction,
            debt: 0,
            collateral: self.pool_balance_state.pledged_collateral,
            inflator: interest::inflator(&self.inflator_state),
            is_new_interest_accrued: false,
            i_rate: interest::interest_rate(&self.interest_state),
            quote_token_scale: self.quote_scale,
        }
    }

    // Create new Pool called by registry object
    public(friend) fun new<Quote, Collateral>(
        name: String,
        quote_scale: u256,
        collateral_scale: Option<u256>,
        i_rate: u256,
        ctx: &mut TxContext
    ): address{
        let id = object::new(ctx);
        let address_ = object::uid_to_address(&id);
        let ts = tx_context::epoch_timestamp_ms(ctx) / 1000;
        // it's impossible token has 18 decimals in Sui, so it's alright we check whether collateral scale is 1 to verify it's token or NFT pool
        let collateral_scale = option::destroy_with_default(collateral_scale, 1);
        let pool = Pool<Quote, Collateral>{
            id,
            name,
            pool_type: collateral_scale != 1,
            quote_balance: balance::zero<Quote>(),
            collateral_balance: balance::zero<Collateral>(),
            collateral_nft: object_bag::new(ctx),
            borrower_nft_ids: table::new<address, vector<ID>>(ctx),
            claimable_nfts: vec::empty(),
            collateral_scale,
            quote_scale,
            inflator_state: interest::default_inflator_state(ts),
            interest_state: interest::default_interest_state(i_rate, ts),
            loans_state: loans::default_loans_state(ctx),
            auction_state: auction::default_auction_state(ctx),
            pool_balance_state: PoolBalanceState{
                pledged_collateral: 0,
                t0_debt_in_auction: 0,
                t0_debt: 0
            },
            deposit_state: deposit::default_deposit_state(ctx),
            ema_state: ema::default_ema_state(),
            //reserve_auction_state: reserve_auction::default_reserve_auction_state(ctx),
            buckets: table::new<u64, Bucket<Collateral>>(ctx),
            burnt_sdb: balance::zero<SDB>()
        };

        transfer::share_object(pool);
        address_
    }

    // ============ Lender Entry ============
    public fun open_position<Quote, Collateral>(
        self: &Pool<Quote, Collateral>,
        ctx: &mut TxContext
    ):Position{
        position::new(object::id(self), ctx)
    }

    public fun merge_position<Quote,Collateral>(
        self: &mut Pool<Quote, Collateral>,
        to: &mut Position,
        from: Position
    ){
        assert!(position::pool(to) == position::pool(&from), ERR_UNMATCHED_POOL);
        let indexes = vec_map::keys(position::positions(&from));
        let totoal_transferred = 0;
        let from_id = object::id(&from);
        let to_id = object::id(to);

        let i = 0;
        while(i < vec::length(&indexes)){
            let index = *vec::borrow(&indexes, i);

            let bucket = table::borrow(&self.buckets, index);
            let from_lender = bucket::lender(bucket, from_id);

            let bankruptcy_time = bucket::bankruptcy_time(bucket);
            let from_deposit_time = bucket::lender_deposit_time(from_lender);
            let transfered_lps = if(bankruptcy_time < from_deposit_time) bucket::lender_lps(from_lender) else 0;

            if(transfered_lps != 0){
                let bucket = table::borrow_mut(&mut self.buckets, index);
                let lenders_mut = bucket::lenders_mut(bucket);

                let to_lender = { // to lender postion update
                    if(!table::contains(lenders_mut, to_id)){
                        table::add(lenders_mut, to_id, bucket::default_lender());
                    };
                    let to_lender = table::borrow_mut(lenders_mut, to_id);
                    let to_deposit_time = bucket::lender_deposit_time(to_lender);
                    // update new position lps
                    if( to_deposit_time > bankruptcy_time){
                        bucket::add_lender_lps(to_lender, transfered_lps);
                    }else{
                        bucket::update_lender_lps(to_lender, transfered_lps);
                    };
                    bucket::update_deposit_time(to_lender ,sui::math::max(from_deposit_time, to_deposit_time));

                    *table::borrow(lenders_mut, to_id)
                };
                // drop from_lender position
                let from_lps = {
                    let from_lender = table::borrow_mut(lenders_mut, from_id);
                    bucket::remove_lender_lps(from_lender, transfered_lps);
                    bucket::lender_lps(from_lender)
                };

                // drop empty lps or bankruptcy position
                assert!(bankruptcy_time > from_deposit_time || from_lps == 0, ERR_POSITION_LIQUIDITY_REMAINED);

                // delte from position nft
                position::drop_position(&mut from, index);
                // update to position nft
                position::update_position(to, index, to_lender);

                totoal_transferred = totoal_transferred + transfered_lps;
            };

            i = i + 1;
        };
        position::delete(from);
    }

    public fun close_position<Quote, Collateral>(
        position: Position
    ){
        position::delete(position);
    }

    entry public fun add_quote_coins<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        index: u64,
        quote: Coin<Quote>,
        expiry: u64,
        revert_if_below_lup: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ): u256{
        assert!(position::pool(position) == object::id(self), ERR_INCORRECT_POSITION);
        assert::check_expiry(expiry, clock);
        assert::check_auction_clearable(&self.auction_state, &self.loans_state, clock);

        let amount = coin::value(&quote);
        let pool_state = accrue_pool_interest_(self, clock);

        // round to token precision
        let amount = ( amount as u256 ) * pool_state.quote_token_scale;

        let _new_Lup = 0_u256;
        let (bucket_LP, _new_Lup) = lender::add_quote_coins_(position, &mut self.buckets, &mut self.deposit_state, lender::new_add_quote_params(
            amount,
            index,
            revert_if_below_lup,
            pool_state.debt,
            pool_state.i_rate
        ),clock, ctx);

        // update self interest rate state
        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, _new_Lup, clock);
        // move quote token amount from lender to pool
        deposit_coins<Quote>(amount, self.quote_scale, &mut self.quote_balance, quote, ctx);

        // position nft update
        update_position_(position, &self.buckets, index);

        bucket_LP
    }

    entry public fun move_quote_coins<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        //  max quote amount to moved from
        max_amount: u256,
        from_index: u64,
        to_index: u64,
        expiry: u64,
        revert_if_below_lup: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ):(u256, u256, u256){
        assert!(position::pool(position) == object::id(self), ERR_INCORRECT_POSITION);
        assert::check_expiry(expiry, clock);
        assert::check_auction_clearable(&self.auction_state, &self.loans_state, clock);

        let pool_state = accrue_pool_interest_(self, clock);
        assert::check_auction_debt_locked(&self.deposit_state, pool_state.t0_debt_in_auction, from_index, pool_state.inflator);

        let params = lender::new_move_quote_params(from_index, to_index, max_amount, get_Htp(self), revert_if_below_lup, pool_state.inflator, pool_state.i_rate, pool_state.debt, pool_state.quote_token_scale);

        let (fromBucketLP_, toBucketLP_, movedAmount_, newLup) = lender::move_quote_tokens(position, &mut self.buckets, &mut self.deposit_state, params, clock, ctx);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, newLup, clock);

        // position nft update
        update_position_(position, &self.buckets, from_index);
        update_position_(position, &self.buckets, to_index);

        (fromBucketLP_, toBucketLP_, movedAmount_)
    }

    entry public fun remove_quote_coins<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        //  max amount to move between deposits
        max_amount: u256,
        index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ):(u256, u256){
        assert!(position::pool(position) == object::id(self), ERR_INCORRECT_POSITION);
        assert::check_auction_clearable(&self.auction_state, &self.loans_state, clock);

        let pool_state = accrue_pool_interest_(self, clock);
        assert::check_auction_debt_locked(&self.deposit_state, pool_state.t0_debt_in_auction, index, pool_state.inflator);
        let params = lender::new_remove_quote_params(index, wad::min(max_amount, available_quote_tokens(self)), get_Htp(self), pool_state.quote_token_scale, pool_state.inflator, pool_state.debt);

        let (removedAmount_, redeemedLP_, newLup) = lender::remove_quote_tokens(position, &mut self.buckets, &mut self.deposit_state, params, clock);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, newLup, clock);

        take_coins(removedAmount_, self.quote_scale, &mut self.quote_balance, ctx);

        // update position
        update_position_(position, &self.buckets, index);

        (removedAmount_, redeemedLP_)
    }

    entry public fun add_collateral<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        collateral: Coin<Collateral>,
        index: u64,
        expiry: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ):u256{
        assert!(self.pool_type, ERR_NOT_TOKEN_POOL);
        assert::check_expiry(expiry, clock);
        assert!(position::pool(position) == object::id(self), ERR_INCORRECT_POSITION);

        let value = (coin::value(&collateral) as u256) * self.collateral_scale;
        if(value == 0) abort ERR_ZERO_COIN_VALUE;

        let pool_state = accrue_pool_interest_(self, clock);

        let bucket_lp = lender::add_collateral(&mut self.buckets, position, &mut self.deposit_state, value, index, clock);

        event::add_collateral(object::id(position), index, value, bucket_lp);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, deposit::get_Lup(&self.deposit_state, pool_state.debt), clock);

        deposit_coins(value, self.collateral_scale, &mut self.collateral_balance, collateral, ctx);

        // TODO: update in internal function to sync up the logic updat
        update_position_(position, &self.buckets, index);

        bucket_lp
    }

    entry public fun add_collateral_nft<Quote, Collateral:key + store>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        collateral: vector<Collateral>,
        index: u64,
        expiry: u64,
        clock: &Clock
    ):u256{
        assert!(!self.pool_type, ERR_NOT_NFT_POOL);
        assert::check_expiry(expiry, clock);
        assert!(position::pool(position) == object::id(self), ERR_INCORRECT_POSITION);

        let num_of_nfts = vec::length(&collateral);

        let pool_state = accrue_pool_interest_(self, clock);

        let bucket_lp = lender::add_collateral(&mut self.buckets, position, &mut self.deposit_state, wad::wad((num_of_nfts as u256)), index, clock);

        event::add_collateral_nft(object::id(position), index, num_of_nfts, bucket_lp);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, deposit::get_Lup(&self.deposit_state, pool_state.debt), clock);

        // deposit nft to pool claimable nft
        let i = 0;
        while(i < num_of_nfts){
            let id = deposit_nft(&mut self.collateral_nft, vec::pop_back(&mut collateral));
            vec::push_back(&mut self.claimable_nfts, id);

            i = i + 1;
        };
        vec::destroy_empty(collateral);

        update_position_(position, &self.buckets, index);

        bucket_lp
    }

    entry public fun remove_collateral<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        max_amount: u64,
        index: u64,
        clock:&Clock,
        ctx: &mut TxContext
    ){
        assert!(self.pool_type, ERR_NOT_TOKEN_POOL);
        assert::check_auction_clearable(&self.auction_state, &self.loans_state, clock);

        let pool_state = accrue_pool_interest_(self, clock);
        let max_amount_ = (max_amount as u256) * self.collateral_scale;

        let (collateral_amount, removed_lp) = lender::remove_max_collateral(&mut self.buckets, position, &mut self.deposit_state, max_amount_, index, clock);

        event::remove_collateral(object::id(position), index, collateral_amount, removed_lp);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, deposit::get_Lup(&self.deposit_state, pool_state.debt), clock);

        take_coins(collateral_amount, self.collateral_scale, &mut self.collateral_balance, ctx);

        update_position_(position, &self.buckets, index);
    }

    entry public fun remove_collateral_nft<Quote, Collateral:key + store>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        no_of_nft: u64,
        index: u64,
        clock:&Clock,
        ctx: &mut TxContext
    ){
        assert!(!self.pool_type, ERR_NOT_NFT_POOL);
        assert::check_auction_clearable(&self.auction_state, &self.loans_state, clock);

        let pool_state = accrue_pool_interest_(self, clock);

        let removed_lp = lender::remove_collateral(&mut self.buckets, position, &mut self.deposit_state, wad::wad((no_of_nft as u256)), index, clock);

        event::remove_collateral_nft(object::id(position), index, no_of_nft, removed_lp);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, deposit::get_Lup(&self.deposit_state, pool_state.debt), clock);

        withdraw_nft_from_pool<Collateral>(&mut self.collateral_nft, &mut self.claimable_nfts, no_of_nft, ctx);

        update_position_(position, &self.buckets, index);
    }

    entry public fun merge_or_remove_collateral<Quote,Collateral: key + store>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        from_indexes: vector<u64>,
        to_index: u64,
        no_of_nft: u64,
        clock:&Clock,
        ctx: &mut TxContext
    ){
        assert!(!self.pool_type, ERR_NOT_NFT_POOL);
        assert::check_auction_clearable(&self.auction_state, &self.loans_state, clock);

        let pool_state = accrue_pool_interest_(self, clock);
        let collateral_amount = wad::wad((no_of_nft as u256));

        let (collateral_to_merge, bucket_lp) = lender::merge_or_remove_collateral(&mut self.buckets, position, &mut self.deposit_state, collateral_amount, from_indexes, to_index, clock);

        event::merge_or_remove_collateral(object::id(position), collateral_to_merge, bucket_lp);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, deposit::get_Lup(&self.deposit_state, pool_state.debt), clock);

        if(collateral_to_merge == collateral_amount){
            // meet the required amount, thereby pay back
            withdraw_nft_from_pool<Collateral>(&mut self.collateral_nft, &mut self.claimable_nfts, no_of_nft, ctx);
        };

        let i = 0;
        vec::push_back(&mut from_indexes, to_index);
        while(i < vec::length(&from_indexes)){
            let index = vec::pop_back(&mut from_indexes);
            update_position_(position, &self.buckets, index);
        };
    }

    entry public fun update_interest<Quote,Collateral>(
        self: &mut Pool<Quote, Collateral>,
        clock: &Clock
    ){
        let pool_state = accrue_pool_interest_(self, clock);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, deposit::get_Lup(&self.deposit_state, pool_state.debt), clock);
    }

    // ======================== Borrower Entry ========================
    entry public fun draw_debt<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        amount_to_borrow: u64,
        limit_index: u64,
        collateral_to_pledge: Coin<Collateral>,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        assert!(self.pool_type, ERR_NOT_TOKEN_POOL);
        let borrower = tx_context::sender(ctx);

        let pool_state = accrue_pool_interest_(self, clock);

        // extend to WAD
        let amount_to_borrow = (amount_to_borrow as u256) * self.quote_scale;
        let value = (coin::value(&collateral_to_pledge) as u256) * self.collateral_scale;

        // new_draw_debt_action
        let params = borrower::new_draw_debt_params(available_quote_tokens(self), borrower, amount_to_borrow, limit_index, value, pool_state.pool_type, pool_state.inflator, pool_state.i_rate, pool_state.t0_debt, pool_state.debt, pool_state.collateral, pool_state.quote_token_scale);
        let (_new_Lup, _pool_collateral, _pool_debt, _remaining_collateral, _t0_pool_debt, _debt_pre_action, _debt_post_action, _collateral_pre_action, _collateral_post_action) = borrower::draw_debt_(&self.auction_state, &self.deposit_state, &mut self.loans_state, params);

        event::draw_debt(borrower, amount_to_borrow, value, _new_Lup);

        pool_state.debt = _pool_debt;
        pool_state.t0_debt = _t0_pool_debt;
        pool_state.collateral = _pool_collateral;

        // adjust t0Debt2ToCollateral ratio
        interest::update_t0_debt2_to_collaterl(&mut self.interest_state, _debt_pre_action, _debt_post_action, _collateral_pre_action, _collateral_post_action);

        // update pool interest rate state
        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, _new_Lup, clock);

        if(value != 0){
            // update pool balances pledged collateral state
            self.pool_balance_state.pledged_collateral = pool_state.collateral;
            // move collateral from sender to pool
            deposit_coins(value, self.collateral_scale, &mut self.collateral_balance, collateral_to_pledge, ctx);
        }else{
            coin::destroy_zero(collateral_to_pledge);
        };

        if(amount_to_borrow != 0){
            // update pool balances pledged collateral state
            self.pool_balance_state.t0_debt = pool_state.t0_debt;
            // move quote from pool to sender
            take_coins(amount_to_borrow, self.quote_scale, &mut self.quote_balance, ctx);
        };
    }

    entry public fun draw_debt_nft<Quote, Collateral: key + store>(
        self: &mut Pool<Quote, Collateral>,
        amount_to_borrow: u64,
        limit_index: u64,
        collateral_to_pledge: vector<Collateral>,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        assert!(!self.pool_type, ERR_NOT_NFT_POOL);

        let pool_state = accrue_pool_interest_(self, clock);
        let amount_to_borrow = (amount_to_borrow as u256) * self.quote_scale;
        let borrower = tx_context::sender(ctx);

        let len = vec::length(&collateral_to_pledge);

        // new_draw_debt_action
        let params = borrower::new_draw_debt_params(available_quote_tokens(self), borrower, amount_to_borrow, limit_index, wad::wad((len as u256)), pool_state.pool_type, pool_state.inflator, pool_state.i_rate, pool_state.t0_debt, pool_state.debt, pool_state.collateral, pool_state.quote_token_scale);
        let (_new_Lup, _pool_collateral, _pool_debt, _remaining_collateral, _t0_pool_debt, _debt_pre_action, _debt_post_action, _collateral_pre_action, _collateral_post_action) = borrower::draw_debt_(&self.auction_state, &self.deposit_state, &mut self.loans_state, params);

        pool_state.debt = _pool_debt;
        pool_state.t0_debt = _t0_pool_debt;
        pool_state.collateral = _pool_collateral;

        interest::update_t0_debt2_to_collaterl(&mut self.interest_state, _debt_pre_action, _debt_post_action, _collateral_pre_action, _collateral_post_action);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, _new_Lup, clock);

        if(len != 0){
            // update pool balances pledged collateral state
            self.pool_balance_state.pledged_collateral = pool_state.collateral;

            // move collateral from sender to pool
            let i = 0;
            let token_ids = vector<ID>[];
            while(i < len){
                let item = vec::pop_back(&mut collateral_to_pledge);
                let id = deposit_nft(&mut self.collateral_nft, item);
                vec::push_back(&mut token_ids, id);
                i = i + 1;
            };
            if(!table::contains(&mut self.borrower_nft_ids, borrower)){
                table::add(&mut self.borrower_nft_ids, borrower, token_ids);
            }else{
                let ids = table::borrow_mut(&mut self.borrower_nft_ids, borrower);
                vec::append(ids, token_ids);
            };
            event::draw_debt_nft(borrower, amount_to_borrow, token_ids, _new_Lup);
        };
        vec::destroy_empty(collateral_to_pledge);

        if(amount_to_borrow != 0){
            // update pool balances pledged collateral state
            self.pool_balance_state.t0_debt = pool_state.t0_debt;
            // move quote from pool to sender
            take_coins(amount_to_borrow, self.quote_scale, &mut self.quote_balance, ctx);
        };
    }

    public fun repay_debt<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        borrower_address: address,
        max_quote_amonut_to_pay: Coin<Quote>,
        collateral_amount_to_pull: u64,
        limit_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): u256{
        assert!(self.pool_type, ERR_NOT_TOKEN_POOL);

        let pool_state = accrue_pool_interest_(self, clock);

        let max_quote_amonut_to_pay_ = (coin::value(&max_quote_amonut_to_pay) as u256) * self.quote_scale;
        let collateral_amount_to_pull_ = (collateral_amount_to_pull as u256) * self.collateral_scale;

        let params = borrower::new_repay_debt_params(borrower_address, max_quote_amonut_to_pay_, collateral_amount_to_pull_, limit_index, pool_state.inflator, pool_state.quote_token_scale, pool_state.i_rate, pool_state.t0_debt, pool_state.debt, pool_state.collateral);

        let (
            newLup,
            poolCollateral,
            poolDebt,
            remainingCollateral,
            t0PoolDebt,
            quoteTokenToRepay,
            debtPreAction,
            debtPostAction,
            collateralPreAction,
            collateralPostAction
        ) = borrower::repay_debt(&mut self.auction_state, &mut self.deposit_state, &mut self.loans_state, params, ctx);

        event::repay_debt(borrower_address, quoteTokenToRepay, collateral_amount_to_pull_, newLup);

        // update in memory pool state struct
        pool_state.debt       = poolDebt;
        pool_state.t0_debt     = t0PoolDebt;
        pool_state.collateral = poolCollateral;

        // adjust t0Debt2ToCollateral ratio
        interest::update_t0_debt2_to_collaterl(&mut self.interest_state, debtPreAction, debtPostAction, collateralPreAction, collateralPostAction);

        // update pool interest rate state
        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, newLup, clock);

        if (quoteTokenToRepay != 0) {
            // update pool balances t0 debt state
            self.pool_balance_state.t0_debt = pool_state.t0_debt;

            // move amount to repay from sender to pool
            deposit_coins(quoteTokenToRepay, self.quote_scale, &mut self.quote_balance, max_quote_amonut_to_pay, ctx);
        }else{
            if(coin::value(&max_quote_amonut_to_pay) == 0){
                coin::destroy_zero(max_quote_amonut_to_pay);
            }else{
                transfer::public_transfer(max_quote_amonut_to_pay, tx_context::sender(ctx));
            };
        };

        if (collateral_amount_to_pull_ != 0) {
            // update pool balances pledged collateral state
            self.pool_balance_state.pledged_collateral = pool_state.collateral;
            // move collateral from pool to address specified as collateral receiver
            take_coins(collateral_amount_to_pull_, self.collateral_scale, &mut self.collateral_balance, ctx);
        };

        quoteTokenToRepay
    }

    public fun repay_debt_nft<Quote, Collateral:key + store>(
        self: &mut Pool<Quote, Collateral>,
        borrower_address: address,
        max_quote_amonut_to_pay: Coin<Quote>,
        amount_of_nft_to_pull: u64,
        limit_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): u256{
        assert!(!self.pool_type, ERR_NOT_TOKEN_POOL);

        let pool_state = accrue_pool_interest_(self, clock);

        let max_quote_amonut_to_pay_ = (coin::value(&max_quote_amonut_to_pay) as u256) * self.quote_scale;
        let collateral_amount_to_pull_ = (amount_of_nft_to_pull as u256) * 1000000000000000000;

        let params = borrower::new_repay_debt_params(borrower_address, max_quote_amonut_to_pay_, collateral_amount_to_pull_, limit_index, pool_state.inflator, pool_state.quote_token_scale, pool_state.i_rate, pool_state.t0_debt, pool_state.debt, pool_state.collateral);

        let (
            newLup,
            poolCollateral,
            poolDebt,
            remainingCollateral,
            t0PoolDebt,
            quoteTokenToRepay,
            debtPreAction,
            debtPostAction,
            collateralPreAction,
            collateralPostAction
        ) = borrower::repay_debt(&mut self.auction_state, &mut self.deposit_state, &mut self.loans_state, params, ctx);

        event::repay_debt(borrower_address, quoteTokenToRepay, collateral_amount_to_pull_, newLup);

        // update in memory pool state struct
        pool_state.debt       = poolDebt;
        pool_state.t0_debt     = t0PoolDebt;
        pool_state.collateral = poolCollateral;

        // adjust t0Debt2ToCollateral ratio
        interest::update_t0_debt2_to_collaterl(&mut self.interest_state, debtPreAction, debtPostAction, collateralPreAction, collateralPostAction);

        // update pool interest rate state
        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, newLup, clock);

        if (quoteTokenToRepay != 0) {
            // update pool balances t0 debt state
            self.pool_balance_state.t0_debt = pool_state.t0_debt;

            // move amount to repay from sender to pool
            deposit_coins(quoteTokenToRepay, self.quote_scale, &mut self.quote_balance, max_quote_amonut_to_pay, ctx);
        }else{
            // pay back
            transfer::public_transfer(max_quote_amonut_to_pay, tx_context::sender(ctx));
        };

        self.pool_balance_state.pledged_collateral = pool_state.collateral;
        if (amount_of_nft_to_pull != 0) {
            withdraw_nft_from_pool<Collateral>(&mut self.collateral_nft, table::borrow_mut(&mut self.borrower_nft_ids, tx_context::sender(ctx)),amount_of_nft_to_pull, ctx);
        };

        quoteTokenToRepay
    }


    entry public fun stamp_loan<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        clock: &Clock,
        ctx: &TxContext
    ){
        let pool_state = accrue_pool_interest_(self, clock);

        let new_lup = borrower::stamp_loan(&self.auction_state, &self.deposit_state, &mut self.loans_state, pool_state.pool_type, pool_state.inflator, pool_state.debt, pool_state.i_rate, ctx);

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, new_lup, clock);
    }

    // ======================== Kicker Entry ========================
    entry public fun kick<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        borrower: address,
        limit_index: u64,
        escrowed_bond_coin: Coin<Quote>,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        let pool_state = accrue_pool_interest_(self, clock);

        let (amonut_to_cover_bond, t0_kicked_debt, collateral_pre_action, lup) = kicker::kick_(&mut self.auction_state, &self.deposit_state, &mut self.loans_state, kicker::new_kick_params(borrower, limit_index, 0, pool_state.pool_type, pool_state.inflator, pool_state.debt), clock, ctx);

        pool_state.t0_debt_in_auction = pool_state.t0_debt_in_auction + t0_kicked_debt;

        interest::update_t0_debt2_to_collaterl(&mut self.interest_state, t0_kicked_debt,  0, collateral_pre_action, 0);

        // update pool_balance
        self.pool_balance_state.t0_debt_in_auction = pool_state.t0_debt_in_auction;

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, lup, clock);

        if(((coin::value(&escrowed_bond_coin) as u256) * self.quote_scale) < amonut_to_cover_bond) abort ERR_INSUFFICIENT_ESCROWED_BOND;

        deposit_coins(amonut_to_cover_bond, self.quote_scale, &mut self.quote_balance, escrowed_bond_coin, ctx);
    }

    entry public fun lender_kick<Quote, Collateral>(
        self:&mut Pool<Quote, Collateral>,
        position: &Position,
        quote: Coin<Quote>,
        index: u64,
        np_limit_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        let pool_state = accrue_pool_interest_(self, clock);

        let params = kicker::new_kick_params(loans::loan_borower(&loans::get_max(&self.loans_state)), np_limit_index, 0, pool_state.pool_type, pool_state.inflator, pool_state.debt);
        let (amonut_to_cover_bond, t0_kicked_debt, collateral_pre_action, lup) = kicker::lender_kick(&mut self.auction_state, &self.deposit_state, &self.buckets, &mut self.loans_state, position, params, index, clock , ctx);

        pool_state.t0_debt_in_auction = pool_state.t0_debt_in_auction + t0_kicked_debt;

        interest::update_t0_debt2_to_collaterl(&mut self.interest_state, t0_kicked_debt,  0, collateral_pre_action, 0);

        // update pool_balance
        self.pool_balance_state.t0_debt_in_auction = pool_state.t0_debt_in_auction;

        update_interst_state_(&mut self.interest_state, &mut self.ema_state, &self.deposit_state, &pool_state, &mut self.inflator_state, lup, clock);

        if(amonut_to_cover_bond != 0){
            deposit_coins(amonut_to_cover_bond, self.quote_scale, &mut self.quote_balance, quote, ctx);
        }else{
            transfer::public_transfer(quote, tx_context::sender(ctx));
        };
    }

    // Withdraw bonds and claim the LP token in position NFT
    entry public fun kicker_claim_rewards<Quote,Collateral>(
        self: &mut Pool<Quote, Collateral>,
        position: &mut Position,
        max_amount: u256,
        ctx: &mut TxContext
    ){
        assert!(position::pool(position) == object::id(self), ERR_INCORRECT_POSITION);
        let kicker_address = tx_context::sender(ctx);
        let position_id = object::id(position);
        let claimable = kicker_claimable(self, kicker_address);

        let max_amount = wad::min(max_amount, claimable);

        if(max_amount == 0) abort ERR_INSUFFICIENT_LIQUIDITY;

        auction::remove_total_bond_escrowed(&mut self.auction_state, max_amount);
        let kicker = auction::kicker_mut(&mut self.auction_state, kicker_address);
        auction::remove_claimable(kicker, max_amount);

        // update lender value of kicker
        let (indexes, lenders) = auction::drop_lenders(kicker);
        let (i, len) = (0, vec::length(&indexes));
        while(i < len){
            // update bucker lender
            let (index, from_lender) = (vec::pop_back(&mut indexes), vec::pop_back(&mut lenders));
            let bucket = table::borrow_mut(&mut self.buckets, index);
            if(!bucket::is_lender(bucket, position_id)) table::add(bucket::lenders_mut(bucket), position_id, bucket::default_lender());

            let bankruptcy_time = bucket::bankruptcy_time(bucket);
            let to_lender = bucket::lender_mut(bucket, position_id);
            bucket::transfer_lender_lps(from_lender, to_lender, bankruptcy_time);

            // update position nft
            position::update_position(position, index, *to_lender);

            i = i + 1;
        };

        event::bond_withdrawn(kicker_address, max_amount);

        take_coins(max_amount, self.quote_scale, &mut self.quote_balance, ctx);
    }

    /// Update pool's debt by latest inflator and accrue underlying interests above LUP
    /// calcualte the new inflator by elapsed times and scaled the Fenwick tree value
    fun accrue_pool_interest_<Quote, Collateral>(
        self: &mut Pool<Quote, Collateral>,
        clock: &Clock
    ): PoolStateArg{
        let pool_state_arg = default_pool_state(self);

        if(pool_state_arg.t0_debt != 0){
            pool_state_arg.debt = wad::wmul(pool_state_arg.t0_debt, pool_state_arg.inflator);

            let elapsed = time::get_sec(clock) - interest::inflator_last_update(&self.inflator_state);
            pool_state_arg.is_new_interest_accrued = elapsed != 0;

            // if new interest may have accrued, call accrueInterest function and update inflator and debt fields of poolState_ struct
            if(pool_state_arg.is_new_interest_accrued){
                let pending_factor = ud60x18::exp(pool_state_arg.i_rate * (elapsed as u256) / (365 * time::days() as u256));

                let new_inflator = wad::wmul(pending_factor, pool_state_arg.inflator);
                let new_accrued_interest = 0_u256;
                let htp = wad::wmul(loans::loan_threshold_price(&loans::get_max(&mut self.loans_state)), pool_state_arg.inflator);

                let _accrua_index = 0_u64;
                if(htp > constants::max_price()){
                    _accrua_index = 1
                }else if(htp < constants::min_price()){
                    _accrua_index = constants::max_fenwick_index();
                }else{
                    _accrua_index = helpers::index_of(htp);
                };

                let lup_index = deposit::find_index_of_sum(&mut self.deposit_state, pool_state_arg.debt);
                // When LUP < HTP, any deposit above LUP can still earn the interest
                if (lup_index > _accrua_index) _accrua_index = lup_index;

                let interest_earning_deposit = deposit::prefix_sum(&mut self.deposit_state, _accrua_index);

                if(interest_earning_deposit != 0){
                    // new_accrued_interest = NIM * ((pending_factor - 1) * debt)
                    // we calculte the diff btw previous debt and latest debt instead of dealing with debt_0
                    new_accrued_interest = wad::wmul(lender_interest_margin_(ema::utilization(&self.ema_state)), wad::wmul(pending_factor - constants::UNIT(), pool_state_arg.debt));

                    // lender factor computation, capped at 10x the interest factor for borrowers
                    // factor = min((new_accrued_interest / interest_earning_deposit), (pending_factor - 1) * 10) + 1
                    let lender_factor = wad::min(
                        wad::floorWdiv(new_accrued_interest, interest_earning_deposit),
                        wad::wmul(pending_factor - constants::UNIT(), wad::wad(10))
                    ) + constants::UNIT();

                    // Scale the fenwick tree to update amount of debt owed to lenders
                    deposit::mult(&mut self.deposit_state, _accrua_index, lender_factor);
                };

                pool_state_arg.inflator = new_inflator;
                pool_state_arg.debt = wad::wmul(pool_state_arg.t0_debt, new_inflator);

                // update total interest earned accumulator in pool reserve with the newly accrued interest
                //reserve_auction::add_total_interest_earned(&mut self.reserve_auction_state, new_accrued_interest);
            };
        };

        pool_state_arg
    }

    fun calculate_interest_rate(
        pool_state_arg: &PoolStateArg,
        debt_ema: u256,
        deposit_ema: u256,
        debt_col_ema: u256,
        lup_t0_debt_ema: u256,
    ):u256{
        // meaningful actual utilization
        let mau = int::zero();
        // meaningful actual utilization * 1.02
        let mau102 = int::zero();

        if(pool_state_arg.debt != 0){
            // calculate meaningful actual utilization for interest rate update
            mau = int::from_u256(ema::utilization_(debt_ema, deposit_ema));
            mau102 = int::div(&int::mul(&mau, &constants::PERCENT_102()), &int::from_u256(constants::UNIT()));
        };

        let tu = if(lup_t0_debt_ema != 0) int::from_u256(wad::wdiv(debt_col_ema, lup_t0_debt_ema)) else int::from_u256(constants::UNIT());

        let new_interest_rate = pool_state_arg.i_rate;
        // raise rates if 4*(tu-1.02*mau) < (tu+1.02*mau-1)^2-1
        if(int::lt(&int::mul(&int::from_u256(4), &int::sub(&tu, &mau102)), &int::sub(&int::mul(&int::div(&int::sub(&int::add(&tu, &mau102), &int::from_u256(1000000000000000000)),&int::from_u256(1000000000)),&int::div(&int::sub(&int::add(&tu, &mau102), &int::from_u256(1000000000000000000)),&int::from_u256(1000000000))), &int::from_u256(1000000000000000000)))){
            new_interest_rate = wad::wmul(pool_state_arg.i_rate, constants::INCREASE_COEFFICIENT());
        }else if(int::gt(&int::mul(&int::from_u256(4), &int::sub(&tu, &mau)), &int::sub(&int::from_u256(1000000000000000000), &int::mul(&int::div(&int::sub(&int::add(&tu, &mau), &int::from_u256(1000000000000000000)),&int::from_u256(1000000000)), &int::div(&int::sub(&int::add(&tu, &mau), &int::from_u256(1000000000000000000)),&int::from_u256(1000000000)))))){
            new_interest_rate = wad::wmul(pool_state_arg.i_rate, constants::DECREASE_COEFFICIENT());
        };

        // bound rates between 10 bps and 400%
        wad::min(4_000_000_000_000_000_000, wad::max(1_000_000_000_000_000, new_interest_rate))
    }

    // Update EmaState, InterestState, InflatorState when there's debt accumulating the interest fees
    fun update_interst_state_(
        interest_state: &mut InterestState,
        ema_state: &mut EmaState,
        deposit_state: &DepositState,
        pool_state_arg: &PoolStateArg,
        inflator_state: &mut InflatorState,
        lup: u256,
        clock: &Clock
    ){
        // ema state
        let (debt_ema, deposit_ema, debt_col_ema, lup_t0_debt_ema, ema_update) = ema::ema_state(ema_state);

        let (_, i_rate_last_update, debt, meaningful_deposit, t0_debt2_to_collateral, debt_col, lup_t0_debt) = interest::interest_state(interest_state);

        // calculate new interest params
        let non_auctioned_t0_debt = pool_state_arg.t0_debt - pool_state_arg.t0_debt_in_auction;
        // exclude the debt in auction
        let new_debt = wad::wmul(non_auctioned_t0_debt, pool_state_arg.inflator);
        // new meaningful deposit cannot be less than pool's debt
        let new_meaningful_deposit = wad::max(meaningful_deposit_(deposit_state,pool_state_arg.t0_debt_in_auction, non_auctioned_t0_debt, pool_state_arg.inflator, t0_debt2_to_collateral), new_debt);

        let new_debt_col = wad::wmul(pool_state_arg.inflator, t0_debt2_to_collateral);
        let new_Lup_t0_debt = wad::wmul(lup, non_auctioned_t0_debt);

        let _elapsed = int::zero();
        let _weight_mau = int::zero();
        let _weight_tu = int::zero();
        let _new_interest_rate = 0_u256;

        // update EMAs only once per block ( use previous interst information )
        if(ema_update != time::get_sec(clock)){
            // first time EMAs are updated, initialize EMAs
            if(ema_update == 0){
                debt_ema = new_debt;
                deposit_ema = new_meaningful_deposit;
                debt_col_ema = new_debt_col;
                lup_t0_debt_ema = new_Lup_t0_debt;
            }else{
                _elapsed = int::from_u256(wad::wdiv(((time::get_sec(clock) - ema_update) as u256), (time::hours() as u256)));
                // MAU is more responsive the latest price as we set smooth facor
                // -ln(2)/12 for MAU and -ln(2)/84 for TU
                _weight_mau = sd59x18::exp(sd59x18::mul(constants::NEG_H_MAU_HOURS(), _elapsed));
                _weight_tu = sd59x18::exp(sd59x18::mul(constants::NEG_H_TU_HOURS(), _elapsed));
                // calculate the debt EMA, used for MAU ( this debt didn't count current action's debt )
                debt_ema = int::as_u256(&int::add(&sd59x18::mul(_weight_mau, int::from_u256(debt_ema)), &sd59x18::mul(int::sub(&int::from_u256(constants::UNIT()), &_weight_mau), int::from_u256(debt))));
                // update the meaningful deposit EMA, used for MAU ( calculated by previous menaingful_deposit )
                deposit_ema = int::as_u256(&int::add(&sd59x18::mul(_weight_mau, int::from_u256(deposit_ema)), &sd59x18::mul(int::sub(&int::from_u256(constants::UNIT()), &_weight_mau), int::from_u256(meaningful_deposit))));
                // calculate the debt squared to collateral EMA, used for TU
                debt_col_ema = int::as_u256(&int::add(&sd59x18::mul(_weight_tu, int::from_u256(debt_col_ema)), &sd59x18::mul(int::sub(&int::from_u256(constants::UNIT()), &_weight_tu), int::from_u256(debt_col))));
                // calculate the EMA of LUP * t0 debt
                lup_t0_debt_ema = int::as_u256(&int::add(&sd59x18::mul(_weight_tu, int::from_u256(lup_t0_debt_ema)), &sd59x18::mul(int::sub(&int::from_u256(constants::UNIT()), &_weight_tu), int::from_u256(lup_t0_debt))));
            };
        };

        // EMA state update
        ema::update_debt_ema(ema_state, debt_ema);
        ema::update_deposit_ema(ema_state, deposit_ema);
        ema::update_debt_col_ema(ema_state, debt_col_ema);
        ema::update_lup_t0_debt_ema(ema_state, lup_t0_debt_ema);
        ema::update_ema_update(ema_state, time::get_sec(clock));

        // reset interest rate if pool rate > 10% and debtEma < 5% of depositEma
        if(pool_state_arg.i_rate > 100_000_000_000_000_000 && debt_ema < wad::wmul(deposit_ema, 50_000_000_000_000_000)){
            interest::update_interest_rate(interest_state, 100_000_000_000_000_000);
            interest::update_i_rate_last_update(interest_state, time::get_sec(clock));

            event::reset_interest_rate(pool_state_arg.i_rate, 100000000000000000)
        }// otherwise calculate and update interest rate if it has been more than 12 hours since the last update
        else if(time::get_sec(clock) - i_rate_last_update > 12 * time::hours()){
            _new_interest_rate = calculate_interest_rate(pool_state_arg, debt_ema, deposit_ema, debt_col_ema, lup_t0_debt_ema);

            if(pool_state_arg.i_rate != _new_interest_rate){
                interest::update_interest_rate(interest_state, _new_interest_rate);
                interest::update_i_rate_last_update(interest_state, time::get_sec(clock));

                event::update_interest_rate(pool_state_arg.i_rate, _new_interest_rate);
            };
        };
        interest::update_debt(interest_state, new_debt);
        interest::update_meaningful_deposit(interest_state, new_meaningful_deposit);
        interest::update_debt_col(interest_state, new_debt_col);
        interest::update_lup_t0_debt(interest_state, new_Lup_t0_debt);

        //update pool inflator
        if(pool_state_arg.is_new_interest_accrued){
            interest::update_inflator(inflator_state, pool_state_arg.inflator);
            interest::update_inflator_last_update(inflator_state, time::get_sec(clock));
        }else if(pool_state_arg.debt == 0){
            // reset the interest rate
            interest::update_inflator(inflator_state, constants::UNIT());
            interest::update_inflator_last_update(inflator_state, time::get_sec(clock));
        };
    }

    fun update_post_take_state(
        pool_state: &mut PoolStateArg,
        interest_state: &mut InterestState,
        pool_balance_state: &mut PoolBalanceState,
        ema_state: &mut EmaState,
        deposit_state: &DepositState,
        inflator_state: &mut InflatorState,
        pool_debt: u256,
        t0_pool_debt: u256,
        t0_debt_in_auction_change: u256,
        collateral_amount: u256,
        compensated_collateral: u256,
        settled_auction: bool,
        debt_post_action: u256,
        collateral_post_action: u256,
        new_Lup: u256,
        clock: &Clock
    ){
        pool_state.debt = pool_debt;
        pool_state.t0_debt = t0_pool_debt;
        pool_state.t0_debt_in_auction = pool_state.t0_debt_in_auction - t0_debt_in_auction_change;
        pool_state.collateral = pool_state.collateral - collateral_amount - compensated_collateral;

        // adjust t0Debt2ToCollateral ratio if auction settled by take action
        if (settled_auction) {
            interest::update_t0_debt2_to_collaterl(
                interest_state,
                0, // debt pre take (for loan in auction) not taken into account
                debt_post_action,
                0, // collateral pre take (for loan in auction) not taken into account
                collateral_post_action,
            );
        };

        // update pool balances state
        pool_balance_state.t0_debt            = pool_state.t0_debt;
        pool_balance_state.t0_debt_in_auction   = pool_state.t0_debt_in_auction;
        pool_balance_state.pledged_collateral = pool_state.collateral;

        // update pool interest rate state
        update_interst_state_(interest_state, ema_state, deposit_state, pool_state, inflator_state, new_Lup, clock);
    }

    fun update_post_settle_state(
        interest_state: &mut InterestState,
        ema_state: &mut EmaState,
        deposit_state: &DepositState,
        inflator_state: &mut InflatorState,
        pool_balance: &mut PoolBalanceState,
        pool_state: &mut PoolStateArg,
        collateral_settled: u256,
        t0_debt_settled: u256,
        clock: &Clock
    ){
        // update in memory pool state struct
        pool_state.debt = pool_state.debt - wad::wmul(t0_debt_settled, pool_state.inflator);
        pool_state.t0_debt = pool_state.t0_debt - t0_debt_settled;
        pool_state.t0_debt_in_auction = pool_state.t0_debt_in_auction - t0_debt_settled;
        pool_state.collateral = pool_state.collateral - collateral_settled;

        // update pool balances state
        pool_balance.t0_debt = pool_state.t0_debt;
        pool_balance.t0_debt_in_auction = pool_state.t0_debt_in_auction;
        pool_balance.pledged_collateral = pool_state.collateral;

        // update pool interest rate state
        let lup = deposit::get_Lup(deposit_state, pool_state.debt);
        update_interst_state_(interest_state, ema_state, deposit_state, pool_state, inflator_state, lup, clock);
    }

    /// put liquidated NFT to claimable pool
    fun rebalance_tokens_(
        borrower_nft_ids: &mut Table<address, vector<ID>>,
        claimable_nfts: &mut vector<ID>,
        borrower_address: address,
        borrower_collateral: u256
    ){
        let nft_ids = table::borrow_mut(borrower_nft_ids, borrower_address);

        let len = vec::length(nft_ids);
         /*
            eg1. borrowerCollateral_ = 4.1, noOfTokensPledged = 6; noOfTokensToTransfer = 1
            eg2. borrowerCollateral_ = 4, noOfTokensPledged = 6; noOfTokensToTransfer = 2
        */
        let collateral_roundup = (borrower_collateral + 1000000000000000000 - 1)/ 1000000000000000000;
        let num_transfer = len - (collateral_roundup as u64);
        let i = 0;
        while(i < num_transfer){
            let id = vec::pop_back(nft_ids);
            vec::push_back(claimable_nfts, id);
            i = i + 1;
        };
    }

    // ================ Utils ================

    // Lender Interest Margin = 1 - NIM
    public fun lender_interest_margin_(mau: u256): u256{
        // Net Interest Margin = ((1 - MAU1) * s)^(1/3) / s^(1/3) * 0.15
        let base = 1_000_000 * constants::UNIT() - u256_common::min(mau, constants::UNIT()) * 1_000_000;
        // If MAU > 99.9999%, lenders get 100% of interest.
        if (base < constants::UNIT()) {
            return constants::UNIT()
        } else {
            let crpud = ud60x18::pow(base, ONE_THIRD);
             // Lender Interest Margin = 1 - Net Interest Margin
            return constants::UNIT() - wad::wdiv(wad::wmul(crpud, 150_000_000_000_000_000), CUBIC_ROOT_1000000)
        }
    }

    public fun encumberance_(debt: u256, price: u256):u256{
        if(price != 0 && debt != 0) wad::wdiv(debt, price) else 0
    }

    public fun collateralization_(debt: u256, collateral: u256, price: u256):u256{
        let encumbered = encumberance_(debt, price);
        if(encumbered != 0) wad::wdiv(collateral, encumbered) else WAD
    }

// Amount of deposit above pool's debt weighted threshold price
    public fun meaningful_deposit_(
        deposit_state: &DepositState,
        t0_debt_in_auction: u256,
        non_auctioned_t0_debt: u256,
        inflator: u256,
        t0_debt2_to_collateral: u256
    ): u256{
        let _meaningful_deposit = 0;
        let dwatp = helpers::dwatp(non_auctioned_t0_debt, inflator, t0_debt2_to_collateral);
        if(dwatp == 0){
            // no debt, therefore all deposit is meaningful deposit
            _meaningful_deposit = deposit::tree_sum(deposit_state);
        }else{
            _meaningful_deposit = if(dwatp >= constants::max_price()){
                0
            }else if(dwatp >= constants::min_price()){
                //amount of deposit above the pool's threshold price
                deposit::prefix_sum(deposit_state, helpers::index_of(dwatp))
            }else{
                deposit::tree_sum(deposit_state)
            };
        };
        _meaningful_deposit - wad::min(_meaningful_deposit, wad::wmul(t0_debt_in_auction, inflator))
    }

    fun available_quote_tokens<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        let normalized_quote_balance = get_normalized_quote_balance(self);
        let escrowed_amount = auction::total_bond_escrowed(&self.auction_state);

        if(normalized_quote_balance > escrowed_amount) normalized_quote_balance - escrowed_amount else 0
    }

    fun get_normalized_quote_balance<Quote, Collateral>(self: &Pool<Quote, Collateral>):u256{
        (balance::value(&self.quote_balance) as u256) * self.quote_scale
    }

    fun update_position_<Collateral>(
        position: &mut Position,
        buckets: &Table<u64, Bucket<Collateral>>,
        index: u64
    ){
        let bucket = table::borrow(buckets, index);
        let lender = bucket::try_lender(bucket, object::id(position));
        if(option::is_some(&lender)){
            position::update_position(position, index, option::destroy_some(lender));
        }else{
            option::destroy_none(lender);
            position::drop_position(position, index);
        };
    }

    fun deposit_coins<T>(
        amount: u256,
        scale:u256,
        balance: &mut Balance<T>,
        coin: Coin<T>,
        ctx: &mut TxContext
    ){
        let transfer_amount = (wad::ceilDiv(amount, scale) as u64);
        if(transfer_amount == coin::value(&coin)){
            coin::put(balance, coin);
        }else{
            let coin_ = coin::split(&mut coin, (transfer_amount as u64), ctx);
            coin::put(balance, coin_);
            transfer::public_transfer(coin, tx_context::sender(ctx))
        }
    }

    fun take_coins<T>(
        amount: u256,
        scale:u256,
        balance: &mut Balance<T>,
        ctx: &mut TxContext
    ){
        let transfer_amount = (wad::ceilDiv(amount, scale) as u64);
        let coin = coin::take(balance, transfer_amount, ctx);
        transfer::public_transfer(coin, tx_context::sender(ctx))
    }

    fun deposit_nft<T: store + key>(
        ob: &mut ObjectBag,
        item: T
    ):ID{
        let id = object::id(&item);
        object_bag::add(ob, id, item);
        id
    }

    fun withdraw_nft_from_pool<Collateral: store + key>(
        ob: &mut ObjectBag,
        // the nft owned by either borrower or pools
        token_ids: &mut vector<ID>,
        no_to_claims: u64,
        ctx: &TxContext
    ){
        let i = 0 ;

        while( i < no_to_claims){
            let key = vec::pop_back(token_ids);
            transfer::public_transfer(object_bag::remove<ID,Collateral>(ob, key), tx_context::sender(ctx));
            i = i + 1;
        };
    }
}