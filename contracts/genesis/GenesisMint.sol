// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./IGenesis.sol";

/**
 * @title GenesisMint
 * @notice The adoption ladder. Fully public: no whitelist, no gating, no
 *         deadline, no progress bar and no per-wallet cap. Anyone buys any
 *         number. The ladder prices patience and the forest waits, since each
 *         hundred costs more than the last, and that climb is the only brake
 *         on a whale.
 *
 *         Ids run ancients first: ancients 1..9, elders 10..99, commons
 *         100..999.
 *
 *         The ladder, in ETH:
 *           commons   nine tiers of 100, stepped on the claimed count:
 *                     0.10  0.12  0.15  0.19  0.24  0.29  0.35  0.41  0.48
 *           elders    90 at 1 flat, born with a stone and brawl-ready at mint
 *           ancients  9 at 2 flat, born with a coral that never resets, and
 *                     the buyer claims a specific true name
 *         Commons are born bare: no grant, so no brawl until someone buys
 *         them a rock. That first burn is the point.
 *
 *         Selling out comes to roughly 341 ETH. Proceeds forward to the
 *         treasury on every mint as native ETH, with an owed ledger behind it
 *         so a payee can never brick the ladder. This contract's steady-state
 *         balance is zero. Shells are funded off contract; nothing about them
 *         lives here.
 *
 *         Sealed order, fair by receipt rather than by randomness. Commons
 *         and elders mint sequential ids, and which identity each id carries
 *         was fixed by the provenance hash committed on the NFT before the
 *         first adoption, which refuses to mint until it is there. Adoption
 *         order decides who wakes. Nobody, the protocol included, can pick
 *         favourites or reshuffle, and there is no randomness to bias. The
 *         one operational rule this rests on: metadata for unminted ids is
 *         never served, so a sleeping wild stays sealed until his id is
 *         adopted.
 *
 *         Ancients are the deliberate exception. The nine true names are
 *         public lore and claiming one is claiming a character, so the buyer
 *         picks which. One id per call, and with nothing hidden about an
 *         ancient's identity there is no draw to protect and no wallet gate.
 */
