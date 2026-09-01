// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import "./IGenesis.sol";

/**
 * @title RockModule
 * @notice Give him his rock. One time, per owner, per brah. Every rock burns
 *         in full. There is no payee in this contract, only the burn.
 *
 *         Two axes, and they never cross. Class decides how often a brah
 *         fights and where he is slotted. The rock decides how big his slice
 *         of the 3% pool is. Nothing bought here changes how often he fights.
 *         So this contract has exactly one economic output, {weightOf}:
 *           stone     66,666 $BRAH   1x pool share
 *           coral    222,222 $BRAH   2x pool share
 *           obsidian 666,666 $BRAH   3x pool share, plus cosmetic flair
 *         Upgrades cost the difference at current dial prices. Those three
 *         are the canon amounts; a test deployment divides all of them by
 *         {amountDivisor} and mainnet is forbidden from doing so.
 *
 *         There is no claim gate. Winnings are fully withdrawable at every
 *         tier, so there is no locked or compounding balance anywhere.
 *
 *         Born rocked, by class: commons arrive bare and cannot fight until
 *         someone buys them a rock, which is the point of that first burn.
 *         Elders are born with a stone, ancients with a coral.
 *
 *         Reset on transfer: the NFT calls {onBrahTransfer} on every real
 *         transfer and the rock clears, because the next owner brings his
 *         own. The exception is an ancient's base coral, which is permanent.
 *         An ancient upgraded to obsidian falls back to coral on a sale,
 *         never to nothing. An elder's founding stone does reset.
 *
 *         The dial: rock amounts target roughly $100, $350 and $1,000, and
 *         the owner re-sets them when they drift about 3x out of band.
 *         {setRockAmounts} is that dial, events make every repricing legible,
 *         and {MAX_DIAL_STEP} makes the band a rule rather than a promise.
 *         Weights are not dialable. They are constants of the game.
 *
 *         Nothing here ever touches a fight. The escrow reads only
 *         {isActivated}, the vault reads only {weightOf}. Odds, calls,
 *         scoring and scheduling never see a rock.
 */
