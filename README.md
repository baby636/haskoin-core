# Haskoin

Haskoin is an implementation of the Bitcoin protocol in Haskell.

## Features

- Protocol message types (de-)serialization
- Bitcoin script interpreter
- Cryptographic ECDSA and hashing primitives
- Hierarchical Deterministic Wallet support (BIP32)
- Pay-to-script-hash (P2SH, BIP16) support
- Multisig transaction support
- JSON-RPC/Stratum client library
- Mnemonic keys (BIP39)

## Documentation

http://hackage.haskell.org/package/haskoin

## Installing from Cabal

You can install the latest stable version of the haskoin package automatically
through the cabal package manager:

```sh
# Install
cabal install haskoin
```

## Contributing

Commits are done through GitHub pull requests.

We do a lot of our technical discussions at the IRC channel #haskoin on
chat.freenode.net.

Code guidelines:

- 80 columns.
- 4 space indentation. No tabs.
- Follow the general style of the code, whenever it makes sense.
- Purity and type-safety are important.