contract GenesisMint is Ownable, Pausable {
    IBrah999 public immutable nft;
    IRockModule public immutable rockModule;
    address public immutable treasury;

    /// @dev Proceeds a refusing treasury could not take yet. See {_forward}.
    ///      This is what lets `treasury` stay immutable in a native-ETH
    ///      world: a payee that reverts delays its own money, never the mint.
    uint256 public owedTreasury;

    uint256 public constant COMMONS_SUPPLY = 900;
    uint256 public constant ELDERS_SUPPLY = 90;
    /// @dev Sequential, ancients first, mirroring Brah999.classOf. The class
    ///      of an id is fixed by these bounds, so a mint can never hand out
    ///      an id whose class disagrees with what the buyer paid for.
    uint256 public constant ANCIENTS_END = 9;
    uint256 public constant ELDERS_START = 10;
    uint256 public constant COMMONS_START = 100;
    uint256 public constant TIER_SIZE = 100;

    /// @notice The canon schedule, used as the default when a deployment
    ///         passes zeros, and readable on chain either way.
    uint256 public constant ELDER_PRICE = 1 ether;
    uint256 public constant ANCIENT_PRICE = 2 ether;
    uint256 public constant TIERS = 9;

    /**
     * @notice What this deployment charges.
     *
     * Owner-settable until frozen, and the cost of that is real: an owner who
     * can move the mint price can move the floor under everyone who already
     * bought, while the adopt page promises the tier price only climbs.
     *
     * What buys it back:
     *   - {setSchedule} is atomic and emits {ScheduleChanged}, so every move
     *     is one auditable event rather than a drift nobody can reconstruct.
     *   - {lockSchedule} closes it forever. Called before the mint opens, it
     *     restores exactly the old guarantee, verifiable by anyone.
     *   - a buyer cannot be overcharged mid-flight: {mintCommons} requires
     *     exact payment, so a price that moves under a pending transaction
     *     reverts it instead of filling at the new number.
     *
     * Pass 0 for any of these at construction to take the canon value, so a
     * deployment that wants the published economics does not have to restate
     * them and cannot fat-finger one.
     */
    uint256 public elderPriceWei;
    uint256 public ancientPriceWei;
    /// @notice Once true, the schedule can never change again.
    bool public scheduleLocked;
    /// @dev The nine common tiers in wei, ascending by claimed count.
    uint256[TIERS] private _ladderWei;
    /// @dev Max commons per call. A gas bound, not a supply gate and not a
    ///      wallet cap. 100 is a full tier in one transaction, comfortably
    ///      inside a block; a bigger batch is more calls, never a refusal.
    uint256 public constant MAX_COMMONS_PER_TX = 100;

    /**
     * @notice Divides every price on this deployment. Always 1 on mainnet.
     *
     * Walking the ladder once at canon prices costs 341 ETH, so a testnet
     * rehearsal of the real flow is otherwise impossible. This divides the
     * whole schedule by one number, so testnet keeps the exact shape of the
     * economics at a thousandth of the cost instead of inventing a second
     * price table nobody has reviewed.
     *
     * Mainnet cannot be discounted: the constructor rejects any divisor but 1
     * on the mainnet chain id, so this cannot be the parameter that ships a
     * 341 ETH raise for 0.341. The guard is in the contract rather than the
     * deploy script, because a deploy script is a thing you can forget to
     * run.
     */
    uint256 public constant RH_MAINNET_CHAIN_ID = 4663;
    uint256 public immutable priceDivisor;

    uint256 public commonsMinted;
    uint256 public eldersMinted;
    uint256 public ancientsMinted;

    event Adopted(
        uint256 indexed brahId,
        address indexed to,
        IBrah999.Class class_,
        uint256 paidWei
    );

    /// @notice The mint was re-priced. Values are canon wei, before the
    ///         divisor, which is the same units {setSchedule} takes, so the
    ///         event replays what was asked for rather than what this
    ///         deployment happens to charge.
    event ScheduleChanged(
        uint256[TIERS] ladder,
        uint256 elderPriceWei,
        uint256 ancientPriceWei
    );
    /// @notice The schedule can never change again.
    event ScheduleLocked();

    constructor(
        address _nft,
        address _rockModule,
        address _treasury,
        uint256 _priceDivisor,
        /// @dev 0 in any slot takes the canon value for that slot
        uint256[TIERS] memory _ladder,
        uint256 _elderPrice,
        uint256 _ancientPrice,
        /**
         * @dev Resume counters: commons, elders and ancients already adopted
         *      on a predecessor mint, all zero on a genesis deploy. This
         *      contract is replaceable while the NFT's wiring is unlocked,
         *      and a successor that restarted its counters at zero would
         *      derive ids that are already taken. Every mint would revert on
         *      the NFT's duplicate guard and the ladder would brick at the
         *      moment of the swap. The counters also carry the ladder
         *      position, so a resumed mint keeps charging the step the
         *      collection had actually climbed to.
         */
        uint256[3] memory _resumeMinted,
        address _owner
    ) Ownable(_owner) {
        require(_nft != address(0), "nft=0");
        require(_rockModule != address(0), "rock=0");
        require(_treasury != address(0), "treasury=0");
        require(_treasury != address(this), "treasury=self");
        require(_priceDivisor > 0, "divisor=0");
        // the whole point of the guard: mainnet pays canon, no exceptions
        require(
            block.chainid != RH_MAINNET_CHAIN_ID || _priceDivisor == 1,
            "mainnet pays canon"
        );
        require(_resumeMinted[0] <= COMMONS_SUPPLY, "resume commons");
        require(_resumeMinted[1] <= ELDERS_SUPPLY, "resume elders");
        require(_resumeMinted[2] <= ANCIENTS_END, "resume ancients");
        nft = IBrah999(_nft);
        rockModule = IRockModule(_rockModule);
        treasury = _treasury;
        priceDivisor = _priceDivisor;
        commonsMinted = _resumeMinted[0];
        eldersMinted = _resumeMinted[1];
        ancientsMinted = _resumeMinted[2];

        // The published ladder, used for any slot left at 0. Ascending is not
        // enforced: a flat or cheaper-later schedule is a legitimate thing
        // for a test deployment to want, and the contract has no business
        // deciding a launch's economics beyond refusing a free mint.
        uint256[TIERS] memory canon = [
            uint256(0.10 ether),
            0.12 ether,
            0.15 ether,
            0.19 ether,
            0.24 ether,
            0.29 ether,
            0.35 ether,
            0.41 ether,
            0.48 ether
        ];
        for (uint256 i = 0; i < TIERS; i++) {
            uint256 v = _ladder[i] == 0 ? canon[i] : _ladder[i];
            // a zero tier would mint that hundred for nothing, and the
            // divisor divides it, so the floor is checked after the default
            require(v >= _priceDivisor, "tier too cheap");
            _ladderWei[i] = v;
        }
        elderPriceWei = _elderPrice == 0 ? ELDER_PRICE : _elderPrice;
        ancientPriceWei = _ancientPrice == 0 ? ANCIENT_PRICE : _ancientPrice;
        require(elderPriceWei >= _priceDivisor, "elder too cheap");
        require(ancientPriceWei >= _priceDivisor, "ancient too cheap");
    }

    // --------------------------------------------------------------------- //
    // The ladder
    // --------------------------------------------------------------------- //

    /// @notice Price of the `index`-th common, zero based, by tier of 100.
    function commonPriceAt(uint256 index) public view returns (uint256) {
        require(index < COMMONS_SUPPLY, "sold out");
        uint256 tier = index / TIER_SIZE; // 0..8
        return _ladderWei[tier] / priceDivisor;
    }

    /// @notice What an elder costs on this deployment.
    function elderPrice() public view returns (uint256) {
        return elderPriceWei / priceDivisor;
    }

    /// @notice What an ancient costs on this deployment.
    function ancientPrice() public view returns (uint256) {
        return ancientPriceWei / priceDivisor;
    }

    /// @notice The full common ladder this deployment charges, after the
    ///         divisor. One call, so the api and the adopt page can quote the
    ///         real schedule instead of a copy of the spec.
    function ladder() external view returns (uint256[TIERS] memory out) {
        for (uint256 i = 0; i < TIERS; i++) out[i] = _ladderWei[i] / priceDivisor;
    }

    // --------------------------------------------------------------------- //
    // The schedule, after deployment
    // --------------------------------------------------------------------- //

    /**
     * @notice Re-price the whole mint in one transaction: all nine common
     *         tiers, the elder flat and the ancient flat.
     * @dev Atomic on purpose. Three separate setters would leave a window
     *      where an elder costs the new price and a common still costs the
     *      old one, and somebody would mint inside it.
     *
     *      Values are canon wei, the same units the constructor takes, and
     *      the divisor is applied on read. So a testnet deployment re-prices
     *      in the numbers the spec is written in and still charges a
     *      thousandth of them. The divisor itself stays immutable, since it
     *      is what keeps mainnet honest.
     *
     *      No zero-means-keep magic here, unlike the constructor. A re-price
     *      states the whole schedule, because "leave that one alone" is
     *      exactly the shape of an accident nobody notices.
     */
    function setSchedule(
        uint256[TIERS] calldata _ladder,
        uint256 _elderPrice,
        uint256 _ancientPrice
    ) external onlyOwner {
        require(!scheduleLocked, "schedule locked");
        for (uint256 i = 0; i < TIERS; i++) {
            // the divisor divides this, so the floor is what keeps a tier
            // from rounding down into a free mint
            require(_ladder[i] >= priceDivisor, "tier too cheap");
            _ladderWei[i] = _ladder[i];
        }
        require(_elderPrice >= priceDivisor, "elder too cheap");
        require(_ancientPrice >= priceDivisor, "ancient too cheap");
        elderPriceWei = _elderPrice;
        ancientPriceWei = _ancientPrice;
        emit ScheduleChanged(_ladder, _elderPrice, _ancientPrice);
    }

    /// @notice Give up the right to re-price, forever. Called before the mint
    ///         opens, it turns "the price only climbs" from something the
    ///         site claims into something a buyer can check.
    function lockSchedule() external onlyOwner {
        scheduleLocked = true;
        emit ScheduleLocked();
    }

    /// @notice Exact cost of the next `qty` commons from the current step.
    ///         This is what the adopt button quotes.
    function quoteCommons(uint256 qty) public view returns (uint256 cost) {
        for (uint256 k = 0; k < qty; k++) {
            cost += commonPriceAt(commonsMinted + k);
        }
    }

    // --------------------------------------------------------------------- //
    // Adoption
    // --------------------------------------------------------------------- //

    /// @notice Adopt `qty` sleeping commons at the current step, which are
    ///         the next ids in the sealed order. Exact payment only, so a
    ///         race that loses the step reverts whole rather than filling at
    ///         a price the buyer never saw.
    function mintCommons(uint256 qty) external payable whenNotPaused {
        require(qty >= 1 && qty <= MAX_COMMONS_PER_TX, "qty");
        require(commonsMinted + qty <= COMMONS_SUPPLY, "sold out");
        require(msg.value == quoteCommons(qty), "bad payment");

        for (uint256 k = 0; k < qty; k++) {
            // sealed order: ids 100..999, in ladder order
            uint256 index = commonsMinted++;
            uint256 brahId = COMMONS_START + index;
            nft.mint(msg.sender, brahId);
            emit Adopted(
                brahId,
                msg.sender,
                IBrah999.Class.Common,
                commonPriceAt(index)
            );
        }

        _forward();
    }

    /// @notice Adopt the next sleeping elder in the sealed order. Flat price,
    ///         and he wakes brawl-ready: the founding stone is granted in the
    ///         same transaction.
    function mintElder() external payable whenNotPaused {
        require(eldersMinted < ELDERS_SUPPLY, "sold out");
        require(msg.value == elderPrice(), "bad payment");

        uint256 brahId = ELDERS_START + eldersMinted++; // ids 10..99
        nft.mint(msg.sender, brahId);
        rockModule.grantFoundingStone(brahId);
        emit Adopted(brahId, msg.sender, IBrah999.Class.Elder, msg.value);

        _forward();
    }

    /// @notice Claim a specific ancient by his true name's id, 1 through 9.
    ///         Flat price, born with a permanent coral. One id per call.
    function mintAncient(uint256 brahId) external payable whenNotPaused {
        require(brahId >= 1 && brahId <= ANCIENTS_END, "not ancient");
        require(!nft.minted(brahId), "claimed");
        require(msg.value == ancientPrice(), "bad payment");

        ancientsMinted += 1;
        nft.mint(msg.sender, brahId);
        rockModule.grantAncientCoral(brahId);
        emit Adopted(brahId, msg.sender, IBrah999.Class.Ancient, msg.value);

        _forward();
    }

    // --------------------------------------------------------------------- //
    // Ops
    // --------------------------------------------------------------------- //

    /// @notice Stop new adoptions. Holds no funds, so pausing strands nobody.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------------------------------- //
    // Internal
    // --------------------------------------------------------------------- //

    /**
     * @dev Proceeds forward to the treasury on every call as native ETH, so
     *      the steady-state balance here is zero.
     *
     *      A native push can be refused, and a treasury that reverts on
     *      receive must not brick every adoption permanently with no way back
     *      because the payee is immutable. So a refused send is booked under
     *      {owedTreasury}, the mint completes, and anyone may retry the
     *      handover later with {flushOwed}. A refusing treasury delays its
     *      own money and nothing else, which is what lets `treasury` stay
     *      immutable: no owner-settable payee, so no lever pointing the
     *      mint's proceeds somewhere new. The escrow's rake legs settle the
     *      same question the same way.
     */
    function _forward() internal {
        // owedTreasury rides along: anything refused earlier retries on every
        // later mint, so a healed treasury catches up by itself.
        uint256 bal = address(this).balance;
        (bool ok, ) = treasury.call{value: bal}("");
        if (!ok) owedTreasury = bal;
        else if (owedTreasury != 0) owedTreasury = 0;
    }

    /// @notice Retry handing the treasury what it once refused.
    ///         Permissionless, since the money is already the treasury's.
    function flushOwed() external {
        uint256 amount = owedTreasury;
        require(amount > 0, "nothing owed");
        owedTreasury = 0;
        (bool ok, ) = treasury.call{value: amount}("");
        require(ok, "still refused");
    }
}
