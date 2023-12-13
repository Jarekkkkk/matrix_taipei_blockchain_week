module protocol::lender{
    use std::vector as vec;

    use sui::table::{Self, Table};
    use sui::clock::Clock;
    use sui::tx_context::TxContext;
    use sui::object;

    use math::wad;
    use protocol::time;

    use protocol::deposit::{Self, DepositState};
    use protocol::bucket::{Self, Bucket};
    use protocol::position::Position;

    use protocol::event;
    use protocol::constants;
    use protocol::helpers;

    friend protocol::pool;

    const ERR_BUCKET_BANKRUPTCY_BLOCK: u64 = 101;
    const ERR_INSUFFICIENT_LP: u64 = 102;
    const ERR_INVALID_AMOUNT: u64 = 103;
    const ERR_INVALID_INDEX: u64 = 105;
    const ERR_PRICE_BELOW_LUP: u64 = 106;
    const ERR_ZERO_VALUE: u64 = 107;
    const ERR_SAME_INDEX: u64 = 108;
    const ERR_DUST_VALUE: u64 = 109;
    const ERR_INSUFFICIENT_LIQUIDITY: u64 = 110;
    const ERR_LUP_BELOW_HTP: u64 = 111;
    const ERR_NO_CLAIM: u64 = 112;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 113;
    const ERR_UNABLE_TO_MERGE_TO_HIGHER_PRICE: u64 = 114;

    struct AddQuoteParams has drop{
        amount: u256,
        index: u64,
        revert_if_below_lup: bool,
        debt: u256,
        i_rate: u256
    }

    public(friend) fun new_add_quote_params(
        amount: u256,
        index: u64,
        revert_if_below_lup: bool,
        debt: u256,
        i_rate: u256
    ):AddQuoteParams{
        AddQuoteParams{
            amount,
            index,
            revert_if_below_lup,
            debt,
            i_rate
        }
    }

    public (friend) fun add_quote_coins_<Collateral>(
        position: &Position,
        buckets: &mut Table<u64, Bucket<Collateral>>,
        deposit_state: &mut DepositState,
        params: AddQuoteParams,
        clock: &Clock,
        ctx: &mut TxContext
    ):(u256, u256){
        // revert if no amount to be added
        if(params.amount == 0) abort ERR_INVALID_AMOUNT;
        // revert if adding to an invalid index
        if(params.index == 0 || params.index > constants::max_fenwick_index()) abort ERR_INVALID_INDEX;

        // retrieve the bucket at desired index
        if(!table::contains(buckets, params.index)){
            table::add(buckets, params.index, bucket::new(ctx));
        };
        let bucket = table::borrow_mut(buckets, params.index);

        // cannot deposit in the same block when bucket becomes insolvent
        let bankruptcy_time = bucket::bankruptcy_time(bucket);
        if( bankruptcy_time > time::get_sec(clock)) abort ERR_BUCKET_BANKRUPTCY_BLOCK;

        let unscaled_bucket_deposit = deposit::unscaled_value_at(deposit_state, params.index);
        let bucket_scale = deposit::scale(deposit_state, params.index);
        let bucket_deposit = wad::wmul(bucket_scale, unscaled_bucket_deposit);
        let bucket_price = helpers::price_at(params.index);

        let added_amount = params.amount;

        // charge unutilized deposit fee where appropriate, determine [LUP][Fenwick Tree]
        let lup_index = deposit::find_index_of_sum(deposit_state, params.debt);

        // Fenwick index, higher index representlower price
        let deposit_below_Lup = lup_index != 0 && params.index > lup_index;

        if(deposit_below_Lup){
            if(params.revert_if_below_lup) abort ERR_PRICE_BELOW_LUP;
            // deposit penalty
            added_amount = wad::wmul(added_amount, constants::UNIT() - helpers::deposit_fee_rate_(params.i_rate));
        };

        let bucket_LP = bucket::quote_token_to_LP(bucket::collateral(bucket),bucket::lps(bucket), bucket_deposit, added_amount, bucket_price, false);

        // revert if (due to rounding) the awarded LP is 0
        if(bucket_LP == 0) abort ERR_INSUFFICIENT_LP;

        let unscaled_amount = wad::wdiv(added_amount, bucket_scale);

        // revert if unscaled amount is 0
        if(unscaled_amount == 0) abort ERR_INVALID_AMOUNT;

        deposit::unscaled_add(deposit_state, params.index, unscaled_amount);

        // update lender LP
        let id = object::id(position);
        if(!bucket::is_lender(bucket, id)) table::add(bucket::lenders_mut(bucket), id, bucket::default_lender());
        let lender = bucket::lender_mut(bucket, id);
        bucket::add_lender_lp(lender, bankruptcy_time, bucket_LP, clock);

        // update bucket LP
        bucket::add_lps(bucket, bucket_LP);

        // only need to recalculate LUP if the deposit was above it
        if(!deposit_below_Lup){
            lup_index = deposit::find_index_of_sum(deposit_state, params.debt);
        };
        let lup = helpers::price_at(lup_index);

        event::add_quote_token(id, (params.index as u64), added_amount, bucket_LP, lup);

        (bucket_LP, lup)
    }


    struct MoveQuoteParams has drop{
        from_index: u64,
        to_index: u64,
        max_amount_to_move: u256,
        threshold_price: u256,
        revert_if_below_lup:bool,
        // pool_state
        inflator: u256,
        i_rate: u256,
        debt: u256,
        quote_token_scale: u256
    }

    public(friend) fun new_move_quote_params(
        from_index: u64,
        to_index: u64,
        max_amount_to_move: u256,
        threshold_price: u256,
        revert_if_below_lup:bool,
        inflator: u256,
        i_rate: u256,
        debt: u256,
        quote_token_scale: u256
    ):MoveQuoteParams{
        MoveQuoteParams{
            from_index,
            to_index,
            max_amount_to_move,
            threshold_price,
            revert_if_below_lup,
            inflator,
            i_rate,
            debt,
            quote_token_scale,
        }
    }

    struct MoveQuoteLocalVars has drop{
        fromBucketPrice: u256,
        fromBucketCollateral: u256,
        fromBucketLP: u256,
        fromBucketLenderLP: u256,
        fromBucketDepositTime: u64,
        fromBucketRemainingLP: u256,
        fromBucketRemainingDeposit: u256,
        toBucketPrice: u256,
        toBucketBankruptcyTime: u64,
        toBucketDepositTime: u64,
        toBucketUnscaledDeposit: u256,
        toBucketDeposit: u256,
        toBucketScale: u256,
        htp: u256
    }

    public(friend) fun move_quote_tokens<Collateral>(
        position: &Position,
        buckets: &mut Table<u64, Bucket<Collateral>>,
        deposit: &mut DepositState,
        params: MoveQuoteParams,
        clock: &Clock,
        ctx: &mut TxContext
    ):(u256, u256, u256, u256,){
        if(params.max_amount_to_move == 0) abort ERR_ZERO_VALUE;
        if(params.from_index == params.to_index) abort ERR_SAME_INDEX;
        if(params.max_amount_to_move != 0 && params.max_amount_to_move < params.quote_token_scale) abort ERR_DUST_VALUE;
        if(params.to_index == 0 || params.to_index == constants::max_fenwick_index()) abort ERR_INVALID_INDEX;

        let position_id = object::id(position);
        let vars = MoveQuoteLocalVars{
            fromBucketPrice: 0,
            fromBucketCollateral: 0,
            fromBucketLP: 0,
            fromBucketLenderLP: 0,
            fromBucketDepositTime: 0,
            fromBucketRemainingLP: 0,
            fromBucketRemainingDeposit: 0,
            toBucketPrice: 0,
            toBucketBankruptcyTime: 0,
            toBucketDepositTime: 0,
            toBucketUnscaledDeposit: 0,
            toBucketDeposit: 0,
            toBucketScale: 0,
            htp: 0
        };

        if(!table::contains(buckets, params.to_index)){
            table::add(buckets, params.to_index, bucket::new(ctx));
        };
        vars.toBucketBankruptcyTime = bucket::bankruptcy_time(table::borrow(buckets, params.to_index));

        if(vars.toBucketBankruptcyTime == time::get_sec(clock)) abort ERR_BUCKET_BANKRUPTCY_BLOCK;

        let from_bucket = table::borrow(buckets, params.from_index);
        let from_bucket_lender = bucket::lender(from_bucket, position_id);

        vars.fromBucketPrice       = helpers::price_at(params.from_index);
        vars.fromBucketCollateral  = bucket::collateral(from_bucket);
        vars.fromBucketLP          = bucket::lps(from_bucket);
        vars.fromBucketDepositTime = bucket::lender_deposit_time(from_bucket_lender);

        vars.toBucketPrice         = helpers::price_at(params.to_index);

        if (bucket::bankruptcy_time(from_bucket) < vars.fromBucketDepositTime) vars.fromBucketLenderLP = bucket::lender_lps(from_bucket_lender);

        let (removedAmount_, redeemedLP_, unscaledRemaining_) = remove_max_deposit(deposit, params.max_amount_to_move, vars.fromBucketLenderLP, vars.fromBucketLP, vars.fromBucketCollateral, vars.fromBucketPrice, params.from_index);

        let toBucketLP_ = 0;
        let movedAmount_ = removedAmount_;
        let fromBucketRedeemedLP_ = redeemedLP_;
        vars.fromBucketRemainingDeposit = unscaledRemaining_;
        let lup_ = deposit::get_Lup(deposit, params.debt);

        // apply unutilized deposit fee if quote token is moved from above the LUP to below the LUP
        if (vars.fromBucketPrice >= lup_ && vars.toBucketPrice < lup_) {
            if (params.revert_if_below_lup) abort ERR_PRICE_BELOW_LUP;

            movedAmount_ = wad::wmul(movedAmount_, wad::wad(1) - helpers::deposit_fee_rate_(params.i_rate));
        };

        vars.toBucketUnscaledDeposit = deposit::unscaled_value_at(deposit, params.to_index);
        vars.toBucketScale           = deposit::scale(deposit, params.to_index);
        vars.toBucketDeposit         = wad::wmul(vars.toBucketUnscaledDeposit, vars.toBucketScale);

        toBucketLP_ = {
            let to_bucket = table::borrow(buckets, params.to_index);
            bucket::quote_token_to_LP(
                bucket::collateral(to_bucket),
                bucket::lps(to_bucket),
                vars.toBucketDeposit,
                movedAmount_,
                vars.toBucketPrice,
                false
            )
        };

        // revert if (due to rounding) the awarded LP in to bucket is 0
        if (toBucketLP_ == 0) abort ERR_INSUFFICIENT_LP;

        deposit::unscaled_add(deposit, params.to_index, wad::wdiv(movedAmount_, vars.toBucketScale));

        // recalculate LUP after adding amount in to bucket only if to bucket price is greater than LUP
        if (vars.toBucketPrice > lup_) lup_ = deposit::get_Lup(deposit, params.debt);

        vars.htp = wad::wmul(params.threshold_price, params.inflator);

        // check loan book's htp against new lup, revert if move drives LUP below HTP

        if (
            params.from_index < params.to_index
            &&
            (
                // check loan book's htp doesn't exceed new lup
                vars.htp > lup_
                ||
                // ensure that pool debt < deposits after move
                // this can happen if deposit fee is applied when moving amount
                (params.debt != 0 && params.debt > deposit::tree_sum(deposit))
            )
        ) abort ERR_LUP_BELOW_HTP;

        // update lender and bucket LP balance in from bucket
        vars.fromBucketRemainingLP = vars.fromBucketLP - fromBucketRedeemedLP_;

        // check if from bucket healthy after move quote tokens - set bankruptcy if collateral and deposit are 0 but there's still LP
        if (vars.fromBucketCollateral == 0 && vars.fromBucketRemainingDeposit == 0 && vars.fromBucketRemainingLP != 0) {
            let from_bucket = table::borrow_mut(buckets, params.from_index);
            bucket::update_lps(from_bucket, 0);
            bucket::update_bankruptcy_time(from_bucket, time::get_sec(clock));

            event::bucket_bankruptcy(
                params.from_index,
                vars.fromBucketRemainingLP
            );
        } else {
            let from_bucket = table::borrow_mut(buckets, params.from_index);

            let from_bucket_lender = bucket::lender_mut(from_bucket, position_id);
            // update lender and bucket LP balance
            bucket::remove_lender_lps(from_bucket_lender, fromBucketRedeemedLP_);
            bucket::drop_lender_if_zero_lps(from_bucket, position_id);
            bucket::update_lps(from_bucket, vars.fromBucketRemainingLP);
        };

        // update lender and bucket LP balance in target bucket
        if(!bucket::is_lender(table::borrow(buckets, params.to_index), position_id)){
            let to_bucket = table::borrow_mut(buckets, params.to_index);
            table::add(bucket::lenders_mut(to_bucket), position_id, bucket::default_lender());
        };
        let to_bucket_lender = bucket::lender_mut(table::borrow_mut(buckets, params.to_index), position_id);

        vars.toBucketDepositTime = bucket::lender_deposit_time(to_bucket_lender);
        if (vars.toBucketBankruptcyTime >= vars.toBucketDepositTime) {
            // bucket is bankrupt and deposit was done before bankruptcy time, reset lender lp amount
            bucket::update_lender_lps(to_bucket_lender, toBucketLP_);

            // set deposit time of the lender's to bucket as bucket's last bankruptcy timestamp + 1 so deposit won't get invalidated
            vars.toBucketDepositTime = vars.toBucketBankruptcyTime + 1;
        } else {
            bucket::add_lender_lps(to_bucket_lender, toBucketLP_);
        };

        // set deposit time to the greater of the lender's from bucket and the target bucket
        bucket::update_deposit_time(to_bucket_lender, sui::math::max(vars.fromBucketDepositTime, vars.toBucketDepositTime));

        // update bucket LP balance
        bucket::add_lps(table::borrow_mut(buckets, params.to_index), toBucketLP_);

        event::move_quote_token(position_id, params.from_index, params.to_index, movedAmount_, fromBucketRedeemedLP_, toBucketLP_, lup_);

        (fromBucketRedeemedLP_, toBucketLP_, movedAmount_, lup_)
    }

    struct RemoveQuoteParams has drop{
        index: u64,
        maxAmount: u256,
        thresholdPrice: u256,
        quoteTokenScale: u256,
        inflator: u256,
        debt: u256
    }
    public(friend) fun new_remove_quote_params(
        index: u64,
        maxAmount: u256,
        thresholdPrice: u256,
        quoteTokenScale: u256,
        inflator: u256,
        debt: u256
    ):RemoveQuoteParams{
        RemoveQuoteParams{
            index,
            maxAmount,
            thresholdPrice,
            quoteTokenScale,
            inflator,
            debt
        }
    }
    struct RemoveDepositParams has drop{
        depositConstraint: u256,
        lpConstraint: u256,
        bucketLP: u256,
        bucketCollateral: u256,
        price: u256,
        index: u64,
        dustLimit: u256
    }

    public(friend) fun remove_quote_tokens<Collateral>(
        position: &Position,
        buckets: &mut Table<u64, Bucket<Collateral>>,
        deposit: &mut DepositState,
        params: RemoveQuoteParams,
        clock: &Clock
    ):(u256, u256, u256){
        // revert if no amount to be removed
        if (params.maxAmount == 0) abort ERR_INVALID_AMOUNT;

        let position_id = object::id(position);
        let bucket = table::borrow(buckets, params.index);
        let lender = bucket::lender(bucket, position_id);

        let depositTime = bucket::lender_deposit_time(lender);

        let removeParams = RemoveDepositParams{
            depositConstraint: 0,
            lpConstraint: 0,
            bucketLP: 0,
            bucketCollateral: 0,
            price: 0,
            index: 0,
            dustLimit: 0
        };

        if (bucket::bankruptcy_time(bucket) < depositTime) removeParams.lpConstraint = bucket::lender_lps(lender);

        // revert if no LP to claim
        if (removeParams.lpConstraint == 0) abort ERR_NO_CLAIM;

        removeParams.depositConstraint = params.maxAmount;
        removeParams.price             = helpers::price_at(params.index);
        removeParams.bucketLP          = bucket::lps(bucket);
        removeParams.bucketCollateral  = bucket::collateral(bucket);
        removeParams.index             = params.index;
        removeParams.dustLimit         = params.quoteTokenScale;

        let (removedAmount_, redeemedLP_, unscaledRemaining) = remove_max_deposit(
            deposit,
            removeParams.depositConstraint,
            removeParams.lpConstraint,
            removeParams.bucketLP,
            removeParams.bucketCollateral,
            removeParams.price,
            removeParams.index,
        );

        let lup_ = deposit::get_Lup(deposit, params.debt);
        let htp = wad::wmul(params.thresholdPrice, params.inflator);

        if (
            // check loan book's htp doesn't exceed new lup
            htp > lup_
            ||
            // ensure that pool debt < deposits after removal
            // this can happen if lup and htp are less than min bucket price and htp > lup (since LUP is capped at min bucket price)
            (params.debt != 0 && params.debt > deposit::tree_sum(deposit))
        ) abort ERR_LUP_BELOW_HTP;

        let lpRemaining = removeParams.bucketLP - redeemedLP_;
        // check if bucket healthy after remove quote tokens - set bankruptcy if collateral and deposit are 0 but there's still LP
        {
            let bucket = table::borrow_mut(buckets, params.index);
            let lender = bucket::lender_mut(bucket, position_id);
            if (removeParams.bucketCollateral == 0 && unscaledRemaining == 0 && lpRemaining != 0) {
                bucket::update_lps(bucket, 0);
                bucket::update_bankruptcy_time(bucket, time::get_sec(clock));

                event::bucket_bankruptcy(params.index, lpRemaining);
            } else {
                // update lender and bucket LP balances
                bucket::remove_lender_lps(lender, redeemedLP_);
                bucket::update_lps(bucket, lpRemaining);
                bucket::drop_lender_if_zero_lps(bucket, position_id);
            };
        };

        event::remove_quote_token(position_id, params.index, removedAmount_, redeemedLP_, lup_);

        (removedAmount_, redeemedLP_, lup_)
    }

    fun remove_max_deposit(
        deposit: &mut DepositState,
        depositConstraint: u256,
        lpConstraint: u256,
        bucketLP: u256,
        bucketCollateral: u256,
        price: u256,
        index: u64
    ):(u256, u256, u256){
        let unscaledDepositAvailable = deposit::unscaled_value_at(deposit, index);

        // revert if there's no liquidity available to remove
        if (unscaledDepositAvailable == 0) abort ERR_INSUFFICIENT_LIQUIDITY;

        let depositScale           = deposit::scale(deposit, index);
        let scaledDepositAvailable = wad::wmul(unscaledDepositAvailable, depositScale);
        // Below is pseudocode explaining the logic behind finding the constrained amount of deposit and LPB
        // scaledRemovedAmount is constrained by the scaled maxAmount(in QT), the scaledDeposit constraint, and
        // the lender LPB exchange rate in scaled deposit-to-LPB for the bucket:
        // scaledRemovedAmount = min ( maxAmount_, scaledDeposit, lenderLPBalance*exchangeRate)
        // redeemedLP_ = min ( maxAmount_/scaledExchangeRate, scaledDeposit/exchangeRate, lenderLPBalance)

        let removedAmount_ = 0;
        let redeemedLP_ = 0;
        let unscaledRemaining_ = 0;

        let scaledLpConstraint = bucket::LP_to_quote_token(
            bucketCollateral,
            bucketLP,
            scaledDepositAvailable,
            lpConstraint,
            price,
            false
        );

        let unscaledRemovedAmount;
        if (
            depositConstraint < scaledDepositAvailable &&
            depositConstraint < scaledLpConstraint
        ) {
            // depositConstraint is binding constraint
            removedAmount_ = depositConstraint;
            redeemedLP_    = bucket::quote_token_to_LP(
                bucketCollateral,
                bucketLP,
                scaledDepositAvailable,
                removedAmount_,
                price,
                true
            );
            redeemedLP_ = wad::min(redeemedLP_, lpConstraint);
            unscaledRemovedAmount = wad::wdiv(removedAmount_, depositScale);
        } else if (scaledDepositAvailable < scaledLpConstraint) {
            // scaledDeposit is binding constraint
            removedAmount_ = scaledDepositAvailable;
            redeemedLP_    = bucket::quote_token_to_LP(
                bucketCollateral,
                bucketLP,
                scaledDepositAvailable,
                removedAmount_,
                price,
                true
            );
            redeemedLP_ = wad::min(redeemedLP_, lpConstraint);
            unscaledRemovedAmount = unscaledDepositAvailable;
        } else {
            // redeeming all LP
            redeemedLP_    = lpConstraint;
            removedAmount_ = bucket::LP_to_quote_token(
                bucketCollateral,
                bucketLP,
                scaledDepositAvailable,
                redeemedLP_,
                price,
                false
            );
            unscaledRemovedAmount = wad::wdiv(removedAmount_, depositScale);
        };

        // If clearing out the bucket deposit, ensure it's zeroed out
        if (redeemedLP_ == bucketLP) {
            removedAmount_ = scaledDepositAvailable;
            unscaledRemovedAmount = unscaledDepositAvailable;
        };

        unscaledRemaining_ = unscaledDepositAvailable - unscaledRemovedAmount;

        // revert if (due to rounding) required LP is 0
        if (redeemedLP_ == 0) abort ERR_INSUFFICIENT_LP;
        // revert if calculated amount of quote to remove is 0
        if (unscaledRemovedAmount == 0) abort ERR_INVALID_AMOUNT;

        // update FenwickTree
        deposit::unscaled_remove(deposit, index, unscaledRemovedAmount);

        (removedAmount_, redeemedLP_, unscaledRemaining_)
    }

    public(friend) fun add_collateral<Collateral>(
        buckets: &mut Table<u64, Bucket<Collateral>>,
        position: &Position,
        deposit: &mut DepositState,
        collateral_amount: u256,
        index: u64,
        clock: &Clock
    ):u256{
        if(collateral_amount == 0) abort ERR_INVALID_AMOUNT;
        if(index == 0 || index > constants::max_fenwick_index()) abort ERR_INVALID_INDEX;

        let bucket_deposit = deposit::value_at(deposit, index);
        let bucket_price = helpers::price_at(index);

        let bucket_mut = table::borrow_mut(buckets, index);
        let bucket_lp = bucket::add_collateral_(bucket_mut, object::id(position), bucket_deposit, collateral_amount, bucket_price, clock);

        // round down number is zero
        if(bucket_lp == 0) abort ERR_INSUFFICIENT_LP;
        bucket_lp
    }

    public(friend) fun remove_max_collateral<Collateral>(
        buckets: &mut Table<u64, Bucket<Collateral>>,
        position: &Position,
        deposit: &mut DepositState,
        max_amount: u256,
        index: u64,
        clock: &Clock
    ):(u256, u256){
        assert!(max_amount != 0, ERR_ZERO_VALUE);

        let bucket = table::borrow(buckets, index);
        let bucket_collateral = bucket::collateral(bucket);
        if(bucket_collateral == 0) abort ERR_INSUFFICIENT_COLLATERAL;

        let lender = bucket::lender(bucket, object::id(position));

        let lender_lp_balance = if(bucket::bankruptcy_time(bucket) < bucket::lender_deposit_time(lender)) bucket::lender_lps(lender) else 0;

        if(lender_lp_balance == 0) abort ERR_NO_CLAIM;

        let bucket_price = helpers::price_at(index);
        let bucket_deposit = deposit::value_at(deposit, index);
        let bucket_lps = bucket::lps(bucket);

        // constrained by what is available in the bucket
        let collateral_amount = wad::min(max_amount, bucket_collateral);

        // quote returned LP
        let required_lp = bucket::collateral_to_LP(bucket, bucket_deposit,collateral_amount, bucket_price, true);

        if(required_lp == 0) abort ERR_INSUFFICIENT_LP;

        let lp_amount = if(required_lp <= lender_lp_balance){
            required_lp
        }else{
            collateral_amount = math::u256_common::mul_div(lender_lp_balance, collateral_amount, required_lp);
            if(collateral_amount == 0) abort ERR_INSUFFICIENT_LP;

            lender_lp_balance
        };

        bucket_lps = bucket_lps - wad::min(bucket_lps, lp_amount);
        // If clearing out the bucket collateral, ensure it's zeroed out
        if (bucket_lps == 0 && bucket_deposit == 0) collateral_amount = bucket_collateral;

        collateral_amount = wad::min(collateral_amount, bucket_collateral);
        bucket_collateral = bucket_collateral - collateral_amount;
        let bucket = table::borrow_mut(buckets, index);
        bucket::update_collateral(bucket, bucket_collateral);
        let lender = bucket::lender_mut(bucket, object::id(position));
        // check if bucket healthy after collateral remove - set bankruptcy if collateral and deposit are 0 but there's still LP
        if(bucket_deposit == 0 && bucket_collateral == 0 && bucket_lps != 0){
            // bankruptcy
            bucket::update_lps(bucket, 0);
            bucket::update_bankruptcy_time(bucket, time::get_sec(clock));
            event::bucket_bankruptcy(index, bucket_lps);
        }else{
            bucket::remove_lender_lps(lender, lp_amount);
            bucket::drop_lender_if_zero_lps(bucket, object::id(position));
            bucket::update_lps(bucket, bucket_lps);
        };

        (collateral_amount, lp_amount)
    }

    public(friend) fun remove_collateral<Collateral>(
        buckets: &mut Table<u64, Bucket<Collateral>>,
        position: &Position,
        deposit: &mut DepositState,
        amount: u256,
        index: u64,
        clock: &Clock
    ):u256{
        assert!(amount != 0, ERR_ZERO_VALUE);

        let bucket = table::borrow(buckets, index);
        let bucket_collateral = bucket::collateral(bucket);
        if(bucket_collateral == 0) abort ERR_INSUFFICIENT_COLLATERAL;

        let bucket_price = helpers::price_at(index);
        let bucket_deposit = deposit::value_at(deposit, index);
        let bucket_lps = bucket::lps(bucket);

        // quote returned LP
        let required_lp = bucket::collateral_to_LP(bucket, bucket_deposit, amount, bucket_price, false);
        if(required_lp == 0) abort ERR_INSUFFICIENT_LP;

        let lender = bucket::lender(bucket, object::id(position));
        let lender_lp_balance = if(bucket::bankruptcy_time(bucket) < bucket::lender_deposit_time(lender)) bucket::lender_lps(lender) else 0;
        if(lender_lp_balance == 0 || required_lp > lender_lp_balance) abort ERR_NO_CLAIM;

        bucket_lps = bucket_lps - required_lp;

        // If clearing out the bucket collateral, ensure it's zeroed out
        // sending all left collateral
        if (bucket_lps == 0 && bucket_deposit == 0) amount = bucket_collateral;

        let bucket = table::borrow_mut(buckets, index);
        bucket::remove_collateral(bucket, amount);
        let lender = bucket::lender_mut(bucket, object::id(position));
        // check if bucket healthy after collateral remove - set bankruptcy if collateral and deposit are 0 but there's still LP3
        if(bucket_deposit == 0 && bucket_collateral == 0 && bucket_lps != 0){
            // bankruptcy
            bucket::update_lps(bucket, 0);
            bucket::update_bankruptcy_time(bucket, time::get_sec(clock));
            event::bucket_bankruptcy(index, bucket_lps);
        }else{
            bucket::remove_lender_lps(lender, required_lp);
            bucket::update_lps(bucket, bucket_lps);
        };

        required_lp
    }


    /// move collateral from chosen indexes to target index, merge and returned the difference nft
    public(friend) fun merge_or_remove_collateral<Collateral>(
        buckets: &mut Table<u64, Bucket<Collateral>>,
        position: &Position,
        deposit:&mut DepositState,
        collateral_amount: u256,
        removed_indexes: vector<u64>,
        to_index: u64,
        clock: &Clock
    ):(u256, u256){
        let i = 0;
        let from_index = 0;
        let no_of_buckets = vec::length(&removed_indexes);
        let collateral_remaining = collateral_amount;

        // sum
        let collateral_to_merge = 0;
        let bucket_lp = 0;

        while( collateral_to_merge < collateral_amount && i < no_of_buckets){
            let from_index = *vec::borrow(&removed_indexes, i);

            // unable to move the price higher
            if(from_index > to_index) abort ERR_UNABLE_TO_MERGE_TO_HIGHER_PRICE;

            let (collateral_removed, _) = remove_max_collateral(buckets, position, deposit, collateral_remaining, from_index, clock);
            // revert if calculated amount of collateral to remove is 0
            if(collateral_removed == 0) abort ERR_INVALID_AMOUNT;

            collateral_to_merge = collateral_to_merge + collateral_removed;

            collateral_remaining = collateral_remaining - collateral_removed;

            i = i + 1;
        };

        // fail to meet reuqired removed amount of NFT, deposit to new bucket
        if(collateral_to_merge != collateral_amount){
            let bucket_lp = add_collateral(buckets, position, deposit, collateral_to_merge, to_index, clock);

            if(bucket_lp == 0) abort ERR_INSUFFICIENT_LP;
        };

        (collateral_to_merge, bucket_lp)
    }
}