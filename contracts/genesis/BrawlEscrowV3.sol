// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../brawl/IOracle.sol";
import "./IGenesis.sol";

/// @dev The writer path into CloutRegistry, and nothing more.
interface ICloutRegistry {
    function recordResult(
        uint256 brahId,
        uint8 category,
        bool correct,
        uint256 missBps
    ) external;

    function recordForfeit(uint256 brahId) external;
}

/**
 * @title BrawlEscrowV3
 * @notice The anchor model. Pari-mutuel native-ETH stakes, an owed ledger, a
 *         rake of 10% of the losing pot split four ways, and a lifecycle
 *         built so there is no last-minute staking edge to take.
 *
 *         The problem it solves: seal an absolute number and the market can
 *         walk through it before staking even closes, deciding the brawl
 *         before it starts and collapsing the pool onto one side. Whoever
 *         staked in the last minute had watched the whole drift and could
 *         snipe the closer call.
 *
 *         So calls are relative, and they are measured from an anchor price
 *         that does not exist until after staking has closed. Drift during
 *         the staking window moves both targets together, so watching the
 *         chart buys a staker nothing.
 *
 *           Sealed     both calls committed as hashes
 *           Revealed   both calls public; staking open until stakeCloseAt
 *           the gap    staking closed, anchor not yet taken. No state
 *                      transition; stake() gates on the clock
 *           Locked     {anchor} snapshotted the price and derived both
 *                      targets: target = anchor * (CALL_SCALE + call) /
 *                      CALL_SCALE. The race is running
 *           Resolved   the pin is read; the closer target wins
 *
 *         The band: every call must land inside plus or minus a per-brawl
 *         band set at create, say 2.5% for majors. The operator clamps at
 *         sealing and {reveal} is the public backstop, where a hash-matching
 *         reveal outside the band forfeits that fighter, with everyone
 *         refunded and no rake, rather than stranding the brawl in Sealed.
 *         Since both calls live inside one box two bands wide, the maximum
 *         spread is bounded by construction.
 *
 *         The fight runs regardless of the book. A one-sided or empty book
 *         still anchors, still resolves and still records both results, so
 *         clout and win rate count every fight. The money keeps its own
 *         promises inside {_settle}: an empty winning side refunds, and a
 *         winning side with no counterparty gets stakes back whole at a zero
 *         rake, because nothing changed hands.
 *
 *         Two standing rules: no rock, no brawl, and players do not bet on
 *         the league. Pausing can never block a brawl's route to a refundable
 *         terminal state, and the contract is not upgradeable. If the
 *         operator goes dark, {forceVoid} is permissionless once resolveAt
 *         plus VOID_GRACE has elapsed.
 *
 *         The trust line: sealed before you can stake, public while you
 *         stake, measured from a price that does not exist until after you
 *         are done.
 */
