module protocol::event{
    use sui::event::emit;
    use sui::object::ID;

    // [POOLCREATED]
    struct PoolCreated<phantom X, phantom Y> has copy, drop{
        pool: address,
        creator: address
    }
    public fun pool_created <X, Y>(pool: address, creator: address){
        emit(
            PoolCreated<X,Y>{
                pool,
                creator
            }
        )
    }

    // [AddQuoteToken]
    struct AddQuoteToken has copy, drop{
        lender: ID,
        index: u64,
        amount: u256,
        lp_awarded: u256,
        lup: u256
    }

    public fun add_quote_token(
        lender: ID,
        index: u64,
        amount: u256,
        lp_awarded: u256,
        lup: u256
    ){
        emit(
            AddQuoteToken{
                lender,
                index,
                amount,
                lp_awarded,
                lup
            }
        )
    }
    struct MoveQuoteToken has copy, drop{
        lender: ID,
        from_index: u64,
        to_index: u64,
        amount: u256,
        lp_redeemed_from: u256,
        lp_awarded_to: u256,
        lup: u256
    }
    public fun move_quote_token(
        lender: ID,
        from_index: u64,
        to_index: u64,
        amount: u256,
        lp_redeemed_from: u256,
        lp_awarded_to: u256,
        lup: u256
    ){
       emit(
            MoveQuoteToken{
                lender,
                from_index,
                to_index,
                amount,
                lp_redeemed_from,
                lp_awarded_to,
                lup
            }
       )
    }
    struct RemoveQuoteToken has copy, drop{
        lender: ID,
        index: u64,
        amount: u256,
        lp_redeemed: u256,
        lup: u256
    }
    public fun remove_quote_token(
        lender: ID,
        index: u64,
        amount: u256,
        lp_redeemed: u256,
        lup: u256
    ){
       emit(
            RemoveQuoteToken{
                lender,
                index,
                amount,
                lp_redeemed,
                lup
            }
       )
    }

    struct AddCollateral has copy, drop{
        lender: ID,
        index: u64,
        amount_to_added: u256,
        bucket_lp: u256
    }
    public fun add_collateral(lender: ID, index: u64, amount_to_added: u256, bucket_lp: u256){
        emit(
            AddCollateral{
                lender,
                index,
                amount_to_added,
                bucket_lp
            }
        )
    }

    struct RemoveCollateral has copy, drop{
        lender: ID,
        index: u64,
        removed_amount: u256,
        redeemed_lp: u256
    }
    public fun remove_collateral(lender: ID, index: u64, removed_amount: u256, redeemed_lp: u256){
        emit(
            RemoveCollateral{
                lender,
                index,
                removed_amount,
                redeemed_lp
            }
        )
    }

    struct AddCollateralNFT has copy, drop{
        lender: ID,
        index: u64,
        num_of_nft: u64,
        bucket_lp: u256
    }
    public fun add_collateral_nft(lender: ID, index: u64, num_of_nft: u64, bucket_lp: u256){
        emit(
            AddCollateralNFT{
                lender,
                index,
                num_of_nft,
                bucket_lp
            }
        )
    }

    struct RemoveCollateralNFT has copy, drop{
        lender: ID,
        index: u64,
        no_of_nft: u64,
        redeemed_lp: u256
    }
    public fun remove_collateral_nft(lender: ID, index: u64, no_of_nft: u64, redeemed_lp: u256){
        emit(
            RemoveCollateralNFT{
                lender,
                index,
                no_of_nft,
                redeemed_lp
            }
        )
    }

    struct MergeOrRemoveCollateral has copy, drop{
        lender: ID,
        collateral_merged: u256,
        to_index_lp: u256
    }
    public fun merge_or_remove_collateral(lender: ID, collateral_merged: u256, to_index_lp: u256){
        emit(
            MergeOrRemoveCollateral{
                lender,
                collateral_merged,
                to_index_lp
            }
        )
    }

    // ResetInterestRate
    struct ResetInterestRate has copy, drop{
        prev_rate: u256,
        new_rate: u256
    }
    public fun reset_interest_rate(prev_rate: u256, new_rate: u256){
        emit(
            ResetInterestRate{
                prev_rate,
                new_rate
            }
        )
    }

    struct UpdateInterestRate has copy, drop{
        prev_rate: u256,
        new_rate: u256
    }
    public fun update_interest_rate(prev_rate: u256, new_rate: u256){
        emit(
            ResetInterestRate{
                prev_rate,
                new_rate
            }
        )
    }

    struct DrawDebt has copy, drop{
        borrower: address,
        amount_borrowed: u256,
        collateral_pledged: u256,
        lup: u256
    }
    public fun draw_debt(borrower: address, amount_borrowed: u256, collateral_pledged: u256, lup: u256){
        emit(
            DrawDebt{
                borrower,
                amount_borrowed,
                collateral_pledged,
                lup
            }
        )
    }
    struct RepayDebt has copy, drop{
        borrower: address,
        quote_to_pay: u256,
        collateral_amonut_to_pull: u256,
        lup: u256
    }

