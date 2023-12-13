module test::utils{
    use sui::clock::Clock;
    use sui::math;

    use protocol::pool::{Self, Pool};
    use protocol::helpers;
    use math::wad;

    public fun cal_desired_collateral_amount<Quote, Collateral>(
        pool: &Pool<Quote, Collateral>,
        debt_to_draw: u64,
        // Usually Over 100% when taking account origination fee
        collateralization: u256,
        decimals: u8,
        clock:& Clock
    ):(u64, u64){
        let (_,_,_,_,_, lup_index) = pool::pool_prices_info(pool, clock);
        let start_bucket_index = 2000;
        let debt_to_draw = ( debt_to_draw as u256 )* pool::quote_scale(pool);

        if(lup_index == 0) lup_index = start_bucket_index;
        let lup = helpers::price_at(lup_index);
        let col_scale = pool::collateral_scale(pool);
        if(col_scale == 1) col_scale = 1000000000000000000;
        let collateral_pledged = wad::wmul(wad::wdiv(debt_to_draw, lup), collateralization) / col_scale * col_scale;

        while(wad::wdiv(wad::wmul(collateral_pledged, lup), debt_to_draw) < collateralization){
            collateral_pledged = collateral_pledged + col_scale;
        };

        let factor = (math::pow(10, 18 - decimals) as u256);

        (lup_index + 4, ((collateral_pledged / factor) as u64))
    }
}