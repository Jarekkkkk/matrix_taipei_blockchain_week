module protocol::bucket{
    use std::option::{Self, Option};

    use sui::table::{Self, Table};
    use sui::clock::Clock;
    use sui::object::ID;

    use protocol::constants;
    use protocol::time;

    use math::mathu256;
    use math::wad;

    friend protocol::pool;
    friend protocol::lender;
    friend protocol::auction;

    const ERR_BUCKET_BANKRUPTCY_BLOCK:u64 = 101;
    const ERR_DROP_NON_ZERO_LP: u64 = 102;

    struct Bucket<phantom Collateral> has store{
        // [WAD] Bucket LP accumulator
        lps:u256,
        // [WAD] Available collateral tokens deposited in the bucket
        collateral: u256,
        // [TS] Timestamp when bucket become insolvent, 0 if healthy
        bankruptcy_time: u64,
        lenders: Table<ID, Lender>
    }

    public(friend) fun new<Collateral>(ctx: &mut sui::tx_context::TxContext):Bucket<Collateral>{
         Bucket<Collateral>{
            lps:0,
            collateral: 0,
            bankruptcy_time: 0,
            lenders: table::new<ID, Lender>(ctx)
        }
    }

    // [VIEW]
    public fun bankruptcy_time<Collateral>(self: &Bucket<Collateral>): u64 { self.bankruptcy_time }

    public fun collateral<Collateral>(self: &Bucket<Collateral>): u256 { self.collateral }

    public fun lps<Collateral>(self: &Bucket<Collateral>):u256{
        self.lps
    }
    public fun lender<Collateral>(self: &Bucket<Collateral>, lender: ID):&Lender{
        table::borrow(&self.lenders, lender)
    }
    public fun is_lender<Collateral>(self: &Bucket<Collateral>, lender: ID):bool { table::contains(&self.lenders, lender) }

    // [MUT]
    public(friend) fun lenders_mut<Collateral>(self: &mut Bucket<Collateral>):&mut Table<ID, Lender>{
        &mut self.lenders
    }
    public(friend) fun lender_mut<Collateral>(self: &mut Bucket<Collateral>, lender: ID):&mut Lender{
        table::borrow_mut(&mut self.lenders, lender)
    }
    public(friend) fun try_lender<Collateral>(self: &Bucket<Collateral>, lender: ID):Option<Lender>{
        if(table::contains(&self.lenders, lender)){
            option::some(*table::borrow(&self.lenders, lender))
        }else{
            option::none<Lender>()
        }
    }
    public(friend) fun add_lps<Collateral>(self: &mut Bucket<Collateral>, value: u256){
        self.lps = self.lps + value;
    }
    public(friend) fun remove_lps<Collateral>(self: &mut Bucket<Collateral>, value: u256){
        self.lps = self.lps - value;
    }
    public(friend) fun update_lps<Collateral>(self: &mut Bucket<Collateral>, value: u256){
        self.lps = value;
    }
    public(friend) fun add_collateral<Collateral>(self: &mut Bucket<Collateral>, value: u256){
        self.collateral = self.collateral + value;
    }
    public(friend) fun remove_collateral<Collateral>(self: &mut Bucket<Collateral>, value: u256){
        self.collateral = self.collateral - value;
    }
    public(friend) fun update_collateral<Collateral>(self: &mut Bucket<Collateral>, value: u256){
        self.collateral = value;
    }
    public(friend) fun update_bankruptcy_time<Collateral>(self: &mut Bucket<Collateral>, value: u64){
        self.bankruptcy_time = value;
    }

    // Lender
    struct Lender has copy, store, drop{
        //pool_id: ID,
        // [WAD] Lender LP accumulator
        lps: u256,
        // [TS] timestamp of last deposit
        deposit_time: u64
    }
    public fun lender_lps(lender: &Lender):u256{ lender.lps }
    public fun lender_deposit_time(lender: &Lender):u64{ lender.deposit_time }

    public(friend) fun add_lender_lps(lender: &mut Lender, value: u256){
        lender.lps = lender.lps + value;
    }
    public(friend) fun remove_lender_lps(lender: &mut Lender, value: u256){
        lender.lps = lender.lps - value;
    }
    public(friend) fun update_lender_lps(lender: &mut Lender, value: u256){
        lender.lps = value;
    }
    public(friend) fun update_deposit_time(lender: &mut Lender, value: u64){
        lender.deposit_time = value;
    }

    public (friend) fun default_lender():Lender{
        Lender{
            lps: 0,
            deposit_time: 0
        }
    }
    // TODO: remove zero lps or bankruptcy position
    public(friend) fun drop_lender_if_zero_lps<Collateral>(bucket: &mut Bucket<Collateral>, lender: ID){
        let lender_ = lender(bucket, lender);
        if(lender_.lps == 0){
            table::remove(&mut bucket.lenders, lender);
        };
    }

     public (friend) fun add_collateral_<Collateral>(
        bucket: &mut Bucket<Collateral>,
        lender: ID,
        deposit: u256,
        collateral_amount_to_add: u256,
        bucket_price: u256,
        clock: &Clock
     ):u256{
        let bankruptcy_time = bucket.bankruptcy_time;
        if(bankruptcy_time == time::get_sec(clock)) abort ERR_BUCKET_BANKRUPTCY_BLOCK;

        // calculate amount of LP to be added for the amount of collateral added to bucket
        let added_lp = collateral_to_LP(bucket, deposit, collateral_amount_to_add, bucket_price, false);
        // update bucket collateral
        bucket.collateral = bucket.collateral + collateral_amount_to_add;
        // update bucket and lender LP balance and deposit timestamp
        bucket.lps = bucket.lps + added_lp;

        if(!is_lender(bucket, lender)) table::add(lenders_mut(bucket), lender, default_lender());
        add_lender_lp(lender_mut(bucket, lender), bankruptcy_time, added_lp, clock);

        added_lp
     }

    public fun quote_token_to_LP(
        bucket_collateral: u256,
        bucket_lp: u256,
        deposit: u256,
        quote_tokens: u256,
        bucket_price: u256,
        rounding_up: bool
    ): u256{
        // case when there's no deposit nor collateral in bucket
        if(deposit == 0 && bucket_collateral == 0) return quote_tokens;
        // case when there's deposit or collateral in bucket but no LP to cover
        if(bucket_lp == 0) return quote_tokens;
        // case when there's deposit or collateral and bucket has LP balance
        mathu256::mul_div_rounding(bucket_lp, quote_tokens * constants::UNIT(), deposit * constants::UNIT() + bucket_collateral * bucket_price, rounding_up)
    }

    public(friend) fun add_lender_lp(
        lender: &mut Lender,
        bankruptcy_time: u64,
        lp_amount: u256,
        clock: &Clock
    ){
        if(lp_amount != 0){
            if(bankruptcy_time >= lender.deposit_time) lender.lps = lp_amount else add_lender_lps(lender, lp_amount);

            lender.deposit_time = time::get_sec(clock)
        };
    }

    public(friend) fun transfer_lender_lps(from: Lender, to: &mut Lender, bankruptcy_time: u64){
        if(bankruptcy_time > from.deposit_time) from.lps = 0;
        if(bankruptcy_time > to.deposit_time) to.lps = 0;

        to.lps = to.lps + from.lps;
        to.deposit_time = sui::math::max(from.deposit_time, to.deposit_time);
    }

     public fun collateral_to_LP<Collateral>(
        bucket: &Bucket<Collateral>,
        // quote balance in bucket
        quote: u256,
        // The amount of collateral to calculate bucket LP for
        collateral: u256,
        bucket_price: u256,
        rounding_up: bool
     ):u256{
        let bucket_collateral = bucket.collateral;
        let bucket_lp = bucket.lps;
        // case when there's no deposit nor collateral in bucket
        if(quote == 0 && bucket_collateral == 0) return wad::wmul(collateral, bucket_price);
        // case when there's deposit or collateral in bucket but no LP to cover
        if(bucket_lp == 0) return wad::wmul(collateral, bucket_price);
        // case when there's deposit or collateral and bucket has LP balance
        mathu256::mul_div_rounding(bucket_lp, collateral * bucket_price, quote * wad::wad(1) + bucket_collateral * bucket_price, rounding_up)
     }

     public fun get_exchange_rate<Collateral>(
        self: &Bucket<Collateral>,
        deposit: u256,
        bucket_price: u256,
     ):u256{
        LP_to_quote_token(self.collateral, self.lps, deposit, wad::wad(1), bucket_price, true)
     }

    public fun LP_to_quote_token(
        bucket_collateral: u256,
        bucket_lp: u256,
        deposit: u256,
        lp: u256,
        bucket_price: u256,
        rounding_up: bool
    ): u256{
        // case when there's no deposit nor collateral in bucket
        if(deposit == 0 && bucket_collateral == 0) return lp;
        // case when there's deposit or collateral in bucket but no LP to cover
        if(bucket_lp == 0) return lp;
        // case when there's deposit or collateral and bucket has LP balance
        mathu256::mul_div_rounding(deposit * wad::wad(1) + bucket_collateral * bucket_price, lp, bucket_lp * wad::wad(1), rounding_up)
    }
}