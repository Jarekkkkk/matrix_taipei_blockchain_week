module test::mock_usdc {
    use sui::coin;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::option;
    use sui::url::{Self, Url};

    struct MOCK_USDC has drop {}

    fun init(witness: MOCK_USDC, ctx: &mut TxContext)
    {
        let (treasury_cap, metadata) = coin::create_currency<MOCK_USDC>(
            witness,
            6,
            b"USDC",
            b"USD coin",
            b"desc",
            option::some<Url>(url::new_unsafe_from_bytes(b"https://assets.coingecko.com/coins/images/6319/small/USD_Coin_icon.png?1547042389")),
            ctx
        );
        transfer::public_transfer(coin::mint(&mut treasury_cap, 1_000_000 * sui::math::pow(10, 6), ctx), tx_context::sender(ctx));
        transfer::public_freeze_object(metadata);
        transfer::public_share_object(treasury_cap);
    }

    #[test_only]
    public fun deploy_coin(ctx: &mut TxContext)
    {
        init(MOCK_USDC {}, ctx)
    }
}