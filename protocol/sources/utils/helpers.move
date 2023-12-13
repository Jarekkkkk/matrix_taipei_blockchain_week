module protocol::helpers{
    use sui::clock::Clock;

    use math::int::{Self, Int};
    use math::wad;
    use math::u256_common;
    use math::sd59x18;

    use protocol::constants;
    use protocol::time;

    const RAY: u256 = 1000000000000000000000000000;
    const MINUTE_HALF_LIFT: u256 = 0_988514020352896135_356867505;
    const WAD_RAY_RATIO: u256 = 1_000000000;

    const BUCKET_PRICE_OUT_OF_BOUNDS: u64 = 1;

    public fun uFLOAT_STEP_INT():Int {
        int::from_u256(1_005_000_000_000_000_000)
    }

    public fun MAX_FENWICK_INDEX(): u64 { 7_388 }

    public fun MAX_BUCKET_INDEX(): Int{
        int::from_u256(4_156)
    }

    public fun MIN_BUCKET_INDEX(): Int{
        int::neg_from_u256(3_232)
    }

    public fun DEPOSIT_BUFFER(): u256{
        1_000000001000000000
    }

     public fun price_at(index: u64):u256{
        let bucket_index = int::sub(&MAX_BUCKET_INDEX(), &int::from_u256((index as u256)));
        if(int::lt(&bucket_index, &MIN_BUCKET_INDEX()) || int::gt(&bucket_index, &MAX_BUCKET_INDEX())) abort BUCKET_PRICE_OUT_OF_BOUNDS;

        int::as_u256(&sd59x18::exp2(sd59x18::mul(sd59x18::from_int(bucket_index), sd59x18::log2(uFLOAT_STEP_INT()))))
     }

    public fun index_of(price_: u256):u64 {
        if (price_ < constants::min_price() || price_ > constants::max_price()) abort BUCKET_PRICE_OUT_OF_BOUNDS;

        // index[WAD]
        let index = sd59x18::div(
            sd59x18::log2(int::from_u256(price_)),
            sd59x18::log2(uFLOAT_STEP_INT())
        );

        let ceil_index = sd59x18::ceil(index);
        if(int::lt(&index, &int::zero()) && int::gt(&int::sub(&ceil_index, &index), &int::from_u256(500_000_000_000_000_000))){
            (int::as_u256(&int::sub(&int::from_u256(4157), &sd59x18::to_int(ceil_index))) as u64)
            //((4157 - int::as_u256(&sd59x18::to_int(ceil_index))) as u64)
        }else{
            (int::as_u256(&int::sub(&int::from_u256(4156), &sd59x18::to_int(ceil_index))) as u64)
            //((4156 - int::as_u256(&sd59x18::to_int(ceil_index))) as u64)
        }
    }

    public fun min_debt_amount(debt: u256, loans_length: u64): u256{
        if(loans_length != 0) wad::wdiv(wad::wdiv(debt, wad::wad((loans_length as u256))), 10000000000000000000) else 0
    }

    public fun round_to_scale(
        amount: u256,
        token_scale: u256
    ): u256{
        ( amount / token_scale ) * token_scale
    }

    public fun round_up_to_scale(
        amount: u256,
        token_scale: u256
    ):u256{
        if(amount % token_scale == 0){
            return amount
        }else{
            round_to_scale(amount, token_scale) + token_scale
        }
    }

    /// Origination Fee; Max(rate_borrow/ 52, 0.005)
    public fun borrow_fee_rate(interest_rate: u256):u256{
        wad::max(wad::wdiv(interest_rate, 52 * 1000000000000000000), 500_000_000_000_000)
    }

    // Deposit penalty: current annualized rate divided by 365 (24 hours of interest), capped at 10%
    public fun deposit_fee_rate_(
        i_rate: u256
    ):u256{
        u256_common::min(wad::wdiv(i_rate, 365_000_000_000_000_000_000), 100_000_000_000_000_000)
    }

    // Calculates debt-weighted average threshold price
    public fun dwatp(
        t0_debt: u256,
        inflator: u256,
        t0_debt2_to_collateral: u256
    ):u256{
        if(t0_debt == 0) 0 else wad::wdiv(wad::wmul(inflator, t0_debt2_to_collateral), t0_debt)
    }

    public fun is_collateralized(
        // borrower_debt
        debt: u256,
        collateral: u256,
        price: u256,
        pool_type: bool
    ):bool{
        if(pool_type){ // coin pool
            wad::wmul(collateral, price) >= debt
        }else{ // NFT pool ( remove decimals )
            collateral = collateral / constants::UNIT() * constants::UNIT();
            wad::wmul(collateral, price) >= debt
        }
    }

    // Auction
    public fun auction_price(
        reference_price: u256,
        kick_time: u64,
        clock: &Clock
    ): u256{
        let elapsed_minutes = wad::wdiv(wad::wad((time::get_sec(clock) - kick_time as u256)), wad::wad((time::minutes() as u256)));
        let _time_adjustment = int::zero();
        let _price = 0;
        if(elapsed_minutes < wad::wad(120)){
            // first 2 hours ( grace period )
            _time_adjustment = sd59x18::mul(int::neg_from_u256(wad::wad(1)), int::from_u256(elapsed_minutes / 20));
            _price = 256 * wad::wmul(reference_price, int::as_u256(&sd59x18::exp2(_time_adjustment)));
        }else if(elapsed_minutes < wad::wad(840)){
            // after 2 to 14 hours
            _time_adjustment = sd59x18::mul(int::neg_from_u256(wad::wad(1)), int::from_u256((elapsed_minutes - wad::wad(120)) / 120));
            _price = 4 * wad::wmul(reference_price, int::as_u256(&sd59x18::exp2(_time_adjustment)));
        }else{
            _time_adjustment = sd59x18::mul(int::neg_from_u256(wad::wad(1)), int::from_u256((elapsed_minutes - wad::wad(840)) / 60));
            _price = 4 * wad::wmul(reference_price, int::as_u256(&sd59x18::exp2(_time_adjustment))) / 16;
        };

        _price
    }

    /// Calculates bond penalty factor
    public fun bpf(
        debt: u256,
        collateral: u256,
        neutral_price: u256,
        bond_factor: u256,
        auction_price: u256
    ):Int{
        let threshold_price = int::from_u256(wad::wdiv(debt, collateral));
        let sign = int::zero();
        if(int::lt(&threshold_price, &int::from_u256(neutral_price))){
            // BPF = BondFactor * min(1, max(-1, (neutralPrice - price) / (neutralPrice - thresholdPrice)))
            sign = int::min_int(&int::from_u256(wad::wad(1)), &int::max_int(&int::neg_from_u256(wad::wad(1)), &sd59x18::div(int::sub(&int::from_u256(neutral_price), &int::from_u256(auction_price)), int::sub(&int::from_u256(neutral_price), &threshold_price))))
        }else{
            let val = int::sub(&int::from_u256(neutral_price), &int::from_u256(auction_price));
            if(int::lt(&val, &int::zero())){
                sign = int::neg_from_u256(wad::wad(1));
            }else if(!int::is_zero(&val)){
                sign = int::from_u256(wad::wad(1));
            };
        };
        sd59x18::mul(int::from_u256(bond_factor), sign)
    }

    /// Bond factor = Min(0.3, Max(0.01, (MOMP - TP)/ MOMP))
    public fun bond_params(
        borrower_debt: u256,
        np_tp_ratio: u256
    ):(u256, u256){
        // np_tp_ratio is always larger that 1 as neutral price is always larger than TP
        let bond_factor = wad::min(0_300000000000000000, (np_tp_ratio - wad::wad(1)) / 10);
        let bond_size = wad::wmul(bond_factor, borrower_debt);
        (bond_factor, bond_size)
    }

    public fun claimable_reserves(
        debt: u256,
        pool_size: u256,
        total_bond_escrowed: u256,
        reserve_auction_unclaimed: u256,
        quote_token_balance: u256
    ):u256{
        let guaranteed_funds = total_bond_escrowed + reserve_auction_unclaimed;

        // calculate claimable reserves if there's quote token excess
        if (quote_token_balance > guaranteed_funds) {
            let claimable_ = wad::wmul(0_995000000000000000, debt) + quote_token_balance;

            claimable_ = claimable_ - wad::min(
                claimable_,
                // require 1.0 + 1e-9 deposit buffer (extra margin) for deposits
                wad::wmul(DEPOSIT_BUFFER(), pool_size) + guaranteed_funds
            );

            // incremental claimable reserve should not exceed excess quote in pool
            claimable_ = wad::min(
                claimable_,
                quote_token_balance - guaranteed_funds
            );
            claimable_
        }else{
            0
        }
    }

    public fun reserve_auction_price(reserve_auction_kicked: u64, clock: &Clock):u256{
        if(reserve_auction_kicked != 0){
            let elapsed = time::get_sec(clock) - reserve_auction_kicked;
            let hours_component = RAY >> ((elapsed/ 3600) as u8);
            let minutes_component = rpow(MINUTE_HALF_LIFT, ((elapsed % 3600 / 60) as u256));
            ray_to_wad(1_000_000_000 * rmul(hours_component, minutes_component))
        }else{
            0
        }
    }

    fun rpow(x: u256, n: u256):u256{
        let z = if(n % 2 != 0) x else RAY;

        n = n / 2;
        while (n != 0){

            n = n / 2;
        };
        z
    }

    fun rmul(x: u256, y: u256):u256 {
        (x * y + RAY / 2) / RAY
    }

    fun ray_to_wad(a: u256):u256{
        let half_ratio = 1_000_000_000 / 2;
        (half_ratio + a) / WAD_RAY_RATIO
    }
}