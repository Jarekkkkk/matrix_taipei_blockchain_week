module protocol::borrower{
    use sui::table;
    use sui::tx_context::{Self, TxContext};

    use protocol::deposit::{Self, DepositState};
    use protocol::loans::{Self, LoansState};
    use protocol::auction::{Self, AuctionState};
    use protocol::constants;
    use protocol::helpers;
    use protocol::event;
    use protocol::assert;

    use math::wad;

    friend protocol::pool;

    const ERR_AUCTION_ACTIVE: u64 = 101;
    const ERR_BORROWER_UNDER_COLLATERALIZED: u64 = 102;
    const ERR_INSUFFICIENT_LIQUIDITY: u64 = 103;
    const ERR_INVALID_AMOUNT: u64 = 104;
    const ERR_NO_DEBT: u64 = 105;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 106;
    const ERR_BORROWER_NOT_SENDER: u64 = 107;

    struct DrawDebtParams has drop{
        max_available: u256,
        borrower_address: address,
        amount_to_borrow: u256,
        limit_index: u64,
        collateral_to_pledge: u256,
        // pool
        pool_type: bool,
        inflator: u256,
        i_rate: u256,
        t0_debt: u256,
        debt: u256,
        collateral: u256,
        quote_token_scale: u256
    }

    public (friend) fun new_draw_debt_params(
        max_available: u256,
        borrower_address: address,
        amount_to_borrow: u256,
        limit_index: u64,
        collateral_to_pledge: u256,
        pool_type: bool,
        inflator: u256,
        i_rate: u256,
        t0_debt: u256,
        debt: u256,
        collateral: u256,
        quote_token_scale: u256
    ):DrawDebtParams{
        DrawDebtParams{
            max_available,
            borrower_address,
            amount_to_borrow,
            limit_index,
            collateral_to_pledge,
            pool_type,
            inflator,
            i_rate,
            t0_debt,
            debt,
            collateral,
            quote_token_scale
        }
    }

    public(friend) fun draw_debt_(
        auction_state: &AuctionState,
        deposit_state: &DepositState,
        loans_state: &mut LoansState,
        params: DrawDebtParams
    ):(u256, u256, u256, u256, u256, u256, u256, u256, u256)
    {
        if(params.amount_to_borrow > params.max_available) abort ERR_INSUFFICIENT_LIQUIDITY;

        if(auction::in_auction(auction_state, params.borrower_address)) abort ERR_AUCTION_ACTIVE;

        let _pledge = params.collateral_to_pledge != 0;
        let _borrow = params.amount_to_borrow != 0;

        if(!_pledge && !_borrow) abort ERR_INVALID_AMOUNT;

        if(!table::contains(loans::borrowers(loans_state), params.borrower_address)) table::add(loans::borrowers_mut(loans_state), params.borrower_address, loans::new_borrower());

        // result
        let (_debt_pre_action, _collateral_pre_action, _remaining_collateral, _borrow_debt) = {
            let borrower = loans::borrower(loans_state, params.borrower_address);
            let _borrow_debt = wad::wmul(loans::t0_debt(borrower), params.inflator);

            (loans::t0_debt(borrower), loans::collateral(borrower), loans::collateral(borrower), wad::wmul(loans::t0_debt(borrower), params.inflator))
        };
        let _t0_pool_debt = params.t0_debt;
        let _pool_debt = params.debt;
        let _pool_collateral = params.collateral;
        let _new_Lup = 0;
        let _t0_borrow_amount = 0;
        let _t0_debt_change = 0;
        let _borrower_debt = 0;
        let _np_tp_ratio_update = false;

        // [Action Pledge]
        if(_pledge){
            // add new amount of collateral to pledge to borrower balance
            let borrower = loans::borrower_mut(loans_state, params.borrower_address);
            loans::add_collateral(borrower, params.collateral_to_pledge);

            _remaining_collateral = loans::collateral(borrower);
            _new_Lup = deposit::get_Lup(deposit_state, _pool_debt);

            // add new amount of collateral to pledge to pool balance
            _pool_collateral = _pool_collateral + params.collateral_to_pledge;
        };

        // [Action Borrow]
        if(_borrow){
            _t0_borrow_amount = wad::ceilWdiv(params.amount_to_borrow, params.inflator);

            // t0 debt change = ( t0 amount to borrow + origination fee )
            _t0_debt_change = wad::wmul(_t0_borrow_amount, helpers::borrow_fee_rate(params.i_rate) + constants::UNIT());


            _borrower_debt = {
                let borrower_mut = loans::borrower_mut(loans_state, params.borrower_address);

                loans::add_t0_debt(borrower_mut, _t0_debt_change);

                wad::wmul(loans::t0_debt(borrower_mut), params.inflator)
            };

            // Minimum Borrow Size
            assert::check_on_min_debt(loans_state, _pool_debt, _borrower_debt, params.quote_token_scale);

            // add debt change to pool's debt
            _t0_pool_debt = _t0_pool_debt + _t0_debt_change;
            _pool_debt = wad::wmul(_t0_pool_debt, params.inflator);
            _new_Lup = deposit::get_Lup(deposit_state, _pool_debt);

            // revert if borrow drives LUP price under the specified price limit
            assert::check_price_drop_below_limit(_new_Lup, params.limit_index);

            // use new lup to check borrow action won't push borrower into a state of under-collateralization
            // this check also covers the scenario when loan is already auctioned
            if(!helpers::is_collateralized(_borrower_debt, loans::collateral(loans::borrower(loans_state, params.borrower_address)), _new_Lup, params.pool_type)) abort ERR_BORROWER_UNDER_COLLATERALIZED;

            // stamp borrower Np to Tp ratio when draw debt
            _np_tp_ratio_update = true;
        };

        // update the heap tree of loans of borrowers
        loans::update(loans_state, params.borrower_address, params.i_rate, false, _np_tp_ratio_update);

        let borrower = loans::borrower(loans_state, params.borrower_address);
        let _debt_post_action = loans::t0_debt(borrower);
        let _collateral_post_action = loans::collateral(borrower);
        (_new_Lup, _pool_collateral, _pool_debt, _remaining_collateral, _t0_pool_debt, _debt_pre_action, _debt_post_action, _collateral_pre_action, _collateral_post_action)
    }

    struct RepayDebtParams has drop{
        borrowerAddress_: address,
        maxQuoteTokenAmountToRepay_: u256,
        collateralAmountToPull_: u256,
        limitIndex_: u64,
        // pool
        inflator: u256,
        quote_token_scale: u256,
        i_rate: u256,
        t0_debt: u256,
        debt: u256,
        collateral: u256,
    }
    public fun new_repay_debt_params(
        borrowerAddress_: address,
        maxQuoteTokenAmountToRepay_: u256,
        collateralAmountToPull_: u256,
        limitIndex_: u64,
        inflator: u256,
        quote_token_scale: u256,
        i_rate: u256,
        t0_debt: u256,
        debt: u256,
        collateral: u256
    ):RepayDebtParams{
        RepayDebtParams{
            borrowerAddress_,
            maxQuoteTokenAmountToRepay_,
            collateralAmountToPull_,
            limitIndex_,
            inflator,
            quote_token_scale,
            i_rate,
            t0_debt,
            debt,
            collateral
        }
    }
    struct RepayDebtLocalVars has drop{
        borrowerDebt: u256,          // [WAD] borrower's accrued debt
        compensatedCollateral: u256, // [WAD] amount of borrower collateral that is compensated with LP (NFTs only)
        pull: bool,                  // true if pull action
        repay: bool,                 // true if repay action
        stampNpTpRatio: bool,        // true if loan's Np to Tp ratio should be restamped (when repay settles auction or pull collateral)
        t0RepaidDebt: u256,           // [WAD] t0 debt repaid
        // pool
        inflator: u256,
        quote_token_scale: u256,
        i_rate: u256,
        t0_debt: u256,
        debt: u256,
        collateral: u256
    }

    struct RepayDebtResult has drop{
        newLup: u256,                // [WAD] new pool LUP after draw debt
        poolCollateral: u256,        // [WAD] total amount of collateral in pool after pull collateral
        poolDebt: u256,              // [WAD] total accrued debt in pool after repay debt
        remainingCollateral: u256,   // [WAD] amount of borrower collateral after pull collateral
        t0PoolDebt: u256,            // [WAD] amount of t0 debt in pool after repay
        quoteTokenToRepay: u256,     // [WAD] quote token amount to be transferred from sender to pool
        debtPreAction: u256,         // [WAD] The amount of borrower t0 debt before repay debt
        debtPostAction: u256,        // [WAD] The amount of borrower t0 debt after repay debt
        collateralPreAction: u256,   // [WAD] The amount of borrower collateral before repay debt
        collateralPostAction: u256  // [WAD] The amount of borrower collateral after repay debt
    }
    public(friend) fun repay_debt(
        auction: &mut AuctionState,
        deposit: &mut DepositState,
        loans: &mut LoansState,
        params: RepayDebtParams,
        ctx: &mut TxContext
    ):(u256, u256, u256, u256, u256, u256, u256, u256, u256, u256){
        let vars = RepayDebtLocalVars{
            borrowerDebt: 0,
            compensatedCollateral: 0,
            pull: false,
            repay: false,
            stampNpTpRatio: false,
            t0RepaidDebt: 0,
            inflator: 0,
            quote_token_scale: 0,
            i_rate: 0,
            t0_debt: 0,
            debt: 0,
            collateral: 0
        };
        let result_ = RepayDebtResult{
            newLup: 0,
            poolCollateral: 0,
            poolDebt: 0,
            remainingCollateral: 0,
            t0PoolDebt: 0,
            quoteTokenToRepay: 0,
            debtPreAction: 0,
            debtPostAction: 0,
            collateralPreAction: 0,
            collateralPostAction: 0
        };

        vars.repay = params.maxQuoteTokenAmountToRepay_ != 0;
        vars.pull  = params.collateralAmountToPull_     != 0;

        // revert if no amount to pull or repay
        if (!vars.repay && !vars.pull) abort ERR_INVALID_AMOUNT;

        if(auction::in_auction(auction, params.borrowerAddress_)) abort ERR_AUCTION_ACTIVE;

        let (borrower_t0_debt, borrower_collateral) = {
            let borrower = loans::borrower(loans, params.borrowerAddress_);
            (loans::t0_debt(borrower), loans::collateral(borrower))
        };

        vars.borrowerDebt = wad::wmul(borrower_t0_debt, params.inflator);

        result_.debtPreAction       = borrower_t0_debt;
        result_.collateralPreAction = borrower_collateral;
        result_.t0PoolDebt          = params.t0_debt;
        result_.poolDebt            = params.debt;
        result_.poolCollateral      = params.collateral;
        result_.remainingCollateral = borrower_collateral;

        if (vars.repay) {
            if (borrower_t0_debt == 0) abort ERR_NO_DEBT;

            if (params.maxQuoteTokenAmountToRepay_ == constants::UINT_MAX()) {
                vars.t0RepaidDebt = borrower_t0_debt;
            } else {
                vars.t0RepaidDebt = wad::min(
                    borrower_t0_debt,
                    wad::floorWdiv(params.maxQuoteTokenAmountToRepay_, params.inflator)
                );
            };

            result_.quoteTokenToRepay = wad::ceilWmul(vars.t0RepaidDebt, params.inflator);
            // revert if (due to roundings) calculated token amount to repay is 0
            if (result_.quoteTokenToRepay == 0) abort ERR_INVALID_AMOUNT;

            result_.t0PoolDebt = result_.t0PoolDebt - vars.t0RepaidDebt;
            result_.poolDebt   = wad::wmul(result_.t0PoolDebt, params.inflator);
            vars.borrowerDebt = wad::wmul(borrower_t0_debt - vars.t0RepaidDebt, params.inflator);

            // check that paying the loan doesn't leave borrower debt under min debt amount
            assert::check_on_min_debt(
                loans,
                result_.poolDebt,
                vars.borrowerDebt,
                params.quote_token_scale
            );

            result_.newLup = deposit::get_Lup(deposit, result_.poolDebt);
            loans::remove_t0_debt(loans::borrower_mut(loans, params.borrowerAddress_), vars.t0RepaidDebt);
        };

        if (vars.pull) {
            // only intended recipient can pull collateral
            if (params.borrowerAddress_ != tx_context::sender(ctx)) abort ERR_BORROWER_NOT_SENDER;

            // calculate LUP only if it wasn't calculated in repay action
            if (!vars.repay) result_.newLup = deposit::get_Lup(deposit, result_.poolDebt);

            let borrower = loans::borrower_mut(loans, params.borrowerAddress_);
            let encumberedCollateral = wad::wdiv(vars.borrowerDebt, result_.newLup);
            if (
                loans::t0_debt(borrower) != 0 && encumberedCollateral == 0 || // case when small amount of debt at a high LUP results in encumbered collateral calculated as 0
                loans::collateral(borrower) < encumberedCollateral ||
                loans::collateral(borrower) - encumberedCollateral < params.collateralAmountToPull_
            ) abort ERR_INSUFFICIENT_COLLATERAL;

            // stamp borrower Np to Tp ratio when pull collateral action
            vars.stampNpTpRatio = true;

            loans::remove_collateral(borrower, params.collateralAmountToPull_);

            result_.poolCollateral = result_.poolCollateral - params.collateralAmountToPull_;
        };

        // check limit price and revert if price dropped below
        assert::check_price_drop_below_limit(result_.newLup, params.limitIndex_);

        // update loan state
        loans::update(loans, params.borrowerAddress_, params.i_rate, false, vars.stampNpTpRatio);

        let borrower = loans::borrower(loans, params.borrowerAddress_);
        result_.debtPostAction       = loans::t0_debt(borrower);
        result_.collateralPostAction = loans::collateral(borrower);


        (
            result_.newLup,
            result_.poolCollateral,
            result_.poolDebt,
            result_.remainingCollateral,
            result_.t0PoolDebt,
            result_.quoteTokenToRepay,
            result_.debtPreAction,
            result_.debtPostAction,
            result_.collateralPreAction,
            result_.collateralPostAction
        )
    }

    public(friend) fun stamp_loan(
        auction: &AuctionState,
        deposit: &DepositState,
        loans: &mut LoansState,
        pool_type: bool,
        pool_inflator: u256,
        pool_debt: u256,
        pool_rate: u256,
        ctx: &TxContext
    ): u256{
        let borrower_address = tx_context::sender(ctx);

        if(auction::in_auction(auction, borrower_address)) abort ERR_AUCTION_ACTIVE;

        let borrower = loans::borrower(loans, borrower_address);
        let new_Lup = deposit::get_Lup(deposit, pool_debt);

        // revert if loan is not fully collateralized at current LUP
        if(!helpers::is_collateralized(wad::wmul(loans::t0_debt(borrower), pool_inflator), loans::collateral(borrower), new_Lup, pool_type)) abort ERR_BORROWER_UNDER_COLLATERALIZED;

        // update loan state to stamp Np to Tp ratio
        loans::update(loans, borrower_address, pool_rate, false, true );

        event::laon_stamped(borrower_address);
        new_Lup
    }
}