// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title BrahERC20
 * @notice $BRAH. Fair launch, and the bytecode is the proof:
 *           - Fixed supply, minted once in this constructor to the deployer,
 *             who seeds the pool in the same bundle. After that there is no
 *             mint function at all.
 *           - No roles, no owner, no proxy. Nothing here can be upgraded,
 *             paused, blacklisted or re-minted.
 *           - {burn} and {burnFrom} are the only supply changes left, and
 *             they only go down. Rocks burn here, the rake's burn leg burns
 *             here, tide pool churn burns here.
 */
contract BrahERC20 is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice The published supply, and the number the whitepaper quotes.
    ///         See {supplyDivisor} for why a test deployment's
    ///         `totalSupply()` can sit below it.
    uint256 public constant CANON_TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @dev The chain that pays canon. Same guard, same chain, as the one in
    ///      GenesisMint.
    uint256 public constant RH_MAINNET_CHAIN_ID = 4663;

    /**
     * @notice Divides the supply minted on this deployment. Always 1 on
     *         mainnet. Testnet runs 1000.
     *
     * GenesisMint has a price divisor that scales what a deployment charges
     * in ETH so the ladder can be walked with faucet money. This is the other
     * half: it scales what the deployment mints, so every $BRAH figure
     * downstream (the rock ladder, the tide pool's spot and delta, the pool
     * seed) scales with it and still describes the same economy.
     *
     * Both sides move together or not at all. A rock costs a fraction of the
     * supply, not a count: 66,666 of a billion and 66.666 of a million are
     * the same claim on the same token, and a pool seeded with a thousandth
     * of the supply against a thousandth of the ETH opens at canon price.
     * Scale one side only and the test deployment stops rehearsing anything,
     * which is why one divisor is fed to this contract, to RockModule and to
     * the tide curve instead of being typed three times.
     *
     * Mainnet cannot be diluted or shrunk: the constructor rejects any
     * divisor but 1 there. The guard lives in the contract rather than the
     * deploy script, because a deploy script is a thing you can forget to
     * run.
     *
     * None of this adds a mint function, a role, an owner or a proxy. The
     * supply is fixed at construction on every chain. Only which fixed
     * number is a deploy parameter, and only away from mainnet.
     */
    uint256 public immutable supplyDivisor;

    constructor(
        uint256 _supplyDivisor
    ) ERC20("Brahhood", "BRAH") ERC20Permit("Brahhood") {
        require(_supplyDivisor > 0, "divisor=0");
        // the whole safety argument: mainnet mints the published billion
        require(
            block.chainid != RH_MAINNET_CHAIN_ID || _supplyDivisor == 1,
            "mainnet mints canon"
        );
        uint256 supply = CANON_TOTAL_SUPPLY / _supplyDivisor;
        // A divisor big enough to round the supply to zero would quietly ship
        // a token nobody can trade, rock or burn. Checked after the division,
        // because the bad outcome is the result, not the input.
        require(supply > 0, "supply=0");
        supplyDivisor = _supplyDivisor;
        _mint(msg.sender, supply);
    }
}
