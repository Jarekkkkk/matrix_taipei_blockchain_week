module test::mock_nft{
    use std::string::utf8;
    use std::ascii::{Self, String};

    use sui::package;
    use sui::display;
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::object::{Self, UID};

    struct MOCK_NFT has drop {}

    struct NFT has key, store{
        id: UID,
        img_url: String,
    }

    fun init(otw: MOCK_NFT, ctx: &mut TxContext){
        // display
        let publisher = package::claim(otw, ctx);
        let keys = vector[
            utf8(b"link"),
            utf8(b"image_url"),
            utf8(b"description"),
            utf8(b"project_url"),
        ];
        let values = vector[
            utf8(b"https://suidoubashi.io/vest"),
            utf8(b"{img_url}"),
            utf8(b"VSDB NFT is used for governance. Any SDB holders can lock their tokens for up to 24 weeks to receive NFTs. NFT holders gain access to the ecosystem and enjoy additional benefits for becoming SuiDouBashi members !"),
            utf8(b"https://suidoubashi.io"),
        ];
        let display = display::new_with_fields<NFT>(&publisher, keys, values, ctx);
        display::update_version(&mut display);

        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::public_transfer(display, tx_context::sender(ctx));
    }

    public fun new(ctx: &mut TxContext):NFT{
        NFT{
            id: object::new(ctx),
            img_url: ascii::string(b"ipfs://bafybeibwg7a52iydiu46ygp27j2m4yasrkbkigs2stbrhc6d75k5qxivcm")
        }
    }

    #[test_only]
    public fun deploy_nft(ctx: &mut TxContext)
    {
        init(MOCK_NFT {}, ctx)
    }
}