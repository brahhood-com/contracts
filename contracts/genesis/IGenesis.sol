// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * Shared interfaces for the 999 contract set. Each one is the smallest
 * surface its callers need; the full contracts sit beside this file.
 *
 * There is no wrapped ETH anywhere in this set. Every payment that must not
 * fail either reverts back to a caller who can retry, or falls back to an
 * owed ledger the payee sweeps later. The only currency anyone sends or
 * receives is the chain's own ETH.
 */

/// @dev The 999 collection, as the modules around it see it.
interface IBrah999 {
    enum Class {
        None, // out of range or unminted
        Common, // ids 1..900
        Elder, // ids 901..990
        Ancient // ids 991..999
    }

    function ownerOf(uint256 tokenId) external view returns (address);

    function minted(uint256 brahId) external view returns (bool);

    function classOf(uint256 brahId) external pure returns (Class);

    /// @dev The brah's token-bound account. Zero until minted.
    function tbaOf(uint256 brahId) external view returns (address);

    /// @dev Reverse lookup, zero when `account` is not a brah wallet. The
    ///      escrow's "players don't bet on the league" rule is one require
    ///      on this view.
    function tbaToBrahId(address account) external view returns (uint256);

    function mint(address to, uint256 brahId) external;
}

/// @dev Activation state, as the escrow, the vault and the NFT see it.
interface IRockModule {
    enum Tier {
        None,
        Stone,
        Coral,
        Obsidian
    }

    function tierOf(uint256 brahId) external view returns (Tier);

    function isActivated(uint256 brahId) external view returns (bool);

    /// @dev Spread weight: none 0, stone 1, coral 2, obsidian 3. Class never
    ///      appears here. Nothing about a brah's traits, class or tier
    ///      touches the fight or the money beyond this one number.
    function weightOf(uint256 brahId) external view returns (uint256);

    /// @dev Transfer hook. Clears the rock, except an ancient, who drops back
    ///      to the coral he was born with rather than to nothing.
    function onBrahTransfer(uint256 brahId) external;

    /// @dev Mint-time grants, callable by GenesisMint only. Commons get
    ///      neither. They are born bare and cannot fight until someone buys
    ///      them a rock.
    function grantFoundingStone(uint256 brahId) external;

    function grantAncientCoral(uint256 brahId) external;
}

/// @dev Per-brah winnings ledger and the weighted spread accumulator.
interface IWinningsVault {
    /// @dev Called by the rock module before a weight changes, so everything
    ///      accrued so far settles at the old weight.
    function updateWeight(uint256 brahId, uint256 newWeight) external;

    /// @dev The 2% leg: credit the winner's brah wallet. Payable, so the
    ///      credit is always backed by ETH that actually arrived.
    function creditWinner(uint256 brahId) external payable;

    /// @dev The 3% leg: split across every activated brah by rock weight.
    ///      Payable, same rule as {creditWinner}.
    function depositSpread() external payable;
}
