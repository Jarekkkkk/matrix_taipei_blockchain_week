module protocol::ema{
    use math::wad;

    friend protocol::pool;

    // Struct holding pool EMAs state.
    struct EmaState has store{
        // [WAD] sample of debt EMA, numerator to MAU calculation
        debt_ema: u256,
        // [WAD] sample of meaningful deposit EMA, denominator to MAU calculation
        deposit_ema: u256,
        // [WAD] debt squared to collateral (debt^2/ col) EMA, numerator to TU calculation
        debt_col_ema: u256,
        // [WAD] EMA of LUP * t0 debt, denominator to TU calculation
        lup_t0_debt_ema: u256,
        // [TS] last time pool's EMAs were updated
        ema_update: u64
    }

    public (friend) fun default_ema_state():EmaState{
        EmaState{
            debt_ema: 0,
            deposit_ema: 0,
            debt_col_ema: 0,
            lup_t0_debt_ema: 0,
            ema_update: 0
        }
    }

    //[VIEW]
    public fun ema_state(self: &EmaState):(u256, u256, u256, u256, u64){
        (self.debt_ema, self.deposit_ema, self.debt_col_ema, self.lup_t0_debt_ema, self.ema_update)
    }
    public fun debt_ema(self: &EmaState): u256{
        self.debt_ema
    }
    public fun deposit_ema(self: &EmaState): u256{
        self.deposit_ema
    }
    public fun debt_col_ema(self: &EmaState): u256{
        self.debt_col_ema
    }
    public fun lup_t0_debt_ema(self: &EmaState): u256{
        self.lup_t0_debt_ema
    }
    public fun ema_update(self: &EmaState): u64{
        self.ema_update
    }

    // [MUT]
    public fun update_debt_ema(self: &mut EmaState, debt_ema: u256){
        self.debt_ema = debt_ema;
    }
    public fun update_deposit_ema(self: &mut EmaState, deposit_ema: u256){
        self.deposit_ema = deposit_ema;
    }
    public fun update_debt_col_ema(self: &mut EmaState, debt_col_ema: u256){
        self.debt_col_ema = debt_col_ema;
    }
    public fun update_lup_t0_debt_ema(self: &mut EmaState, lup_t0_debt_ema: u256){
        self.lup_t0_debt_ema = lup_t0_debt_ema;
    }
    public fun update_ema_update(self: &mut EmaState, ema_update: u64){
        self.ema_update = ema_update;
    }


    public fun utilization(ema: &EmaState): u256{
        utilization_(ema.debt_ema, ema.deposit_ema)
    }

    // Calculates pool meaningful actual utilization.
    public fun utilization_(
        debt_ema: u256,
        deposit_ema: u256
    ): u256 {
        if (debt_ema != 0) wad::wdiv(debt_ema, deposit_ema) else 0
    }
}