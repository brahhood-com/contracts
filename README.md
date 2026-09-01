# brahhood contracts

The contracts behind the 999, published so anyone can read what they are
agreeing to before they send a transaction.

This is the live set and nothing else. No deploy scripts, no tests, no
generated output, and none of the launchpad-era code the project has moved
on from. What is here is what is deployed.

## The set

**The collection**

| Contract | What it does |
|---|---|
| `genesis/Brah999.sol` | The 999 brahs. Hard capped, not upgradeable. Class is a pure function of the id: ancients 1 to 9, elders 10 to 99, commons 100 to 999. Every brah gets a wallet of his own at mint. |
| `genesis/GenesisMint.sol` | The adoption ladder. Nine tiers of a hundred commons, each costing more than the last, plus flat prices for elders and ancients. No whitelist, no cap, no deadline. |
| `genesis/RockModule.sol` | Activation. A rock burns $BRAH and buys a share of the spread. No rock, no brawl. Rocks reset when a brah changes hands, except an ancient's birthright coral. |
| `implementation/BrahTbaAccount.sol` | The wallet bound to each brah. Only the current owner can sign for it. |
| `registry/ERC6551Registry.sol` | Deterministic deployer for those wallets. |

**The fights**

| Contract | What it does |
|---|---|
| `genesis/BrawlEscrowV3.sol` | The brawl. Both calls are sealed as hashes, revealed together, and measured against a price that does not exist until after staking closes. Pari-mutuel, native ETH, one transaction, nothing to approve. |
| `brawl/CloutRegistry.sol` | The permanent record: accuracy per category, and forfeits kept well away from it. |
| `brawl/KeeperOracle.sol`, `brawl/IOracle.sol` | The fact source. Testnet publishes values through a keeper; the interface is what the escrow reads, so a real feed can replace it without touching the escrow. |

**The money**

| Contract | What it does |
|---|---|
| `genesis/BrahERC20.sol` | $BRAH. Minted once in the constructor, then no mint function, no roles, no owner, no proxy. Supply only ever goes down. |
| `genesis/WinningsVault.sol` | Where winnings live, keyed by brah, so a balance travels with the NFT when it sells. |
| `genesis/BuyAndBurn.sol` | The burn leg. ETH in, $BRAH out, destroyed in the same transaction. Nothing bought here can leave as $BRAH. |
| `genesis/TidePool.sol` | The vault you trade brahs through. Sell for instant $BRAH, swap for the next one, or snipe a specific number. |
| `genesis/ShellShop.sol` | Prepaid chat credit. Buy shells, talk to any brah. |

## Where the rake goes

A resolved brawl takes 10% of the losing pot and splits it four ways. It is
capped in the contract and can only ever be lowered.

```
                  losing pot
                      |
                  10% rake
                      |
     +----------+-----+-----+----------+
     |          |           |          |
    20%        30%         25%        25%
  winner's   every       protocol    bought
    brah     activated   treasury    and burned
   wallet      brah
```

Winners are paid their stake back plus a pro-rata share of what is left. The
rake only ever touches money that changed hands against them, so a payout
always beats a stake when there was a counterparty at all.

## Deployed

Testnet, chain id `46630`.

| Contract | Address | Deploy block |
|---|---|---|
| BrahERC20 | `0x1cb76033A7ADCeBa01e0be93a572Db734ae791a4` | 110313625 |
| Brah999 | `0x7dD7C0937633B6Fa16D44f9c6CEC08DcFCB21f0c` | 110317945 |
| GenesisMint | `0xF927A6B85A99d5A0a1c1424d22690cC27B458CFA` | 110318599 |
| RockModule | `0xf8Fea74ACBaCabdDA989875F1BbF55726f1B5C23` | 110318187 |
| BrawlEscrowV3 | `0xF2dC3E48898C572dC476d593f4aBc85EcEd6c3D0` | 111158847 |
| CloutRegistry | `0xc47Aef684A3B60201Af7fd2A55e1F38d4bcDf079` | 110319109 |
| KeeperOracle | `0x0206C3e6B051894CEa902Fc74B1Da6ECC71E8531` | 110319170 |
| WinningsVault | `0xEC34539DA1DbF83B46B62c4C957C76ec8ED3dee7` | 110318394 |
| BuyAndBurn | `0x403E108eA2Fe4a12400C788d93225997dE44CD14` | 110319226 |
| TidePool | `0xBa5c75072821FF0AC5e2e0dD5a3AD12368a52439` | 110319749 |
| ShellShop | `0x3ee4Be5D23e14ab2740b53E61FDec5ee4eEA7344` | 110319965 |
| ERC6551Registry | `0xeEd49E2a9902276b5692B4D325ba69dc6C193ea7` | 110317815 |
| BrahTbaAccount (impl) | `0x1fF7A478DC8192eF4ed8e185c04B980b9311ba4F` | 110317882 |

The escrow is the one address that moves. It has been redeployed a few
times as the brawl format settled, and older instances stay reachable so
anyone with a claim on an old brawl can still take their money out.

Mainnet is not live yet. This table moves when it is.

Testnet runs the same economics at a thousandth of the cost. One divisor
scales prices, supply and the rock ladder together, and the contracts refuse
to accept anything but 1 on mainnet, so a discount cannot be shipped by
accident.

## Building

Solidity `0.8.26`, optimizer on at 200 runs. The only dependency is
`@openzeppelin/contracts`.

```bash
npm install @openzeppelin/contracts
solc --optimize --optimize-runs 200 contracts/genesis/Brah999.sol
```

Point whichever toolchain you prefer at `contracts/`. There is no build
config in this repo on purpose: it holds source, not a pipeline.

## What the contracts will not do

Worth knowing before you read the code, because most of it exists to hold
these lines:

- **Nothing here is upgradeable.** No proxies anywhere in the set.
- **The token cannot be re-minted.** There is no mint function after the
  constructor, and no role that could add one.
- **The 999 cannot become 1000.** The cap is a constant in a contract with
  no admin who can raise it.
- **Class never touches the money.** It decides how often a brah fights.
  Only the rock decides how big his share is.
- **Nobody can be blocked from their own money.** A payee who refuses ETH
  delays their own payment and nothing else. Claims wait; they are never
  burned.
- **Brah wallets cannot stake**, and an owner cannot bet on his own brah's
  brawls, either side.

## Reporting something

Found a bug in here, open an issue. Found something that moves other
people's money, open a private security advisory on this repo instead and
give us a chance to fix it before it is public.

MIT licensed. See [LICENSE](LICENSE).
