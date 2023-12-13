# matrix_SC

Automated Money Market

## published_address

- pacakge: 0x0570f269e1b0bd08aa96e17c851dc300f6a5a851041fefc0efda1a8815cd9fcd
- coin: 0xe04e38f99c316e42e7ca3d98898b662408b55bd80afa9dec187f452adfe16535
- nft: 0x8b2ff4a4cce408bfd7638c1f0c161ddb7049f06fbaf6279c1ea0f8b1db4f5b9e

## static object

- USDC

  - metadata: 0x3a16a4634cca81ffa13b751fcb9627eadf396e8f134c78dedbaa0959e7cd8b19
  - cap: 0x6f18bd25bb70b652489400199e42d1fc84ae2e88798450a45f46514a4d8d1cd5

- USDT

  - metadata: 0xfd8858d752f9a149277784a64c563cc1c6716ae408372d04223640dddd7d4c0f
  - cap: 0x7017fb8d5749be904539fcd11c5c247baf9eaae6fcf51f909a58e04c0609e293

- ETH
  - metadata: 0x2e11a9390b1ae91fdee007ba3592ccf939ae7e2a59aca7ef7af76cf1e5f78d48
  - cap: 0xd63842c9d3e5ad9428b9fe6261bf9a4adf226f12a0e4b3913da4c9d0ae4b9eef

## Global config

Testnet

```bash
set package 0x49ae5fe4c3ae5c9be19d962a52c53cc2b52aa078e643a26d5b17beb41e471485
set pool_reg 0x25f411d35f2d45ac37762ce06bd72c2b13e9bb8bc54b6bebbb9e10009de337e0
set coin 0xe04e38f99c316e42e7ca3d98898b662408b55bd80afa9dec187f452adfe16535
```

Devnet

```bash
set package 0x70a16896de4e0ceefd7513a8f19737310fc2e3e2073daf5831a121a0196d3ff1
set pool_reg 0xd6d5562b84bf0b0feb1649356dcdb5a106c73ce265e8d35e7f5871d0aa3ab327
set coin 0x8e642a330346be05a283ed0d2282b71e59ba61b273640f28c7cc606cabcf17f3
```

## Create Pool

- Token

```bash
sui client call --gas-budget 100000000 --package $package --module pool_factory --function create_token_pool --args $pool_reg 0x3a16a4634cca81ffa13b751fcb9627eadf396e8f134c78dedbaa0959e7cd8b19 0x6f18bd25bb70b652489400199e42d1fc84ae2e88798450a45f46514a4d8d1cd5 10000000000000000 --type-args $coin::mock_usdc::MOCK_USDC $coin::mock_usdt::MOCK_USDT
```

- NFT

```bash
pip install foobar
```

## Usage

```python
import foobar

# returns 'words'
foobar.pluralize('word')

# returns 'geese'
foobar.pluralize('goose')

# returns 'phenomenon'
foobar.singularize('phenomena')
```

## Contributing

Pull requests are welcome. For major changes, please open an issue first
to discuss what you would like to change.

Please make sure to update tests as appropriate.

## License

[MIT](https://choosealicense.com/licenses/mit/)
# matrix_taipei_blockchain_week
# matrix_taipei_blockchain_week
