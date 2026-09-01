// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CloutRegistry
 * @notice The reputation ledger for brahs. It holds three things: a trust
 *         score published by a keeper, a permanent per-category accuracy
 *         record written by the escrow when a brawl resolves, and a forfeit
 *         count kept well away from both.
 *
 *         Forfeits never touch accuracy on purpose. Missing a fight says
 *         nothing about how good your calls are, so it does not go in the
 *         skill record.
 *
 *         The escrow and the keeper hold WRITER_ROLE.
 */
contract CloutRegistry is AccessControl {
    bytes32 public constant WRITER_ROLE = keccak256("WRITER_ROLE");

    uint256 public constant MAX_SCORE = 1000;

    /**
     * @dev Accuracy for one brah in one category.
     *  - correct:    times this brah landed closer to the pin, for result cards
     *  - total:      calls resolved, the sample size
     *  - cumMissBps: running sum of miss in bps, so average miss is
     *                cumMissBps / total with no replay needed
     */
    struct Accuracy {
        uint256 correct;
        uint256 total;
        uint256 cumMissBps;
    }

    /// @dev brahId => trust score, 0..1000
    mapping(uint256 => uint256) private _scores;

    /// @dev brahId => category => accuracy record
    mapping(uint256 => mapping(uint8 => Accuracy)) private _accuracy;

    /// @dev brahId => lifetime forfeits, deliberately kept out of Accuracy
    mapping(uint256 => uint256) private _forfeits;

    /// @notice Current season pointer, advanced by the admin.
    uint256 public currentSeason;

    event ScoreUpdated(uint256 indexed brahId, uint256 score, int256 delta);
    event AccuracyRecorded(
        uint256 indexed brahId,
        uint8 indexed category,
        uint256 correct,
        uint256 total,
        uint256 missBps,
        uint256 cumMissBps
    );
    event ForfeitRecorded(uint256 indexed brahId, uint256 count);
    event SeasonAdvanced(uint256 indexed season);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        currentSeason = 1;
    }

    /// @notice Publish a brah's trust score. Emits the signed delta.
    function setScore(
        uint256 brahId,
        uint256 score
    ) external onlyRole(WRITER_ROLE) {
        require(score <= MAX_SCORE, "score>1000");
        int256 delta = int256(score) - int256(_scores[brahId]);
        _scores[brahId] = score;
        emit ScoreUpdated(brahId, score, delta);
    }

    /**
     * @notice Record one call outcome. `total` always moves, `correct` moves
     *         when this brah was the closer of the two, and `cumMissBps`
     *         always takes the miss. The escrow caps the miss before it gets
     *         here, so one wild call cannot wreck a lifetime average.
     */
    function recordResult(
        uint256 brahId,
        uint8 category,
        bool correct,
        uint256 missBps
    ) external onlyRole(WRITER_ROLE) {
        Accuracy storage a = _accuracy[brahId][category];
        a.total += 1;
        if (correct) a.correct += 1;
        a.cumMissBps += missBps;
        emit AccuracyRecorded(
            brahId,
            category,
            a.correct,
            a.total,
            missBps,
            a.cumMissBps
        );
    }

    /// @notice Record a no-show. Its own ledger, never the accuracy record.
    function recordForfeit(uint256 brahId) external onlyRole(WRITER_ROLE) {
        uint256 count = ++_forfeits[brahId];
        emit ForfeitRecorded(brahId, count);
    }

    /// @notice Move to the next season. Prize accounting lives elsewhere.
    function advanceSeason() external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentSeason += 1;
        emit SeasonAdvanced(currentSeason);
    }

    /// @notice Set the season pointer directly.
    function setSeason(uint256 season) external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentSeason = season;
        emit SeasonAdvanced(season);
    }

    function scoreOf(uint256 brahId) external view returns (uint256) {
        return _scores[brahId];
    }

    /// @notice Wins, calls and cumulative miss for one brah in one category.
    function accuracy(
        uint256 brahId,
        uint8 category
    )
        external
        view
        returns (uint256 correct, uint256 total, uint256 cumMissBps)
    {
        Accuracy memory a = _accuracy[brahId][category];
        return (a.correct, a.total, a.cumMissBps);
    }

    /// @notice Lifetime forfeit count for a brah.
    function forfeitsOf(uint256 brahId) external view returns (uint256) {
        return _forfeits[brahId];
    }
}