contract BrawlEscrowV3 is Ownable, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant BPS = 10000;
    // Hard ceiling on the rake, at its launch value. The rake is easy to
    // lower and can never be raised above 10% of the losing pot.
    uint256 public constant MAX_RAKE_BPS = 1000;

    /**
     * The scale a call is expressed at: a signed fraction of the anchor at
     * 1e8, the same scale family as every oracle value, so one convention
     * covers every int256 in the system. +0.7% is +700_000 and a 2.5% band
     * is 2_500_000. target = anchor * (CALL_SCALE + call) / CALL_SCALE.
     */
    int256 public constant CALL_SCALE = 100_000_000;

    /**
     * Ceiling on a single call's recorded miss, in bps of the measured pin.
     * Two jobs: one absurd reveal cannot poison a brah's lifetime average,
     * and the registry's cumulative accumulator stays bounded. Record side
     * only. It never touches winner selection, the pot, the rake or a claim,
     * and being ten thousand times off still loses the brawl on distance.
     */
    uint256 public constant MAX_MISS_BPS = 100_000_000;

    enum Status {
        None,
        Sealed, // calls committed as hashes; no staking yet
        Revealed, // calls public; staking open until stakeCloseAt
        Locked, // anchored: targets derived, the race is running
        Resolved, // oracle read, winning stakers may claim
        Voided, // no valid outcome, or our fault; everyone refunds
        Forfeited // a brah no-showed or revealed out of band; full refund
    }

    // Reasons carried on Voided.
    uint8 public constant VOID_EXACT_TIE = 0;
    uint8 public constant VOID_NO_WINNER_STAKE = 1;
    uint8 public constant VOID_TIMEOUT = 2;
    uint8 public constant VOID_INFRA = 3;
    /// @dev Reserved. A one-sided book no longer voids, but the code stays so
    ///      historical events still decode.
    uint8 public constant VOID_ONE_SIDED = 4;

    /// {CloutRecordFailed} kinds: which ledger the swallowed write targeted.
    uint8 public constant CLOUT_KIND_RESULT = 0;
    uint8 public constant CLOUT_KIND_FORFEIT = 1;

    /// {RakeLegFallback} legs: which vault leg fell back to the treasury.
    uint8 public constant LEG_WINNER = 0;
    uint8 public constant LEG_SPREAD = 1;

    // Permissionless liveness backstop. See {forceVoid}.
    uint256 public constant VOID_GRACE = 1 days;

    /**
     * Maximum age of an oracle read used by {anchor} and {resolve}. A read
     * older than this, or never written at all, reverts rather than settling
     * real ETH against a value that is not current. The anchor to resolve gap
     * is hours, so this gate is what proves resolve can never quietly consume
     * the anchor snapshot as the close. It carries about five keeper crank
     * intervals of headroom, so ordinary latency cannot brick anything. A
     * backstop, not the primary defence: the happy path reads a value written
     * seconds earlier.
     */
    uint256 public constant MAX_ORACLE_STALENESS = 5 minutes;

    struct Brawl {
        uint256 brahA; // brahId
        uint256 brahB; // brahId
        uint256 potA; // total ETH staked on A
        uint256 potB; // total ETH staked on B
        uint256 winnerBrahId; // 0 until resolved
        uint256 winnerPot; // stake on the winning side, 0 until resolved
        uint256 netPot; // distributable to winners: totalPot - rake
        uint256 poolCap; // max potA+potB, 0 for uncapped; fixed at create
        int256 band; // |call| ceiling at CALL_SCALE; fixed at create
        int256 anchorValue; // oracle snapshot at the anchor, 0 until Locked
        int256 targetA; // anchor * (CALL_SCALE + callA) / CALL_SCALE
        int256 targetB; // anchor * (CALL_SCALE + callB) / CALL_SCALE
        int256 resolvedValue; // the raw pin read at resolution
        int256 callA; // brahA's revealed call, 0 until Revealed
        int256 callB; // brahB's revealed call, 0 until Revealed
        bytes32 commitA;
        bytes32 commitB;
        bytes32 feedId;
        uint64 revealAt; // calls decrypt here; staking opens
        uint64 stakeCloseAt; // stakes freeze here; the gap begins
        uint64 anchorAt; // the anchor may be snapshotted from here
        uint64 resolveAt; // the pin is read here
        uint8 category; // call taxonomy; the menu lives off chain
        Status status;
        string question; // the call in plain words
    }

    // Immutable wiring.
    address public immutable brahNft;
    address public immutable cloutRegistry;
    IRockModule public immutable rockModule;
    IWinningsVault public immutable winningsVault;

    // Owner-tunable config. None of it touches escrowed funds.
    address public oracle;
    address public protocolTreasury;
    address public buyAndBurn;
    uint256 public minStake = 0.002 ether; // per stake() call; 0 disables

    /**
     * The owed ledger, which is what makes a native-ETH settlement
     * unblockable.
     *
     * A rake leg is a push to a payee this contract does not control, and a
     * native push can be refused. Any leg whose send fails is recorded here
     * instead, the resolve completes, and anyone may retry the payment later
     * with {sweepOwed}. Money in this ledger already belongs to the payee;
     * the escrow just could not hand it over yet.
     */
    mapping(address => uint256) public owed;
    /**
     * When false, which is the default, a brah's owner cannot stake either
     * side of a brawl his brah is in. It binds the NFT-holding wallet only,
     * since alts are an off-chain problem, and it is owner-settable so the
     * gate can open without a redeploy.
     */
    bool public ownerStakeAllowed;
    /**
     * Per-wallet ceiling across both sides of a single brawl. 0 disables. It
     * caps a wallet's total exposure to one brawl rather than a single
     * stake() call, and it binds a wallet, not a person.
     */
    uint256 public maxStakePerWallet;

    // Rake config, set through {setRakeConfig}: the rake is capped at
    // MAX_RAKE_BPS and the splits must sum to BPS.
    uint256 public brawlRakeBps = 1000; // of the losing pot
    uint256 public splitWinnerBps = 2000; // of rake, to the winner's wallet
    uint256 public splitSpreadBps = 3000; // of rake, to all activated brahs
    uint256 public splitProtocolBps = 2500; // of rake, to the treasury
    uint256 public splitBurnBps = 2500; // of rake, to the burn leg

    uint256 public lastBrawlId;
    mapping(uint256 => Brawl) private _brawls;

    // brawlId => user => stake on each side
    mapping(uint256 => mapping(address => uint256)) public stakeA;
    mapping(uint256 => mapping(address => uint256)) public stakeB;
    // brawlId => user => claimed
    mapping(uint256 => mapping(address => bool)) public claimed;

    // Running remainders, so pro-rata is exact and no dust is left behind.
    mapping(uint256 => uint256) private _winStakeRemaining;
    mapping(uint256 => uint256) private _distRemaining;

    event BrawlOpened(
        uint256 indexed brawlId,
        uint256 indexed brahA,
        uint256 indexed brahB,
        uint8 category,
        string question,
        uint64 revealAt,
        uint64 stakeCloseAt,
        uint64 anchorAt,
        uint64 resolveAt,
        bytes32 feedId,
        bytes32 commitA,
        bytes32 commitB,
        int256 band,
        uint256 poolCap
    );
    event Staked(
        uint256 indexed brawlId,
        address indexed user,
        uint256 indexed backedBrahId,
        uint256 amount,
        uint256 potA,
        uint256 potB
    );
    /// Both calls decrypt at once; staking opens on this event.
    event Revealed(uint256 indexed brawlId, int256 callA, int256 callB);
    /// @notice The anchor dropped: the measuring stick exists, and only now.
    ///         Both targets are derived on chain and carried here, so nobody
    ///         has to trust an off-chain multiplication about their money.
    event Anchored(
        uint256 indexed brawlId,
        int256 anchorValue,
        int256 targetA,
        int256 targetB
    );
    event Resolved(
        uint256 indexed brawlId,
        uint256 indexed winnerBrahId,
        uint256 indexed loserBrahId,
        uint256 totalPot,
        uint256 winnerPot,
        uint256 rake,
        int256 resolvedValue,
        int256 measured
    );
    /// @param whichBrah 1 = A out, 2 = B out, 3 = both, whether absent or
    ///        out of band.
    event Forfeited(uint256 indexed brawlId, uint8 whichBrah);
    event RakePaid(
        uint256 indexed brawlId,
        uint256 winnerAmt,
        uint256 spreadAmt,
        uint256 protocolAmt,
        uint256 burnAmt
    );
    /// @notice A vault leg reverted and the money went to the treasury
    ///         instead, so settlement could not strand a wei. Only reachable
    ///         on a wiring fault, and the treasury makes the brahs whole off
    ///         this event.
    event RakeLegFallback(uint256 indexed brawlId, uint8 leg, uint256 amount);
    /// @notice A clout write reverted and was swallowed so the pot could
    ///         still settle. Money is unaffected; only the record for
    ///         `brahId` was lost, and the keeper can republish it.
    /// @param kind 0 for an accuracy record, 1 for a forfeit.
    event CloutRecordFailed(
        uint256 indexed brawlId,
        uint256 indexed brahId,
        uint8 kind
    );
    event Voided(uint256 indexed brawlId, uint8 reason);
    event Claimed(uint256 indexed brawlId, address indexed user, uint256 amount);
    /// @notice A payee refused its ETH; the amount waits in {owed}.
    event Owed(address indexed to, uint256 amount);
    /// @notice A previously refused payment landed via {sweepOwed}.
    event OwedSwept(address indexed to, uint256 amount);
    event MinStakeUpdated(uint256 minStake);
    event MaxStakePerWalletUpdated(uint256 maxStakePerWallet);
    event OwnerStakeAllowedUpdated(bool allowed);
    event RakeConfigUpdated(
        uint256 rakeBps,
        uint256 winnerBps,
        uint256 spreadBps,
        uint256 protocolBps,
        uint256 burnBps
    );

    constructor(
        address _brahNft,
        address _cloutRegistry,
        address _rockModule,
        address _winningsVault,
        address _oracle,
        address _protocolTreasury,
        address _buyAndBurn,
        address _owner,
        address _operator
    ) Ownable(_owner) {
        require(_brahNft != address(0), "nft=0");
        require(_cloutRegistry != address(0), "clout=0");
        require(_rockModule != address(0), "rock=0");
        require(_winningsVault != address(0), "vault=0");
        require(_oracle != address(0), "oracle=0");
        require(_protocolTreasury != address(0), "treasury=0");
        require(_buyAndBurn != address(0), "burn=0");

        brahNft = _brahNft;
        cloutRegistry = _cloutRegistry;
        rockModule = IRockModule(_rockModule);
        winningsVault = IWinningsVault(_winningsVault);
        oracle = _oracle;
        protocolTreasury = _protocolTreasury;
        buyAndBurn = _buyAndBurn;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(OPERATOR_ROLE, _operator);
    }

    // --------------------------------------------------------------------- //
    // Owner config, which never touches escrowed pot funds
    // --------------------------------------------------------------------- //

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "oracle=0");
        oracle = _oracle;
    }

    function setProtocolTreasury(address _t) external onlyOwner {
        require(_t != address(0), "treasury=0");
        protocolTreasury = _t;
    }

    function setBuyAndBurn(address _b) external onlyOwner {
        require(_b != address(0), "burn=0");
        buyAndBurn = _b;
    }

    /// @notice Minimum per stake() call, in wei. 0 disables it.
    function setMinStake(uint256 _min) external onlyOwner {
        minStake = _min;
        emit MinStakeUpdated(_min);
    }

    /// @notice Ceiling on one wallet's total stake in a single brawl. 0
    ///         disables. Gates new stakes only.
    function setMaxStakePerWallet(uint256 _max) external onlyOwner {
        maxStakePerWallet = _max;
        emit MaxStakePerWalletUpdated(_max);
    }

    /// @notice Allow, or re-block, a brah's owner staking his own brah's
    ///         brawls. Gates new stakes only.
    function setOwnerStakeAllowed(bool _allowed) external onlyOwner {
        ownerStakeAllowed = _allowed;
        emit OwnerStakeAllowedUpdated(_allowed);
    }

    /**
     * @notice Set the rake and its split atomically. Affects only brawls
     *         resolved after the change; voided and forfeited brawls always
     *         refund in full.
     * @dev The rake never goes above MAX_RAKE_BPS, which is the launch value,
     *      so it can only be lowered. The splits must sum to exactly BPS.
     */
    function setRakeConfig(
        uint256 _rakeBps,
        uint256 _winnerBps,
        uint256 _spreadBps,
        uint256 _protocolBps,
        uint256 _burnBps
    ) external onlyOwner {
        require(_rakeBps <= MAX_RAKE_BPS, "rake>max");
        require(
            _winnerBps + _spreadBps + _protocolBps + _burnBps == BPS,
            "split!=BPS"
        );
        brawlRakeBps = _rakeBps;
        splitWinnerBps = _winnerBps;
        splitSpreadBps = _spreadBps;
        splitProtocolBps = _protocolBps;
        splitBurnBps = _burnBps;
        emit RakeConfigUpdated(
            _rakeBps,
            _winnerBps,
            _spreadBps,
            _protocolBps,
            _burnBps
        );
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------------------------------- //
    // Operator: create, reveal, anchor, resolve
    // --------------------------------------------------------------------- //

    /**
     * @notice Open a sealed brawl. Both calls arrive as commit hashes and
     *         nobody can stake until {reveal} publishes them.
     *
     * @param commitA keccak256(abi.encode(int256 callA, bytes32 saltA))
     * @param commitB keccak256(abi.encode(int256 callB, bytes32 saltB))
     * @param band |call| ceiling at CALL_SCALE, so 2.5% is 2_500_000. Fixed
     *        here, shown before staking opens, and enforced by {reveal}.
     * @param poolCap max potA+potB in wei; 0 for uncapped.
     *
     * @dev No rock, no brawl: both brahs must be activated at create time.
     *      Activation is deliberately re-checked nowhere else, since a rock
     *      lost mid-brawl does not cancel a brawl that was honestly opened.
     *
     *      Format-agnostic. The contract stores four timestamps and enforces
     *      only their ordering, so seal, stake, gap and race each have real
     *      duration. How long the gap runs is off-chain format config, like
     *      every other duration.
     */
    function create(
        uint256 brahA,
        uint256 brahB,
        uint8 category,
        string calldata question,
        bytes32 commitA,
        bytes32 commitB,
        uint64 revealAt,
        uint64 stakeCloseAt,
        uint64 anchorAt,
        uint64 resolveAt,
        bytes32 feedId,
        int256 band,
        uint256 poolCap
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused returns (uint256 brawlId) {
        require(brahA != brahB, "same brah");
        require(brahA != 0 && brahB != 0, "brah=0");
        require(
            rockModule.isActivated(brahA) &&
                rockModule.isActivated(brahB),
            "no rock, no brawl"
        );
        // Strict ordering: a sealed window, a staking window, the gap, then
        // a measurement window, each with real duration.
        require(revealAt > block.timestamp, "reveal past");
        require(stakeCloseAt > revealAt, "stakeClose<=reveal");
        require(anchorAt > stakeCloseAt, "anchor<=stakeClose");
        require(resolveAt > anchorAt, "resolve<=anchor");
        require(commitA != bytes32(0) && commitB != bytes32(0), "commit=0");
        // A band must exist and be sane. Zero would forfeit every reveal, and
        // a band at or past 100% down would admit a target at or below zero,
        // which the anchor math must never produce.
        require(band > 0 && band < CALL_SCALE, "bad band");

        brawlId = ++lastBrawlId;
        Brawl storage b = _brawls[brawlId];
        b.brahA = brahA;
        b.brahB = brahB;
        b.category = category;
        b.question = question;
        b.commitA = commitA;
        b.commitB = commitB;
        b.revealAt = revealAt;
        b.stakeCloseAt = stakeCloseAt;
        b.anchorAt = anchorAt;
        b.resolveAt = resolveAt;
        b.feedId = feedId;
        b.band = band;
        b.poolCap = poolCap;
        b.status = Status.Sealed;

        emit BrawlOpened(
            brawlId,
            brahA,
            brahB,
            category,
            question,
            revealAt,
            stakeCloseAt,
            anchorAt,
            resolveAt,
            feedId,
            commitA,
            commitB,
            band,
            poolCap
        );
    }

    /**
     * @notice Publish both calls at once. Staking opens on success, unless a
     *         call sits outside the band, in which case that fighter forfeits
     *         and everyone is refunded.
     *
     * @dev Both commits are verified in one transaction and either both land
     *      or neither does. The preimage is
     *      keccak256(abi.encode(int256 call, bytes32 salt)).
     *
     *      An out-of-band call does not reject the reveal, because rejecting
     *      a hash-matching reveal would strand the brawl in Sealed. It
     *      forfeits the fighter who made it, which is terminal and refunds in
     *      full. The operator clamps calls to the band at sealing, so this
     *      path firing at all means the off-chain pipeline glitched. On chain
     *      it is the public guarantee that no target can ever sit outside the
     *      anchor's band.
     */
    function reveal(
        uint256 brawlId,
        int256 callA,
        bytes32 saltA,
        int256 callB,
        bytes32 saltB
    ) external onlyRole(OPERATOR_ROLE) {
        Brawl storage b = _brawls[brawlId];
        require(b.status == Status.Sealed, "not sealed");
        require(block.timestamp >= b.revealAt, "too early");
        require(
            keccak256(abi.encode(callA, saltA)) == b.commitA,
            "commitA mismatch"
        );
        require(
            keccak256(abi.encode(callB, saltB)) == b.commitB,
            "commitB mismatch"
        );
        // Stored either way: on a band forfeit, the record of what was
        // revealed is the receipt that justifies the forfeit.
        b.callA = callA;
        b.callB = callB;

        bool outA = callA > b.band || callA < -b.band;
        bool outB = callB > b.band || callB < -b.band;
        if (outA || outB) {
            uint8 whichBrah = outA && outB ? 3 : (outA ? 1 : 2);
            b.status = Status.Forfeited;
            if (outA) _recordForfeit(brawlId, b.brahA);
            if (outB) _recordForfeit(brawlId, b.brahB);
            emit Revealed(brawlId, callA, callB);
            emit Forfeited(brawlId, whichBrah);
            return;
        }

        b.status = Status.Revealed;
        emit Revealed(brawlId, callA, callB);
    }

    /**
     * @notice Drop the anchor: snapshot the measuring stick and derive both
     *         targets. Until this instant no target existed, which is the
     *         whole design.
     *
     * @dev Runs strictly after the gap, so everything a staker learned during
     *      the window is stale before the race has a starting line.
     *
     *      Reads the feed through the same freshness gate as {resolve}.
     *      Operator only, since a permissionless anchor would let anyone pick
     *      the instant. It cannot strand funds: {forceVoid} refunds everyone
     *      after resolveAt plus VOID_GRACE. Not gated by pause, because a
     *      paused escrow must still carry an in-flight brawl to a terminal
     *      state where the money comes out.
     */
    function anchor(uint256 brawlId) external onlyRole(OPERATOR_ROLE) {
        Brawl storage b = _brawls[brawlId];
        require(b.status == Status.Revealed, "not revealed");
        require(block.timestamp >= b.anchorAt, "too early");

        // The fight runs regardless of the book. A one-sided or empty book
        // does not void here: the oracle still reads, the targets still
        // derive, and {resolve} still records both results, so clout and win
        // rate count every fight. The money keeps its promises in {_settle}.

        int256 anchorValue = _readFreshValue(b.feedId);
        // Every anchored quantity is a positive magnitude: a price, a level,
        // a period total. A non-positive read is a broken feed, and a target
        // derived from it would be meaningless about people's money.
        require(anchorValue > 0, "bad anchor");

        b.anchorValue = anchorValue;
        // target = anchor * (1 + call), in CALL_SCALE fixed point. Because
        // band < CALL_SCALE both factors are positive, so both targets are
        // too, and checked math reverts on the absurd rather than wrapping.
        b.targetA = (anchorValue * (CALL_SCALE + b.callA)) / CALL_SCALE;
        b.targetB = (anchorValue * (CALL_SCALE + b.callB)) / CALL_SCALE;
        b.status = Status.Locked;
        emit Anchored(brawlId, anchorValue, b.targetA, b.targetB);
    }

    /**
     * @notice Read the pin, crown the closer target, pay the pool, write the
     *         records.
     *
     * @dev The pin is the raw oracle read: no baseline subtraction, no modes.
     *      Distance is |target - pin| per side, against targets derived on
     *      chain at {anchor}. Both brahs are recorded on every resolve
     *      whoever won, because an average miss needs the loser's miss too,
     *      and the miss is measured from the target, since a relative call
     *      has no distance to a price without its anchor. Records are written
     *      before settlement but can never block it: each write is swallowed
     *      on revert and surfaced as {CloutRecordFailed}.
     *
     *      An exact tie has no honest winner, so both misses are recorded and
     *      the pot refunds in full.
     */
    function resolve(
        uint256 brawlId
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        Brawl storage b = _brawls[brawlId];
        require(b.status == Status.Locked, "not anchored");
        require(block.timestamp >= b.resolveAt, "too early");

        // Freshness gate before any state write or accuracy record.
        int256 measured = _readFreshValue(b.feedId);
        b.resolvedValue = measured;

        uint256 dA = _absDiff(b.targetA, measured);
        uint256 dB = _absDiff(b.targetB, measured);

        _recordResult(brawlId, b.brahA, b.category, dA < dB, b.targetA, measured);
        _recordResult(brawlId, b.brahB, b.category, dB < dA, b.targetB, measured);

        if (dA == dB) {
            // Equidistant to the decimal, so no honest winner, so full refund.
            _void(b, brawlId, VOID_EXACT_TIE);
            return;
        }

        _settle(b, brawlId, dA < dB ? b.brahA : b.brahB, measured, measured);
    }

    /**
     * @notice A brah did not show up. Refund everyone, take no rake, and
     *         record the forfeit against the absent brah. The present brah
     *         does not win, because money never settles on a brawl that did
     *         not happen.
     * @param whichBrah 1 = A absent, 2 = B absent, 3 = both.
     * @dev The forfeit lands on its own ledger and never touches accuracy.
     *      The operator classifies forfeit against void off chain, and both
     *      paths are money-identical, full refund and zero rake, so a
     *      misclassification can only move a reputation mark, never a wei.
     */
    function forfeit(
        uint256 brawlId,
        uint8 whichBrah
    ) external onlyRole(OPERATOR_ROLE) {
        Brawl storage b = _brawls[brawlId];
        require(
            b.status == Status.Sealed ||
                b.status == Status.Revealed ||
                b.status == Status.Locked,
            "not forfeitable"
        );
        require(whichBrah >= 1 && whichBrah <= 3, "bad brah");

        b.status = Status.Forfeited;

        if (whichBrah == 1 || whichBrah == 3) {
            _recordForfeit(brawlId, b.brahA);
        }
        if (whichBrah == 2 || whichBrah == 3) {
            _recordForfeit(brawlId, b.brahB);
        }

        emit Forfeited(brawlId, whichBrah);
    }

    /// @notice Our fault, not theirs: void the brawl and refund in full
    ///         without marking either brah. No record is touched. Not gated
    ///         by pause, since pausing must never block a brawl's route to a
    ///         refundable terminal state.
    function voidBrawl(uint256 brawlId) external onlyRole(OPERATOR_ROLE) {
        Brawl storage b = _brawls[brawlId];
        require(
            b.status == Status.Sealed ||
                b.status == Status.Revealed ||
                b.status == Status.Locked,
            "not voidable"
        );
        _void(b, brawlId, VOID_INFRA);
    }

    /// @notice Permissionless liveness backstop. If the operator goes dark at
    ///         any pre-terminal step, then once VOID_GRACE has elapsed past
    ///         resolveAt anyone may void the brawl, after which the usual
    ///         full-refund claim path applies. Never gated by pause: money in
    ///         the pot is always retrievable.
    function forceVoid(uint256 brawlId) external nonReentrant {
        Brawl storage b = _brawls[brawlId];
        require(
            b.status == Status.Sealed ||
                b.status == Status.Revealed ||
                b.status == Status.Locked,
            "not voidable"
        );
        require(
            block.timestamp > uint256(b.resolveAt) + VOID_GRACE,
            "grace active"
        );
        _void(b, brawlId, VOID_TIMEOUT);
    }

    // --------------------------------------------------------------------- //
    // Staking and claims
    // --------------------------------------------------------------------- //

    /**
     * @notice Stake native ETH on a brah. The msg.value is the stake, one
     *         transaction, nothing to approve. Pari-mutuel: every stake goes
     *         into one pool and the live ratio is the odds.
     *
     * @dev Requires status Revealed, so you always see both calls before you
     *      bet. What you do not see, by design, is the price they will be
     *      measured from, because the anchor does not exist until after the
     *      gap. A failed gate reverts the whole call, so a blocked stake
     *      hands every wei straight back:
     *        (a) players do not bet on the league. Any registered brah wallet
     *            is rejected outright.
     *        (b) a brah's owner cannot stake his own brah's brawls, either
     *            side, since betting against your own agent is the same
     *            conflict wearing a different hat.
     *        (c) the per-wallet cap on total exposure to this brawl.
     *        (d) the per-brawl pool cap, as a whole-stake revert rather than
     *            a partial fill.
     */
    function stake(
        uint256 brawlId,
        uint256 backedBrahId
    ) external payable nonReentrant whenNotPaused {
        uint256 amount = msg.value;
        Brawl storage b = _brawls[brawlId];
        require(b.status == Status.Revealed, "not open");
        require(block.timestamp < b.stakeCloseAt, "staking closed");
        require(amount > 0, "amount=0");
        require(amount >= minStake, "amount<min");
        require(
            backedBrahId == b.brahA || backedBrahId == b.brahB,
            "bad brah"
        );

        // (a) Any brah's wallet, whether or not it fights in this brawl, is
        // barred from staking, ever.
        require(
            IBrah999(brahNft).tbaToBrahId(msg.sender) == 0,
            "brah wallet"
        );

        // (b) Binds the NFT-holding wallet; alts are enforced off chain.
        if (!ownerStakeAllowed) {
            require(
                IBrah999(brahNft).ownerOf(b.brahA) != msg.sender &&
                    IBrah999(brahNft).ownerOf(b.brahB) != msg.sender,
                "brah owner"
            );
        }

        // (c) Per-wallet cap across both sides of this brawl. 0 disables.
        require(
            maxStakePerWallet == 0 ||
                stakeA[brawlId][msg.sender] +
                    stakeB[brawlId][msg.sender] +
                    amount <=
                maxStakePerWallet,
            "wallet cap"
        );

        // (d) Pool cap, as a whole-stake revert. A partial fill would hand
        // the staker a position they did not ask for. 0 is uncapped.
        require(
            b.poolCap == 0 || b.potA + b.potB + amount <= b.poolCap,
            "pool full"
        );

        // The ETH arrived with the call; only the books move here.
        if (backedBrahId == b.brahA) {
            b.potA += amount;
            stakeA[brawlId][msg.sender] += amount;
        } else {
            b.potB += amount;
            stakeB[brawlId][msg.sender] += amount;
        }
        emit Staked(brawlId, msg.sender, backedBrahId, amount, b.potA, b.potB);
    }

    /**
     * @notice Winning stakers claim their stake back plus a pro-rata share of
     *         the net losing pot. On a voided or forfeited brawl everyone
     *         reclaims their exact stake. Never gated by pause, and no double
     *         claim.
     * @dev Because the rake is capped at the losing pot, netPot is at least
     *      winnerPot, so distRemaining stays at or above winStakeRemaining at
     *      every step and each claimant is paid at least the stake he is
     *      claiming on. The last claimant drains the pot exactly, so floor
     *      dust lands on him rather than sitting in the escrow.
     */
    function claim(uint256 brawlId) external nonReentrant {
        Brawl storage b = _brawls[brawlId];
        require(
            b.status == Status.Resolved ||
                b.status == Status.Voided ||
                b.status == Status.Forfeited,
            "not claimable"
        );
        address user = msg.sender;
        require(!claimed[brawlId][user], "claimed");
        claimed[brawlId][user] = true;

        uint256 payout = _claimAccounting(b, brawlId, user);
        // On Resolved, zero means no stake on the winning side. On a refund
        // it means no stake at all. Two different facts, two words.
        if (b.status == Status.Resolved) require(payout > 0, "no winnings");
        require(payout > 0, "nothing to claim");
        // Every ledger above is written before this send. A wallet that
        // refuses ETH reverts the claim whole, the books roll back with it,
        // and the payout waits for a retry rather than being burned.
        (bool ok, ) = user.call{value: payout}("");
        require(ok, "eth refused");
        emit Claimed(brawlId, user, payout);
    }

    /**
     * @notice Claim across many brawls in one transaction and one transfer.
     *         Both claim paths key on msg.sender by design, since a third
     *         party must never choose when your money moves, which is also
     *         why a generic aggregator cannot batch them: the aggregator
     *         would be the sender. So the batching lives here, behind the
     *         same key.
     *
     * @dev Skip rather than revert, per id. An id that is not terminal yet,
     *      is already claimed, or holds nothing for this wallet costs nothing
     *      and contributes nothing. A claim-all raced by the operator's
     *      resolve must not revert the nine claims that are real because of
     *      the one that is not. `claimed` flips only on ids that actually
     *      pay, exactly as {claim} leaves a loser's flag untouched. One send
     *      at the end, since the point of the batch is one signature and one
     *      transfer, and the per-brawl events still say everything they said
     *      before. The only whole-call reverts are every id being skipped, or
     *      the wallet refusing its own money.
     */
    function claimMany(uint256[] calldata brawlIds) external nonReentrant {
        address user = msg.sender;
        uint256 total;
        for (uint256 i = 0; i < brawlIds.length; i++) {
            uint256 brawlId = brawlIds[i];
            Brawl storage b = _brawls[brawlId];
            if (
                b.status != Status.Resolved &&
                b.status != Status.Voided &&
                b.status != Status.Forfeited
            ) continue;
            // a duplicate id in the array lands here on its second pass
            if (claimed[brawlId][user]) continue;
            uint256 payout = _claimAccounting(b, brawlId, user);
            if (payout == 0) continue;
            claimed[brawlId][user] = true;
            total += payout;
            emit Claimed(brawlId, user, payout);
        }
        require(total > 0, "nothing to claim");
        (bool ok, ) = user.call{value: total}("");
        require(ok, "eth refused");
    }

    /// @dev The one place the payout arithmetic lives, shared by {claim} and
    ///      {claimMany}. Returns 0 without touching the remainders when this
    ///      wallet has nothing on the winning side, and the caller decides
    ///      whether 0 is a revert or a skip.
    function _claimAccounting(
        Brawl storage b,
        uint256 brawlId,
        address user
    ) internal returns (uint256 payout) {
        if (b.status == Status.Resolved) {
            uint256 userWinStake = (b.winnerBrahId == b.brahA)
                ? stakeA[brawlId][user]
                : stakeB[brawlId][user];
            if (userWinStake == 0) return 0;
            uint256 winRem = _winStakeRemaining[brawlId];
            uint256 distRem = _distRemaining[brawlId];
            payout = (distRem * userWinStake) / winRem;
            _winStakeRemaining[brawlId] = winRem - userWinStake;
            _distRemaining[brawlId] = distRem - payout;
        } else {
            // Voided or Forfeited: an exact refund of everything staked.
            payout = stakeA[brawlId][user] + stakeB[brawlId][user];
        }
    }

    // --------------------------------------------------------------------- //
    // Internal
    // --------------------------------------------------------------------- //

    /// @dev The one oracle read, used by both {anchor} and {resolve}. A feed
    ///      that was never written returns zeros without reverting, so
    ///      updatedAt is checked explicitly. Revert rather than void: a
    ///      revert leaves the pot intact and re-attemptable, and {forceVoid}
    ///      is the terminal backstop.
    function _readFreshValue(
        bytes32 feedId
    ) internal view returns (int256 value) {
        uint256 updatedAt;
        (value, updatedAt) = IOracle(oracle).latestValue(feedId);
        require(updatedAt != 0, "oracle unset");
        require(
            block.timestamp - updatedAt <= MAX_ORACLE_STALENESS,
            "oracle stale"
        );
    }

    /// @dev |a - b| for two oracle-scale values. Checked math reverts on
    ///      overflow.
    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        int256 d = a >= b ? a - b : b - a;
        return uint256(d);
    }

    /// @dev |a| for an oracle-scale value. Checked math reverts at
    ///      type(int256).min.
    function _abs(int256 a) internal pure returns (uint256) {
        return uint256(a >= 0 ? a : -a);
    }

    /**
     * @dev One brah's miss, in bps of the measured pin, where `pred` is his
     *      derived target, the number that actually competed. Relative, so a
     *      1% miss on one feed and a 1% miss on another are the same skill
     *      statistic. Nailing a zero pin is a perfect call; missing a zero
     *      pin records the cap rather than dividing by zero. The cap is
     *      applied before the multiplication, as a ratio compare, so an
     *      absurd number becomes the cap instead of an overflow revert that
     *      would strand the pot until forceVoid. Record side only: it never
     *      selects the winner and never touches money.
     */
    function _missBps(
        int256 pred,
        int256 measured
    ) internal pure returns (uint256) {
        if (measured == 0) return pred == 0 ? 0 : MAX_MISS_BPS;
        uint256 diff = _absDiff(pred, measured);
        uint256 denom = _abs(measured); // non-zero: |x| is 0 only when x is 0
        if (diff / denom >= MAX_MISS_BPS / BPS) return MAX_MISS_BPS;
        return (diff * BPS) / denom;
    }

    /// @dev The shared settlement tail: rake, pro-rata bookkeeping, payout.
    ///      Resolve lands here once it has a winner, so the money path is
    ///      defined in exactly one place.
    function _settle(
        Brawl storage b,
        uint256 brawlId,
        uint256 winner,
        int256 value,
        int256 measured
    ) internal {
        uint256 winnerPot = (winner == b.brahA) ? b.potA : b.potB;
        uint256 loserPot = (winner == b.brahA) ? b.potB : b.potA;
        uint256 totalPot = winnerPot + loserPot;

        // A skill winner with no backers has no pari-mutuel counterparty to
        // be paid from, so everyone gets their stake back.
        if (winnerPot == 0) {
            _void(b, brawlId, VOID_NO_WINNER_STAKE);
            return;
        }

        // The rake is a slice of the losing pot alone. The house only ever
        // takes from money that changed hands against the winners, so a
        // payout beats a stake whenever a counterparty exists, and payout is
        // at least stake structurally: netPot = winnerPot + loserPot minus a
        // slice of loserPot, which is at least winnerPot for any bps up to
        // BPS. With no losing pot the rake is zero and the winner simply gets
        // his stake back: no counterparty, no winnings, nothing to rake.
        // Floor rounding favours the stakers, and dropped wei stays in netPot
        // to be paid out by the running-remainder distribution in {claim}.
        // The rake config is read at resolve time rather than snapshotted at
        // create: owner only, hard capped, and lowerable only.
        uint256 rake = (loserPot * brawlRakeBps) / BPS;
        uint256 netPot = totalPot - rake;

        // Effects.
        uint256 loser = (winner == b.brahA) ? b.brahB : b.brahA;
        b.winnerBrahId = winner;
        b.winnerPot = winnerPot;
        b.netPot = netPot;
        b.status = Status.Resolved;
        _winStakeRemaining[brawlId] = winnerPot;
        _distRemaining[brawlId] = netPot;

        // Interactions: pay the rake splits.
        _payRake(brawlId, winner, rake);

        emit Resolved(
            brawlId,
            winner,
            loser,
            totalPot,
            winnerPot,
            rake,
            value,
            measured
        );
    }

    function _void(Brawl storage b, uint256 brawlId, uint8 reason) internal {
        b.status = Status.Voided;
        emit Voided(brawlId, reason);
    }

    /**
     * @dev The rake split, all four legs in native ETH:
     *        winner    a vault credit to the winner's brah wallet
     *        spread    a vault index deposit across all activated brahs,
     *                  pro-rata by rock weight
     *        protocol  the protocol treasury
     *        burn      the burn sink, swapped to $BRAH and destroyed on the
     *                  keeper's crank
     *      Rounding dust from the four splits goes to protocol.
     *
     *      The vault legs are payable calls, so the credit and the ETH
     *      backing it arrive together and cannot be split, which makes a
     *      successful credit backed by construction. If a vault call reverts,
     *      the value never left this contract and that leg re-routes to the
     *      treasury, surfaced as {RakeLegFallback}. The treasury and burn
     *      legs are bare pushes, which can be refused, so those fall into the
     *      {owed} ledger instead of blocking resolve. A bookkeeping failure
     *      is never worth a stranded pot.
     */
    function _payRake(uint256 brawlId, uint256 winner, uint256 rake) internal {
        uint256 winnerAmt = (rake * splitWinnerBps) / BPS;
        uint256 spreadAmt = (rake * splitSpreadBps) / BPS;
        uint256 protocolAmt = (rake * splitProtocolBps) / BPS;
        uint256 burnAmt = (rake * splitBurnBps) / BPS;
        // Rounding dust from the four splits goes to protocol.
        protocolAmt += rake - (winnerAmt + spreadAmt + protocolAmt + burnAmt);

        if (winnerAmt > 0) {
            try winningsVault.creditWinner{value: winnerAmt}(winner) {} catch {
                _sendOrOwe(protocolTreasury, winnerAmt);
                emit RakeLegFallback(brawlId, LEG_WINNER, winnerAmt);
            }
        }
        if (spreadAmt > 0) {
            try winningsVault.depositSpread{value: spreadAmt}() {} catch {
                _sendOrOwe(protocolTreasury, spreadAmt);
                emit RakeLegFallback(brawlId, LEG_SPREAD, spreadAmt);
            }
        }
        if (protocolAmt > 0) _sendOrOwe(protocolTreasury, protocolAmt);
        if (burnAmt > 0) _sendOrOwe(buyAndBurn, burnAmt);

        emit RakePaid(brawlId, winnerAmt, spreadAmt, protocolAmt, burnAmt);
    }

    /// @dev Push ETH, and if the payee refuses, book it as {owed} instead of
    ///      reverting. Only ever called on the rake legs: a staker's claim
    ///      must revert loudly, since it is his money and his retry, but a
    ///      rake payee refusing must never block the settlement everyone else
    ///      is waiting on.
    function _sendOrOwe(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) {
            owed[to] += amount;
            emit Owed(to, amount);
        }
    }

    /// @notice Retry a payment a payee once refused. Permissionless, since
    ///         the money already belongs to `to` and anyone may hand it over
    ///         once the payee can take it.
    function sweepOwed(address to) external nonReentrant {
        uint256 amount = owed[to];
        require(amount > 0, "nothing owed");
        owed[to] = 0;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "still refused");
        emit OwedSwept(to, amount);
    }

    /// @dev Write one accuracy record, swallowing a revert. A reputation
    ///      write must never brick the money path: the pot settles and the
    ///      failure is emitted. A record is never worth a pot.
    function _recordResult(
        uint256 brawlId,
        uint256 brahId,
        uint8 category,
        bool correct,
        int256 pred,
        int256 measured
    ) internal {
        try
            ICloutRegistry(cloutRegistry).recordResult(
                brahId,
                category,
                correct,
                _missBps(pred, measured)
            )
        {} catch {
            emit CloutRecordFailed(brawlId, brahId, CLOUT_KIND_RESULT);
        }
    }

    /// @dev The forfeit-ledger twin of {_recordResult}, same reasoning.
    function _recordForfeit(uint256 brawlId, uint256 brahId) internal {
        try ICloutRegistry(cloutRegistry).recordForfeit(brahId) {} catch {
            emit CloutRecordFailed(brawlId, brahId, CLOUT_KIND_FORFEIT);
        }
    }

    // --------------------------------------------------------------------- //
    // Views
    // --------------------------------------------------------------------- //

    function getBrawl(uint256 brawlId) external view returns (Brawl memory) {
        return _brawls[brawlId];
    }

    /// @notice A user's stake on a given brah in a brawl.
    function stakeOf(
        uint256 brawlId,
        address user,
        uint256 backedBrahId
    ) external view returns (uint256) {
        Brawl storage b = _brawls[brawlId];
        if (backedBrahId == b.brahA) return stakeA[brawlId][user];
        if (backedBrahId == b.brahB) return stakeB[brawlId][user];
        return 0;
    }

    function pots(
        uint256 brawlId
    ) external view returns (uint256 potA, uint256 potB, uint256 totalPot) {
        Brawl storage b = _brawls[brawlId];
        return (b.potA, b.potB, b.potA + b.potB);
    }

    function statusOf(uint256 brawlId) external view returns (Status) {
        return _brawls[brawlId].status;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
