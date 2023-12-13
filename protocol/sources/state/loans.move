module protocol::loans{
    use std::vector as vec;
    use sui::table::{Self, Table};

    use math::sd59x18;
    use math::wad;
    use math::int;

    use protocol::loans;

    friend protocol::pool;
    friend protocol::borrower;
    friend protocol::kicker;

    const ROOT_INDEX: u64 = 1;

    const E_ZERO_THRESHOLD_PRICE: u64 = 1;

    struct LoansState has store{
        /// `Max Heap` data structure (complete binary tree) the root node is the loan with the highest threshold price (`TP`)
        ///  at a given time. The heap is represented as an array, where the first element is a dummy element (`Loan(address(0), 0)`) and the first
        ///  value of the heap starts at index `1`, `ROOT_INDEX`. The threshold price of a loan's parent is always greater than or equal to the
        ///  threshold price of the loan.
        loans: vector<Loan>,
        /// mapping borrower address to loans index
        indices: Table<address, u64>,
        /// mapping borrower address to borrower struct data
        borrowers: Table<address, Borrower>
    }
    public(friend) fun default_loans_state(ctx: &mut sui::tx_context::TxContext): LoansState{
        LoansState {
                loans: vec::singleton(Loan{ borrower: @0x00, threshold_price: 0}),
                indices: table::new<address, u64>(ctx),
                borrowers: table::new<address, Borrower>(ctx)
        }
    }

    struct Loan has store, copy, drop{
        borrower:address,
        threshold_price: u256
    }
    public fun loan_borower(loan: &Loan): address { loan.borrower }
    public fun loan_threshold_price(loan: &Loan):u256 { loan.threshold_price }

    //[VIEW]
    public fun loans(self: &LoansState): &vector<Loan>{
        &self.loans
    }
    public fun borrowers(self: &LoansState): &Table<address, Borrower>{
        &self.borrowers
    }
    public fun borrower_contains(self: &LoansState, borrower:address): bool{
        table::contains(&self.borrowers, borrower)
    }
    public fun borrower(self: &LoansState, borrower: address):&Borrower{
        table::borrow(&self.borrowers, borrower)
    }
    public fun borrower_indices(self: &LoansState, borrower: address): u64{
        if(table::contains(&self.indices, borrower)) *table::borrow(&self.indices, borrower) else 0
    }

    // [MUT]
    public (friend) fun borrowers_mut(self: &mut LoansState): &mut Table<address, Borrower>{
        &mut self.borrowers
    }
    public (friend) fun borrower_mut(self: &mut LoansState, borrower: address):&mut Borrower{
        table::borrow_mut(&mut self.borrowers, borrower)
    }


    struct Borrower has store, drop{
        // [WAD] Borrower debt time-adjusted as if it was incurred upon first loan of pool
        t0_debt: u256,
        // [WAD] Collateral deposited by borrower.
        collateral: u256,
        // [WAD] Np to Tp ratio at the time of last borrow or pull collateral.
        np_tp_ratio: u256
    }
    public(friend) fun new_borrower(): Borrower {
        Borrower{
            t0_debt:0,
            collateral:0,
            np_tp_ratio: 0
        }
    }
    // [VIEW]
    public fun borrower_state(borrower: &Borrower):(u256, u256, u256){
        (borrower.t0_debt, borrower.collateral, borrower.np_tp_ratio)
    }
    public fun t0_debt(borrower: &Borrower): u256 { borrower.t0_debt }
    public fun collateral(borrower: &Borrower): u256 { borrower.collateral }
    public fun np_tp_ratio(borrower: &Borrower): u256 { borrower.np_tp_ratio }
    // [MUT]
    public (friend) fun add_collateral(borrower: &mut Borrower, value: u256){
        borrower.collateral = borrower.collateral + value;
    }
    public (friend) fun remove_collateral(borrower: &mut Borrower, value: u256){
        borrower.collateral = borrower.collateral - value;
    }
    public (friend) fun update_collateral(borrower: &mut Borrower, value: u256){
        borrower.collateral = value;
    }
    public (friend) fun add_t0_debt(borrower: &mut Borrower, value: u256){
        borrower.t0_debt = borrower.t0_debt + value;
    }
    public (friend) fun remove_t0_debt(borrower: &mut Borrower, value: u256){
        borrower.t0_debt = borrower.t0_debt - value;
    }
    public (friend) fun update_t0_debt(borrower: &mut Borrower, value: u256){
        borrower.t0_debt = value;
    }

    public fun update(
        loans_state: &mut LoansState,
        borrower_address: address,
        pool_rate: u256,
        in_auction: bool,
        np_tp_ratio_update: bool
     ){
        let borrower = loans::borrower(loans_state, borrower_address);
        let active_borrower = borrower.t0_debt != 0 && borrower.collateral != 0;

        let t0_threshold_price = if(active_borrower) wad::wdiv(borrower.t0_debt, borrower.collateral) else 0;

        // loan not in auction, update threshold price and position in heap
        if (!in_auction) {
            // get the loan id inside the heap
            if(!table::contains(&loans_state.indices, borrower_address)) table::add(&mut loans_state.indices, borrower_address, 0);
            let loan_id = *table::borrow(&loans_state.indices, borrower_address);
            if (active_borrower) {
                // revert if threshold price is zero
                if (t0_threshold_price == 0) abort E_ZERO_THRESHOLD_PRICE;

                // update heap, insert if a new loan, update loan if already in heap
                upsert_(loans_state, borrower_address, loan_id, t0_threshold_price);

                // if loan is in heap and borrwer is no longer active (no debt, no collateral) then remove loan from heap
            } else if (loan_id != 0) {
                remove(loans_state, borrower_address, loan_id);
            }
        };

        // update Np to Tp ratio of borrower
        if (np_tp_ratio_update) {
            // NP(loan's liquidation price.) = TP(1.04 + r^0.5 / 2)
            // get the value between (1,2)
            loans::borrower_mut(loans_state, borrower_address).np_tp_ratio = 1_040_000_000_000_000_000 + int::as_u256(&sd59x18::sqrt(int::from_u256(pool_rate))) / 2;
        };
     }

    // Moves a `Loan` up the heap.
    fun bubble_up_(
        loan_state: &mut LoansState,
        loan: Loan,
        index: u64
    ){
        let count = vec::length(&loan_state.loans);

        if(index == ROOT_INDEX || loan.threshold_price <= vec::borrow(&loan_state.loans, index / 2).threshold_price){
            insert_(loan_state, loan, index, count);
        }else{
            let loan_ = *vec::borrow(&loan_state.loans, index / 2);
            insert_(loan_state, loan_, index, count);
            bubble_up_(loan_state, loan, index / 2 );
        }
    }

    // Moves a `Loan` down the heap.
    fun bubble_down_(
        loan_state: &mut LoansState,
        loan: Loan,
        index: u64
    ){
        // Left child index.
        let child_index = index * 2;

        let count = vec::length(&loan_state.loans);
        if(count <= child_index){
            insert_(loan_state, loan, index, count);
        }else{
            let largest_child = *vec::borrow(&loan_state.loans, child_index);

            if(count > child_index + 1 && vec::borrow(&loan_state.loans, child_index + 1).threshold_price > largest_child.threshold_price){
                child_index = child_index + 1;
                largest_child = *vec::borrow(&loan_state.loans, child_index);
            };

            if(largest_child.threshold_price <= loan.threshold_price){
                insert_(loan_state, loan, index, count);
            }else{
                insert_(loan_state, largest_child, index, count);
                bubble_down_(loan_state, loan, index);
            }
        };
    }

    // Inserts a `Loan` in the heap.
    fun insert_(
        loan_state: &mut LoansState,
        loan: Loan,
        index: u64,
        count: u64
    ){
        if(index == count){
            vec::push_back(&mut loan_state.loans, loan)
        }else{
            *vec::borrow_mut(&mut loan_state.loans, index) = loan
        };

        if(!table::contains(&loan_state.indices, loan.borrower)){
            table::add(&mut loan_state.indices, loan.borrower, index);
        }else{
            *table::borrow_mut(&mut loan_state.indices, loan.borrower) = index;
        };
    }

    // Removes `Loan` from heap given borrower address.
    public (friend) fun remove(
        loan_state: &mut LoansState,
        borrower: address,
        index: u64
    ){
        table::remove(&mut loan_state.indices, borrower);
        let tail_index = vec::length(&loan_state.loans) - 1;

        if(index == tail_index){
            vec::pop_back(&mut loan_state.loans);
        }else{
            let tail = *vec::borrow(&loan_state.loans, tail_index);
            vec::pop_back(&mut loan_state.loans);
            bubble_up_(loan_state, tail, index);
            let loan = *vec::borrow(&loan_state.loans, index);
            bubble_down_(loan_state, loan, index);
        }
    }


     // Performs an insert or an update dependent on borrowers existance.
     fun upsert_(
        loan_state: &mut LoansState,
        borrower: address,
        index: u64,
        threshold_price: u256
     ){
        // Loan exists, update in place.
        if(index != 0){
            let current_loan = *vec::borrow(&loan_state.loans, index);
            if(current_loan.threshold_price > threshold_price){
                current_loan.threshold_price = threshold_price;
                bubble_down_(loan_state, current_loan, index);
            }else{
                current_loan.threshold_price = threshold_price;
                bubble_up_(loan_state, current_loan, index);
            }
        }else{
            // New loan, insert with the last index and sort it in bubble up
            let len = vec::length(&loan_state.loans);
            bubble_up_(loan_state, Loan{borrower, threshold_price}, len);
        }
     }

     // VIEW
     public fun get_by_index(
        loan_state: &LoansState,
        index: u64
     ):Loan{
        if(vec::length(&loan_state.loans) > index) *vec::borrow(&loan_state.loans, index) else Loan{ borrower: @0x00, threshold_price: 0}
     }

     public fun get_max(
        loan_state: &LoansState
     ):Loan{
        get_by_index(loan_state, ROOT_INDEX)
     }

     public fun no_of_loans(
        loan_state: &LoansState
     ): u64{
        vec::length(&loan_state.loans) - 1
     }
}