    public fun repay_debt(borrower: address, quote_to_pay: u256, collateral_amonut_to_pull: u256, lup: u256){
        emit(
            RepayDebt{
                borrower,
                quote_to_pay,
                collateral_amonut_to_pull,
                lup
            }
        )
    }

    struct DrawDebtNFT has copy, drop{
        borrower: address,
        amount_borrowed: u256,
        collateral_pledged: vector<ID>,
        lup: u256
    }
    public fun draw_debt_nft(borrower: address, amount_borrowed: u256, collateral_pledged: vector<ID>, lup: u256){
        emit(
            DrawDebtNFT{
                borrower,
                amount_borrowed,
                collateral_pledged,
                lup
            }
        )
    }

    struct BucketTakeLPAwarded has copy, drop{
        taker: address,
        kicker: address,
        lp_awarded_taker: u256,
        lp_awarded_kicker: u256
    }

    public fun bucket_take_lp_awarded(taker: address, kicker: address, lp_awarded_taker: u256, lp_awarded_kicker: u256){
        emit(
            BucketTakeLPAwarded{
                taker,
                kicker,
                lp_awarded_taker,
                lp_awarded_kicker
            }
        )
    }

    struct Kick has copy, drop{
        borrower: address,
        debt: u256,
        collateral: u256,
        bond: u256
    }
    public fun kick(borrower: address, debt: u256, collateral: u256, bond: u256){
        emit(
            Kick{
                borrower,
                debt,
                collateral,
                bond
            }
        )
    }

    struct KickReserveAuction has copy, drop{
        claimable_reserve_remaining: u256,
        auction_price: u256,
        current_burn_epoch: u64
    }
    public fun kick_reserve_auction(
        claimable_reserve_remaining: u256,
        auction_price: u256,
        current_burn_epoch: u64
    ){
        emit(
            KickReserveAuction{
                claimable_reserve_remaining,
                auction_price,
                current_burn_epoch
            }
        )
    }

    struct ReserveAuction has copy, drop{
        claimable_reserve_remaining: u256,
        auction_price: u256,
        current_burn_epoch: u64
    }
    public fun reserve_auction(claimable_reserve_remaining: u256, auction_price: u256, current_burn_epoch: u64){
        emit(
            ReserveAuction{
                claimable_reserve_remaining,
                auction_price,
                current_burn_epoch
            }
        )
    }

    struct BondWithdrawn has copy, drop{
        kicker: address,
        bond_amount: u256
    }
    public fun bond_withdrawn(kicker: address, bond_amount: u256){
        emit(
            BondWithdrawn{
                kicker,
                bond_amount
            }
        )
    }

    struct Take has copy, drop{
        borrower: address,
        quote: u256,
        collateral: u256,
        bond_change: u256,
        is_rewarded: bool
    }
    public fun take(
        borrower: address,
        quote: u256,
        collateral: u256,
        bond_change: u256,
        is_rewarded: bool
    ):Take{
        Take{
            borrower,
            quote,
            collateral,
            bond_change,
            is_rewarded
        }
    }

    struct BucketTake has copy, drop{
        borrower: address,
        index: u64,
        amount: u256,
        collateral: u256,
        bond_change: u256,
        is_reward: bool
    }
    public fun bucket_take(borrower: address, index: u64, amount: u256, collateral: u256, bond_change: u256, is_reward: bool){
        emit(
            BucketTake{
                borrower,
                index,
                amount,
                collateral,
                bond_change,
                is_reward
            }
        )
    }

    struct AuctionSettle has copy, drop{
        borrower: address,
        remaining_collateral: u256,
    }
    public fun auction_settle(borrower: address, remaining_collateral: u256){
        emit(
            AuctionSettle{
                borrower,
                remaining_collateral
            }
        )
    }

    struct AuctionNFTSettle has copy, drop{
        borrower: address,
        remaining_collateral: u256,
        lp: u256,
        index: u64
    }
    public fun auction_nft_settle(borrower: address, remaining_collateral: u256, lp: u256, index: u64){
        emit(
            AuctionNFTSettle{
                borrower,
                remaining_collateral,
                lp,
                index
            }
        )
    }

    struct BucketBankruptcy has copy, drop{
        index: u64,
        lp_forfeited: u256
    }

    public fun bucket_bankruptcy(index: u64, lp_forfeited: u256){
        emit(
            BucketBankruptcy{
                index,
                lp_forfeited
            }
        )
    }

    struct Settle has copy, drop{
        borrower: address,
        settled_debt: u256
    }

    public fun settle(borrower: address, settled_debt: u256){
        emit(
            Settle{
                borrower,
                settled_debt
            }
        )
    }

    struct LoanStamped has copy, drop{
        borrower: address
    }

    public fun laon_stamped(borrower: address){
        emit(
            LoanStamped{
                borrower
            }
        )
    }


}