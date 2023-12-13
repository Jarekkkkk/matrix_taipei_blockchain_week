module protocol::interest{
    use sui::clock::Clock;

    use math::wad;
    use math::ud60x18;
    use protocol::time;

    friend protocol::pool;
    //friend protocol::taker;

    struct InterestState has store{
        // [WAD] pool's interest rate
        i_rate: u256,
        // [TS] last time pool's interest rate was updated (not before 12 hours passed)
        i_rate_last_update: u64,
        // [WAD] previous update's debt
        debt: u256,
        // [WAD] previous update's meaningfulDeposit
        meaningful_deposit: u256,
        // [WAD] utilization weight accumulator, tracks debt and collateral relationship accross borrowers
        t0_debt2_to_collateral: u256,
        // [WAD] previous debt squared to collateral
        debt_col: u256,
        // [WAD] previous LUP * t0 debt
        lup_t0_debt: u256
    }

    public (friend) fun default_interest_state(i_rate: u256, ts: u64):InterestState{
        InterestState{
            i_rate,
            i_rate_last_update: ts,
            debt: 0,
            meaningful_deposit: 0,
            t0_debt2_to_collateral: 0,
            debt_col: 0,
            lup_t0_debt: 0
        }
    }

    struct InflatorState has store{
        // [WAD] pool's inflator
        inflator: u256,
        // [TS] last time inflator update
        inflator_last_update: u64
    }

    public (friend) fun default_inflator_state(ts: u64):InflatorState{
        InflatorState{
            inflator: 1000000000000000000,
            inflator_last_update: ts
        }
    }

    // [ VIEW ]
    public fun interest_state(self: &InterestState):(u256, u64, u256, u256, u256, u256, u256){
        (self.i_rate, self.i_rate_last_update, self.debt, self.meaningful_deposit, self.t0_debt2_to_collateral, self.debt_col, self.lup_t0_debt)
    }
    public fun inflator(self: &InflatorState):u256{
        self.inflator
    }
    public fun inflator_last_update(self: &InflatorState):u64{
        self.inflator_last_update
    }
    // interest rate
    public fun interest_rate(self: &InterestState):u256{
        self.i_rate
    }
    public fun debt(self: &InterestState):u256{
        self.debt
    }
    public fun meaningful_deposit(self: &InterestState):u256{
        self.meaningful_deposit
    }
    public fun t0_debt2_to_collateral(self: &InterestState):u256{
        self.t0_debt2_to_collateral
    }
    public fun debt_col(self: &InterestState):u256{
        self.debt_col
    }
    public fun lup_t0_debt(self: &InterestState):u256{
        self.lup_t0_debt
    }


    // [ MUT ]
    public (friend) fun update_inflator(self: &mut InflatorState, value: u256){
        self.inflator = value;
    }
    public (friend) fun update_inflator_last_update(self: &mut InflatorState, time: u64){
        self.inflator_last_update = time;
    }
    // interest rate
    public (friend) fun update_interest_rate(self: &mut InterestState, value: u256){
        self.i_rate = value;
    }
    public (friend) fun update_i_rate_last_update(self: &mut InterestState, time: u64){
        self.i_rate_last_update = time;
    }
    public (friend) fun update_debt(self: &mut InterestState, value: u256){
        self.debt = value;
    }
    public (friend) fun update_meaningful_deposit(self: &mut InterestState, value: u256){
        self.meaningful_deposit = value;
    }
    public (friend) fun update_t0_debt2_to_collateral(self: &mut InterestState, value: u256){
        self.t0_debt2_to_collateral = value;
    }
    public (friend) fun update_debt_col(self: &mut InterestState, value: u256){
        self.debt_col = value;
    }
    public (friend) fun update_lup_t0_debt(self: &mut InterestState, value: u256){
        self.lup_t0_debt = value;
    }


     // Adjusts the `t0` debt 2 to collateral ratio, `interestState.t0Debt2ToCollateral`.
     public (friend) fun update_t0_debt2_to_collaterl(
        interest_state: &mut InterestState,
        _debt_pre_action: u256,
        _debt_post_action: u256,
        _collateral_pre_action: u256,
        _collateral_post_action: u256
     ){
        let debt_2_col_accum_pre_action = if(_collateral_pre_action != 0) _debt_pre_action * _debt_pre_action / _collateral_pre_action else 0;
        let debt_2_col_accum_post_action = if(_collateral_post_action != 0) _debt_post_action * _debt_post_action / _collateral_post_action else 0;

        if( debt_2_col_accum_pre_action != 0 || debt_2_col_accum_post_action != 0){
            interest_state.t0_debt2_to_collateral = interest_state.t0_debt2_to_collateral + debt_2_col_accum_post_action - debt_2_col_accum_pre_action;
        }
     }

    public fun pending_inflator(
        inflator: &InflatorState,
        interest: &InterestState,
        clock: &Clock
    ):u256{
        wad::wmul(inflator.inflator, ud60x18::exp(interest.i_rate * ((time::get_sec(clock) -inflator.inflator_last_update) as u256) / (365 * time::days() as u256)))
    }

    public fun pending_interest_factor(
        i_rate: u256,
        elapsed: u64
    ):u256{
        ud60x18::exp((i_rate * (elapsed as u256)) /(( 365 * time::days()) as u256))
    }
}