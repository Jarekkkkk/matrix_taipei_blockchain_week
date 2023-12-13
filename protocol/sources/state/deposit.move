module protocol::deposit{
    use sui::table::{Self, Table};
    use sui::tx_context::TxContext;

    use math::mathu256;
    use math::wad;
    use protocol::helpers;

    const SIZE: u64 = 8192;
    const WAD: u256 = 1_000_000_000_000_000_000;
    const MAX_FENWICK_INDEX: u64 = 7_388;

    const E_MUST_ZERO: u64 = 1;

    friend protocol::pool;

    // [data structure] Fenwick tree
    struct DepositState has store{
        // max szie of Fenwick Tree is 8193 ( 2**13 + dummy value: 1)
        tree: Table<u64, Deposit>
    }

    struct Deposit has store, drop{
        value: u256,
        scaling: u256
    }

    public fun value(deposit: &Deposit):u256 {deposit.value}
    public fun scaling(deposit: &Deposit):u256 {deposit.scaling}

    // public fun values(self: &DepositState): &vector<u256>{
    //     &self.values
    // }

    // public fun scaling(self: &DepositState): &vector<u256>{
    //     &self.scaling
    // }

    /// initialize all the 8193 values in BITree[] as 0.
    public(friend) fun default_deposit_state(ctx: &mut TxContext): DepositState{
        let tree = table::new<u64, Deposit>(ctx);
        let i = 0;
        // while( i < 8193 ){
        //     table::push_back(&mut values, 0);
        //     table::push_back(&mut scaling, 0);
        //     i = i + 1;
        // };
        DepositState{
            tree
        }
    }

    public fun unscaled_add(
        deposit_state: &mut DepositState,
        index: u64,
        unscaled_add_amount: u256
    ){
        index = index + 1;

        let _value = 0;
        let _scaling = 0;
        let _new_value = 0;

        while(index <= SIZE){
            check_and_init_index(deposit_state, index);

            let deposit = table::borrow_mut(&mut deposit_state.tree, index);

            _value = deposit.value;
            _scaling = deposit.scaling;

            // Compute the new _value to be put in location index_
            _new_value = _value + unscaled_add_amount;

            // Update unscaledAddAmount to propogate up the Fenwick tree
            // Note: we can't just multiply addAmount_ by _scaling[i_] due to rounding
            // We need to track the precice change in values[i_] in order to ensure
            // obliterated indices remain zero after subsequent adding to related indices
            // if _scaling==0, the actual scale _value is 1, otherwise it is _scaling
            if(_scaling != 0) unscaled_add_amount = wad::wmul(_new_value, _scaling) - wad::wmul(_value, _scaling);
            deposit.value = _new_value;

            index = index + (lsb((index as u256)) as u64)
        }
    }

    fun lsb(
        i_: u256
    ): u256{
        assert!(i_ > 0, E_MUST_ZERO);

        // "i & (-i)"
        i_ & ((i_ ^ 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) + 1)
    }


    // Finds index and sum of first bucket that EXCEEDS the given sum
    public fun find_index_and_sum_of_sum(
        deposit_state: &DepositState,
        target_sum: u256
    ):(u64, u256, u256){
        let i = 4096;
        let running_scale = WAD;

        let sum_index = 0_u64;
        let sum_index_sum = 0_u256;
        let sum_index_scale = 0_u256;

        let lowrer_index_sum: u256 = 0;
        let _cur_index: u64 = 0;
        let _value: u256 = 0;
        let _scaling: u256 = 0;
        let _scaled_value: u256 = 0;

        while(i > 0){
            _cur_index = sum_index + i;

            let deposit = if(table::contains(&deposit_state.tree, _cur_index)){
                table::borrow(&deposit_state.tree, _cur_index)
            }else{
                let deposit = Deposit{
                        value: 0,
                        scaling: 0
                    };
                &deposit
            };

            _value = deposit.value;
            _scaling = deposit.scaling;

            // Compute sum up to sumIndex_ + i
            let acc = if(_scaling != 0) mathu256::mul_div(running_scale * _scaling, _value, 1000000000000000000000000000000000000) else wad::wmul(running_scale, _value);

            _scaled_value = lowrer_index_sum + acc;

            if(_scaled_value < target_sum){
                // Target _value is too small, need to consider increasing sumIndex_ still
                if(_cur_index <= MAX_FENWICK_INDEX){
                    // sumIndex_ + i is in range of Fenwick prices. Target index has this bit set to 1.
                    sum_index = _cur_index;
                    lowrer_index_sum = _scaled_value;
                };
            }else{
                // Target index has this bit set to 0
                // _scaling == 0 means scale factor == 1, otherwise scale factor == _scaling
                if(_scaling != 0) running_scale = wad::floorWmul(running_scale, _scaling);

                // Current scaledValue is <= targetSum_, it's a candidate _value for sumIndexSum_
                sum_index_sum = _scaled_value;
                sum_index_scale = running_scale;
            };
            // Shift i to next less significant bit
            i = i >> 1;
        };
        (sum_index, sum_index_sum, sum_index_scale)
    }

    public fun find_index_of_sum(
        deposit_state: &DepositState,
        sum: u256
    ): u64{
        let (sum_index, _, _) = find_index_and_sum_of_sum(deposit_state, sum);
        sum_index
    }


     // Scale values in the tree from the index provided, upwards.
     public fun mult(
        deposit_state: &mut DepositState,
        index: u64,
        factor: u256
    ){
        index = index + 1;

        let sum = 0;
        let _value = 0;
        let _scaling = 0;
        let bit = (lsb((index as u256)) as u64);

        // Starting with the LSB of index, we iteratively move up towards the MSB of SIZE
        // Case 1:     the bit of index_ is set to 1.  In this case, the entire subtree below index_
        //             is scaled.  So, we include factor_ into scaling[index_], and remember in sum how much
        //             we increased the subtree by, so that we can use it in case we encounter 0 bits (below).
        // Case 2:     The bit of index_ is set to 0.  In this case, consider the subtree below the node
        //             index_+bit. The subtree below that is not entirely scaled, but it does contain the
        //             subtree what was scaled earlier.  Therefore: we need to increment it's stored _value
        //             (in sum) which was set in a prior interation in case 1.
        while(bit < SIZE){
             if ((bit & index) != 0) {
                // Case 1 as described above
                check_and_init_index(deposit_state, index);

                let deposit = table::borrow_mut(&mut deposit_state.tree, index);
                _value = deposit.value;
                _scaling = deposit.scaling;

                // Calc sum, will only be stored in range parents of starting node, index
                if (_scaling != 0) {
                    // Note: we can't just multiply by factor_ - 1 in the following line, as rounding will
                    // cause obliterated indices to have nonzero values.  Need to track the actual
                    // precise delta in the _value array
                    let scaled_factor = wad::wmul(factor, _scaling);

                    sum = sum + wad::wmul(scaled_factor, _value) - wad::wmul(_scaling, _value);

                    // Apply scaling to all range parents less then starting node, index
                    deposit.scaling = scaled_factor;
                } else {
                    // this node's scale factor is 1
                    sum = sum + wad::wmul(factor, _value) - _value;
                    deposit.scaling = factor;
                };
                // Unset the bit in index to continue traversing up the Fenwick tree
                index = index - bit;
            } else {
                // Case 2 above.  superRangeIndex is the index of the node to consider that
                //                contains the sub range that was already scaled in prior iteration
                let super_range_index = index + bit;

                check_and_init_index(deposit_state, super_range_index);

                let deposit = table::borrow_mut(&mut deposit_state.tree, super_range_index);
                _value = value(deposit);
                _scaling = scaling(deposit);

                _value = deposit.value + sum;
                deposit.value = _value;

                _scaling = deposit.scaling;

                // Need to be careful due to rounding to propagate actual changes upwards in tree.
                // sum is always equal to the actual _value we changed deposits_.values[] by
                if (_scaling != 0) sum = wad::wmul(_value, _scaling) - wad::wmul(_value - sum, _scaling);
            };
            // consider next most significant bit

            bit = bit << 1;
        }
    }


     // Get prefix sum of all indexes from provided index downwards.
     public fun prefix_sum(
        deposit_state: &DepositState,
        sum_index: u64
     ):u256{
        sum_index = sum_index + 1;

        let sum = 0_u256;

        let running_scale = WAD;
        let j = SIZE;
        let index = 0_u64;

        // Used to terminate loop.  We don't need to consider final 0 bits of sumIndex_
        let index_lsb = (lsb((sum_index as u256)) as u64);
        let _cur_index = 0_u64;

        while (j >= index_lsb){
            _cur_index = index + j;

            // Skip considering indices outside bounds of Fenwick tree
            if(_cur_index > SIZE) continue;

            let deposit = if(table::contains(&deposit_state.tree, _cur_index)){
                table::borrow(&deposit_state.tree, _cur_index)
            }else{
                let deposit = Deposit{
                        value: 0,
                        scaling: 0
                    };
                &deposit
            };

            // We are considering whether to include node index + j in the sum or not.  Either way, we need to scaling[index + j],
            // either to increment sum_ or to accumulate in runningScale
            let scaled = deposit.scaling;

            if (j & sum_index != 0) {
                // node index + j of tree is included in sum
                let value = deposit.value;

                // Accumulate in sum_, recall that scaled==0 means that the scale factor is actually 1
                let acc = if(scaled != 0) mathu256::mul_div(running_scale * scaled, value, 1000000000000000000000000000000000000) else wad::wmul(running_scale, value);
                sum = sum + acc;

                // Build up index bit by bit
                index = _cur_index;

                // terminate if we've already matched sum_index
                if (index == sum_index) break;
            } else {
                // node is not included in sum, but its scale needs to be included for subsequent sums
                if (scaled != 0) running_scale = wad::floorWmul(running_scale, scaled);
            };
            // shift j to consider next less signficant bit

            j = j >> 1;
        };

        sum
     }

     // Decrease a node in the `FenwickTree` at an index.
     public fun unscaled_remove(
        deposit_state: &mut DepositState,
        index: u64,
        unscaled_remove_amount: u256
     ){
        index = index + 1;

         // We operate with unscaledRemoveAmount_ here instead of a scaled quantity to avoid duplicate computation of scale factor
        // (thus redundant iterations through the Fenwick tree), and ALSO so that we can set the value of a given deposit exactly
        // to 0.

        while(index <= SIZE){
            // Decrement deposits_ at index_ for removeAmount, storing new _value in _value
            check_and_init_index(deposit_state, index);

            let deposit = table::borrow_mut(&mut deposit_state.tree, index);

            let _value = deposit.value - unscaled_remove_amount;
            deposit.value = _value;
            let _scaling = deposit.scaling;

            // If scale factor != 1, we need to adjust unscaledRemoveAmount by scale factor to adjust values further up in tree
            // On the line below, it would be tempting to replace this with:
            // unscaledRemoveAmount_ = Maths.wmul(unscaledRemoveAmount, _scaling).  This will introduce nonzero values up
            // the tree due to rounding.  It's important to compute the actual change in deposits_.values[index_]
            // and propogate that upwards.
            if(_scaling != 0) unscaled_remove_amount = wad::wmul(_value + unscaled_remove_amount, _scaling) - wad::wmul(_value, _scaling);

            // Traverse upward through the "update" path of the Fenwick tree
            index = index + (lsb((index as u256)) as u64)
        };
     }

     // Scale tree starting from given index.
     public fun scale(
        deposit_state: &DepositState,
        index: u64
     ): u256{
        index = index + 1;

        let scaled = WAD;
        while(index <= SIZE){
            let deposit = if(table::contains(&deposit_state.tree, index)){
                table::borrow(&deposit_state.tree, index)
            }else{
                let deposit = Deposit{
                        value: 0,
                        scaling: 0
                    };
                &deposit
            };
            // Traverse up through Fenwick tree via "update" path, accumulating scale factors as we go
            let scaling = deposit.scaling;
            // scaling==0 means actual scale factor is 1
            if(scaling != 0) scaled = wad::wmul(scaled, scaling);
            index = index + (lsb((index as u256)) as u64);
        };
        scaled
     }

     /// sum of all deposits.
     public fun tree_sum(
        deposit_state: &DepositState
     ): u256{
        // In a scaled Fenwick tree, sum is at the root node and never scaled
        let deposit = if(table::contains(&deposit_state.tree, SIZE)){
            table::borrow(&deposit_state.tree, SIZE)
        }else{
            let deposit = Deposit{
                    value: 0,
                    scaling: 0
                };
            &deposit
        };
        deposit.value
     }

     // Returns deposit value for a given deposit index.
     public fun value_at(
        deposit_state: &DepositState,
        index: u64
     ):u256{
        // Get unscaled value at index and multiply by scale
        wad::wmul(unscaled_value_at(deposit_state, index), scale(deposit_state, index))
     }

     // Returns unscaled (deposit without interest) deposit value for a given deposit index.
     public fun unscaled_value_at(
        deposit_state: &DepositState,
        index: u64
     ): u256{
        index = index + 1;

        let j = 1;
        // Returns the unscaled value at the node. We consider the unscaled value for two reasons:
        // 1- If we want to zero out deposit in bucket, we need to subtract the exact unscaled value
        // 2- We may already have computed the scale factor, so we can avoid duplicate traversal

        let deposit = if(table::contains(&deposit_state.tree, index)){
            table::borrow(&deposit_state.tree, index)
        }else{
            let deposit = Deposit{
                    value: 0,
                    scaling: 0
                };
            &deposit
        };

        let unscaled_deposit_value = deposit.value;
        let _cur_index = 0;
        let _value = 0;
        let _scaling = 0;

        while( j & index == 0 ){
            _cur_index = index - j;

            let deposit = if(table::contains(&deposit_state.tree, _cur_index)){
                table::borrow(&deposit_state.tree, _cur_index)
            }else{
                let deposit = Deposit{
                    value: 0,
                    scaling: 0
                };
                &deposit
            };

            _value = deposit.value;
            _scaling = deposit.scaling;

            unscaled_deposit_value = unscaled_deposit_value - if(_scaling != 0) wad::wmul(_scaling, _value) else _value;

            j = j << 1;
        };

        unscaled_deposit_value
     }

     // Returns `LUP` for a given debt value (capped at min bucket price).
     public fun get_Lup(
        deposit_state: &DepositState,
        debt: u256
     ): u256{
        helpers::price_at(find_index_of_sum(deposit_state, debt))
     }

     fun check_and_init_index(self: &mut DepositState, index: u64){
        if(!table::contains(&self.tree, index)){
            table::add(&mut self.tree, index, Deposit{value: 0, scaling: 0})
        };
     }
}