contract RockModule is Ownable, IRockModule {
    /**
     * The most a single {setRockAmounts} may move one tier, either way. The
     * policy is to re-set when prices drift about 3x out of band, so one call
     * may correct exactly that much and no more. No single transaction can
     * turn activation into a price nobody can pay, or into free, and a
     * larger drift has to be walked in bounded, evented steps.
     */
    uint256 public constant MAX_DIAL_STEP = 3;

    /// @dev The chain that pays canon. The same guard sits in GenesisMint and
    ///      BrahERC20: one rule, three contracts, one chain id.
    uint256 public constant RH_MAINNET_CHAIN_ID = 4663;

    /// @notice What a rock costs before any deployment scaling. Kept on chain
    ///         so the canon a test deployment was derived from is as readable
    ///         as the number it actually charges.
    uint256 public constant CANON_STONE = 66_666 * 1e18;
    uint256 public constant CANON_CORAL = 222_222 * 1e18;
    uint256 public constant CANON_OBSIDIAN = 666_666 * 1e18;

    /**
     * @notice What the canon amounts were divided by on this deployment.
     *         Always 1 on mainnet; testnet runs 1000.
     *
     * This must equal BrahERC20.supplyDivisor. A rock is a claim on a
     * fraction of the supply, and that fraction is the economics. Mint a
     * thousandth of the supply while still charging 66,666 and a stone costs
     * 6.7% of every token in existence. Charge 66.666 against the full
     * billion and it costs a rounding error. Neither rehearses anything.
     * The deploy script feeds both contracts the same number, and nothing
     * here can check it, because the token has no opinion about who is
     * quoting it.
     *
     * Mainnet pays canon, enforced by the chain id guard below rather than
     * by a script, because a discounted rock on mainnet discounts the only
     * thing $BRAH is for.
     *
     * Recorded rather than read: the dial holds the already-divided amounts,
     * so nothing in the burn path divides at read time. This field is here
     * so a deployment can be audited against the canon it claims to scale.
     */
    uint256 public immutable amountDivisor;

    IBrah999 public immutable nft;
    ERC20Burnable public immutable brah;

    /// @dev Winnings vault, told before every weight change. Settable until
    ///      {lockWiring}.
    IWinningsVault public vault;

    /// @dev The only caller of the mint-time grants. Settable until
    ///      {lockWiring}.
    address public minter;

    /// @dev Once true, {setVault} and {setMinter} are closed for good.
    bool public wiringLocked;

    /// @dev The dial: $BRAH per tier. Set in the constructor rather than at
    ///      declaration, so the launch amounts are computed in one place and
    ///      there is one number to read afterwards.
    uint256 public stoneAmount;
    uint256 public coralAmount;
    uint256 public obsidianAmount;

    mapping(uint256 => Tier) private _tiers;

    event VaultSet(address vault);
    event MinterSet(address minter);
    event WiringLocked();
    /// @param burned exact $BRAH destroyed, zero only for the two mint grants
    event RockGiven(
        uint256 indexed brahId,
        address indexed giver,
        Tier tier,
        uint256 burned
    );
    event RockCleared(uint256 indexed brahId);
    event RockDialTurned(
        uint256 stoneAmount,
        uint256 coralAmount,
        uint256 obsidianAmount
    );

    /**
     * @param _amountDivisor Divides the canon dial on this deployment. 1 is
     *        canon and mainnet accepts nothing else.
     *
     * @dev The dial is announced at birth, and that emit is load-bearing.
     *      Without it a fresh deployment's prices exist in storage and
     *      nowhere else, so an indexer stays empty until the owner happens to
     *      reprice and every surface falls back to a hand-copied literal. On
     *      a scaled deployment that is a factor-of-a-thousand gap between the
     *      price a page quotes and the approval a user signs. Emitting here
     *      makes the chain the first and only publisher of its own dial.
     */
    constructor(
        address _nft,
        address _brah,
        uint256 _amountDivisor,
        address _owner
    ) Ownable(_owner) {
        require(_nft != address(0), "nft=0");
        require(_brah != address(0), "brah=0");
        require(_amountDivisor > 0, "divisor=0");
        // mainnet's rock is the published rock; see {amountDivisor}
        require(
            block.chainid != RH_MAINNET_CHAIN_ID || _amountDivisor == 1,
            "mainnet pays canon"
        );
        nft = IBrah999(_nft);
        brah = ERC20Burnable(_brah);
        amountDivisor = _amountDivisor;

        uint256 stone = CANON_STONE / _amountDivisor;
        uint256 coral = CANON_CORAL / _amountDivisor;
        uint256 obsidian = CANON_OBSIDIAN / _amountDivisor;
        /**
         * The same invariant {setRockAmounts} enforces, checked on the result
         * of the division rather than on the divisor.
         *
         * A divisor big enough to truncate a tier to zero would hand out
         * stones for free, since {activate} burns the difference and burning
         * zero succeeds. Big enough to collapse two tiers together and an
         * upgrade costs nothing for the same reason. Both fail silently, so
         * both are checked here.
         */
        require(stone > 0 && stone < coral && coral < obsidian, "order");
        stoneAmount = stone;
        coralAmount = coral;
        obsidianAmount = obsidian;
        emit RockDialTurned(stone, coral, obsidian);
    }

    // --------------------------------------------------------------------- //
    // Wiring, settable until locked
    // --------------------------------------------------------------------- //

    /**
     * @dev Re-pointing the vault carries the whole weight ledger with it: a
     *      fresh vault starts at zero total weight while brahs here already
     *      hold tiers. This window is for replacing a broken vault before the
     *      mint opens, not for migrating a live one.
     */
    function setVault(address _vault) external onlyOwner {
        require(!wiringLocked, "wiring locked");
        require(_vault != address(0), "vault=0");
        vault = IWinningsVault(_vault);
        emit VaultSet(_vault);
    }

    function setMinter(address _minter) external onlyOwner {
        require(!wiringLocked, "wiring locked");
        require(_minter != address(0), "minter=0");
        minter = _minter;
        emit MinterSet(_minter);
    }

    /**
     * @notice Freeze {setVault} and {setMinter} forever.
     * @dev Until this lands, a bug in the mint or the vault is a redeploy and
     *      a re-point. After it, the mint-grant caller and the weight ledger
     *      are as fixed as the tier constants. Locked is the launch posture;
     *      an unlocked module is a rehearsal that has not finished.
     */
    function lockWiring() external onlyOwner {
        require(!wiringLocked, "locked");
        require(address(vault) != address(0), "vault unset");
        require(minter != address(0), "minter unset");
        wiringLocked = true;
        emit WiringLocked();
    }

    // --------------------------------------------------------------------- //
    // The dial
    // --------------------------------------------------------------------- //

    /// @notice Re-set rock prices within the published band. Ordering is
    ///         enforced so an upgrade's difference can never go negative, and
    ///         each tier moves at most {MAX_DIAL_STEP}x per call so the dial
    ///         cannot become a gate or a giveaway in one move.
    function setRockAmounts(
        uint256 _stone,
        uint256 _coral,
        uint256 _obsidian
    ) external onlyOwner {
        require(_stone > 0 && _stone < _coral && _coral < _obsidian, "order");
        _requireInStep(stoneAmount, _stone);
        _requireInStep(coralAmount, _coral);
        _requireInStep(obsidianAmount, _obsidian);
        stoneAmount = _stone;
        coralAmount = _coral;
        obsidianAmount = _obsidian;
        emit RockDialTurned(_stone, _coral, _obsidian);
    }

    // --------------------------------------------------------------------- //
    // Activation
    // --------------------------------------------------------------------- //

    /**
     * @notice Give brah `brahId` his rock, or upgrade the one he holds. The
     *         caller must own the brah and have approved this contract for
     *         the cost, all of which burns in this transaction.
     * @dev A first activation charges the full tier amount; an upgrade
     *      charges the difference at current dial prices. Downgrades do not
     *      exist. Ancients are coral-born, so obsidian is something they can
     *      buy and the subtraction credits the birthright: 444,444 at canon
     *      amounts, never the full 666,666.
     */
    function activate(uint256 brahId, Tier tier) external {
        require(nft.ownerOf(brahId) == msg.sender, "not owner");
        Tier current = _tiers[brahId];
        require(tier > current, "not an upgrade");

        uint256 cost = _amountOf(tier) - _amountOf(current);
        // The burn is the payment. No transfer to any wallet, ever.
        brah.burnFrom(msg.sender, cost);

        _setTier(brahId, tier);
        emit RockGiven(brahId, msg.sender, tier, cost);
    }

    /**
     * @notice Rock reset on transfer, callable by the NFT only. The next
     *         owner brings his own rock, except for an ancient, who keeps the
     *         coral he was born with and loses only what was paid on top.
     *
     * @dev Exempting ancients outright would leak: it would carry a paid
     *      obsidian through a sale and hand the buyer 444,444 $BRAH of
     *      upgrade the seller burned for. So an ancient is set back to coral
     *      rather than to none. The gift survives, the purchase does not, and
     *      he is never left rockless and benched over a transfer he did not
     *      make.
     *
     *      An ancient already at his birthright is a real no-op: no write and
     *      no event, so nobody downstream has to interpret a clear that
     *      changed nothing.
     */
    function onBrahTransfer(uint256 brahId) external {
        require(msg.sender == address(nft), "not nft");
        Tier current = _tiers[brahId];
        if (current == Tier.None) return;

        if (nft.classOf(brahId) == IBrah999.Class.Ancient) {
            if (current == Tier.Coral) return; // already the birthright
            _setTier(brahId, Tier.Coral);
            emit RockCleared(brahId);
            return;
        }

        _setTier(brahId, Tier.None);
        emit RockCleared(brahId);
    }

    /// @notice Elder founding bonus: born with his stone, fight-ready at
    ///         mint, no $BRAH needed. Consumable, so it resets on resale like
    ///         any other rock.
    function grantFoundingStone(uint256 brahId) external {
        require(msg.sender == minter, "not minter");
        require(nft.classOf(brahId) == IBrah999.Class.Elder, "not elder");
        require(_tiers[brahId] == Tier.None, "has rock");
        _setTier(brahId, Tier.Stone);
        emit RockGiven(brahId, msg.sender, Tier.Stone, 0);
    }

    /**
     * @notice Ancient birthright: coral-born, and that coral is permanent.
     *
     * @dev Coral rather than obsidian, so there is still something to buy.
     *      An ancient handed the top tier at mint could never upgrade. Coral
     *      gives him 2x pool share from birth and leaves obsidian as a choice
     *      his owner pays the difference for.
     *
     *      Only this coral is permanent. {onBrahTransfer} returns an ancient
     *      to it rather than to none, so a sale strips a bought upgrade and
     *      never the birthright.
     */
    function grantAncientCoral(uint256 brahId) external {
        require(msg.sender == minter, "not minter");
        require(nft.classOf(brahId) == IBrah999.Class.Ancient, "not ancient");
        require(_tiers[brahId] == Tier.None, "has rock");
        _setTier(brahId, Tier.Coral);
        emit RockGiven(brahId, msg.sender, Tier.Coral, 0);
    }

    // --------------------------------------------------------------------- //
    // Views
    // --------------------------------------------------------------------- //

    function tierOf(uint256 brahId) external view returns (Tier) {
        return _tiers[brahId];
    }

    /// @notice The only gate: no rock, no fight.
    function isActivated(uint256 brahId) external view returns (bool) {
        return _tiers[brahId] != Tier.None;
    }

    /// @notice Spread weight, 1x / 2x / 3x by rock tier alone. Class
    ///         multipliers are matchmaking, never money.
    function weightOf(uint256 brahId) external view returns (uint256) {
        return _weightOf(_tiers[brahId]);
    }

    // --------------------------------------------------------------------- //
    // Internal
    // --------------------------------------------------------------------- //

    /// @dev One tier's move, bounded to {MAX_DIAL_STEP}x either way. Written
    ///      as two multiplications so no rounding decides whether a repricing
    ///      is legal.
    function _requireInStep(uint256 current, uint256 next) internal pure {
        require(
            next <= current * MAX_DIAL_STEP &&
                next * MAX_DIAL_STEP >= current,
            "dial step"
        );
    }

    /// @dev Every tier write goes through here, so the vault's weight ledger
    ///      cannot drift from the tier ledger.
    function _setTier(uint256 brahId, Tier tier) internal {
        _tiers[brahId] = tier;
        vault.updateWeight(brahId, _weightOf(tier));
    }

    function _weightOf(Tier t) internal pure returns (uint256) {
        return uint256(t); // none 0, stone 1, coral 2, obsidian 3
    }

    function _amountOf(Tier t) internal view returns (uint256) {
        if (t == Tier.Stone) return stoneAmount;
        if (t == Tier.Coral) return coralAmount;
        if (t == Tier.Obsidian) return obsidianAmount;
        return 0;
    }
}
