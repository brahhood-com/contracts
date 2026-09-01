// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./IGenesis.sol";

/**
 * @title WinningsVault
 * @notice His winnings, his wallet. Rake lands here per brah, in native ETH:
 *           - the 2% winner leg is credited to the winning brah directly
 *           - the 3% spread leg accrues to every activated brah pro-rata by
 *             rock weight, through an O(1) cumulative index, so resolving a
 *             brawl costs the same gas whether six brahs are activated or six
 *             hundred. Balances materialise lazily in {settle}.
 *
 *         Native ETH throughout. A credit is always backed because
 *         {creditWinner} and {depositSpread} are payable and the msg.value is
 *         the amount, so the credit and its backing arrive in one call and
 *         cannot be split. On the way out there is only {claim}, which the
 *         owner calls on himself: a wallet that refuses ETH reverts the claim
 *         and the balance simply waits, still his.
 *
 *         The ledger is keyed by brahId, so a balance travels with the NFT.
 *         Sell the brah and his unclaimed treasury is priced into the sale.
 *         His token-bound account stays his identity wallet; keeping the
 *         winnings here is what makes the ledger enforceable at all.
 *
 *         Shells, the compute bucket, stay off chain by design.
 *
 *         Trust model: not upgradeable. Only escrows the admin has granted
 *         can write money in, only the rock module can change weights, only
 *         the brah's current owner can take money out.
 *
 *         The exposure, named: this vault holds one ETH pool against a ledger
 *         of per-brah balances, and the admin can grant ESCROW_ROLE to any
 *         address. A holder of that role can only credit what it sends, so
 *         there is no path that writes a balance without receiving the ETH
 *         behind it. What is left is who holds the admin role. It belongs on
 *         the multisig, and renouncing it once the last escrow is wired
 *         freezes the writer set permanently, at the cost of ever adding
 *         another brawl format.
 */
contract WinningsVault is AccessControl, ReentrancyGuard, IWinningsVault {
    /// @dev Granted to the brawl escrow, and to any future format's escrow.
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");

    uint256 public constant INDEX_SCALE = 1e18;

    IBrah999 public immutable nft;

    /// @dev The only writer of weights. Settable until {lockWiring}.
    IRockModule public rockModule;

    /// @dev Once true, {setRockModule} is closed for good.
    bool public wiringLocked;

    /// @dev Where a spread with zero activated weight goes. It cannot happen
    ///      while a fight is live, since both fighters are activated, but the
    ///      branch still needs an answer that is not stranded ETH. If the
    ///      fallback refuses, the deposit reverts back to the escrow, whose
    ///      own owed ledger keeps settlement unblockable.
    address public fallbackTreasury;

    struct BrahAccount {
        uint256 credited; // lifetime ETH landed in this wallet, settled
        uint256 claimed; // lifetime ETH withdrawn by owners
        uint256 weight; // current spread weight, mirrors the rock module
        uint256 lastIndexE18; // spread index at last settle
    }

    mapping(uint256 => BrahAccount) private _accounts;

    /// @dev Cumulative spread per unit of weight, scaled by INDEX_SCALE.
    uint256 public accIndexE18;
    /// @dev Sum of every activated brah's weight.
    uint256 public totalWeight;

    event RockModuleSet(address rockModule);
    event WiringLocked();
    event FallbackTreasurySet(address treasury);
    event WinnerCredited(uint256 indexed brahId, uint256 amount);
    event SpreadDeposited(uint256 amount, uint256 totalWeight);
    /// @dev Spread arrived with nobody activated, so it went to the treasury.
    event SpreadFallback(uint256 amount);
    event Settled(uint256 indexed brahId, uint256 pending);
    /// @dev A weight brought back to the rock module's truth by {syncWeight}.
    event WeightSynced(uint256 indexed brahId, uint256 weight);
    event Claimed(
        uint256 indexed brahId,
        address indexed owner,
        uint256 amount
    );

    constructor(address _nft, address _admin) {
        require(_nft != address(0), "nft=0");
        require(_admin != address(0), "admin=0");
        nft = IBrah999(_nft);
        fallbackTreasury = _admin;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // --------------------------------------------------------------------- //
    // Wiring
    // --------------------------------------------------------------------- //

    /// @dev Re-pointable only until {lockWiring}. A replacement rock module
    ///      arrives with an empty weight ledger, so this is a pre-mint repair
    ///      window, never a live migration.
    function setRockModule(
        address _rockModule
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!wiringLocked, "wiring locked");
        require(_rockModule != address(0), "module=0");
        rockModule = IRockModule(_rockModule);
        emit RockModuleSet(_rockModule);
    }

    /// @notice Freeze {setRockModule} forever. This is the call that makes
    ///         "only the rock module can change weights" final.
    function lockWiring() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!wiringLocked, "locked");
        require(address(rockModule) != address(0), "module unset");
        wiringLocked = true;
        emit WiringLocked();
    }

    function setFallbackTreasury(
        address _treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "treasury=0");
        fallbackTreasury = _treasury;
        emit FallbackTreasurySet(_treasury);
    }

    // --------------------------------------------------------------------- //
    // Money in, escrow only, and the ETH is the argument
    // --------------------------------------------------------------------- //

    /// @notice The 2% leg: the winner's brah wallet. msg.value is the credit.
    function creditWinner(
        uint256 brahId
    ) external payable onlyRole(ESCROW_ROLE) {
        require(msg.value > 0, "value=0");
        _settle(brahId);
        _accounts[brahId].credited += msg.value;
        emit WinnerCredited(brahId, msg.value);
    }

    /**
     * @notice The 3% leg, spread across every activated brah by rock weight.
     *         msg.value is the deposit.
     * @dev Floor rounding leaves dust, under totalWeight wei per deposit, in
     *      the vault's balance rather than over-crediting. Always in the
     *      ledger's favour, never a shortfall.
     */
    function depositSpread() external payable onlyRole(ESCROW_ROLE) {
        require(msg.value > 0, "value=0");
        if (totalWeight == 0) {
            // Nobody to spread over. Refusing here would strand the leg, so
            // it goes to the treasury. If the treasury refuses too, the
            // revert hands the ETH back to the escrow and its owed ledger
            // takes over.
            (bool ok, ) = fallbackTreasury.call{value: msg.value}("");
            require(ok, "fallback refused");
            emit SpreadFallback(msg.value);
            return;
        }
        accIndexE18 += (msg.value * INDEX_SCALE) / totalWeight;
        emit SpreadDeposited(msg.value, totalWeight);
    }

    // --------------------------------------------------------------------- //
    // Weight sync, rock module only
    // --------------------------------------------------------------------- //

    /// @notice Settle accrual at the old weight, then apply the new one.
    ///         Called on every activation, upgrade and transfer reset, so the
    ///         two ledgers cannot drift.
    function updateWeight(uint256 brahId, uint256 newWeight) external {
        require(msg.sender == address(rockModule), "not rock module");
        BrahAccount storage a = _accounts[brahId];
        _settle(brahId);
        totalWeight = totalWeight - a.weight + newWeight;
        a.weight = newWeight;
    }

    // --------------------------------------------------------------------- //
    // Money out, current owner
    // --------------------------------------------------------------------- //

    /**
     * @notice Claim winnings to the owner's wallet as native ETH. `amount`
     *         is in wei; zero claims everything available.
     * @dev Claimable is simply what landed minus what was taken. There is no
     *      tier gate: the rock sizes what lands here, it has never decided
     *      what may leave. The ledger is written before the send, so a wallet
     *      that refuses ETH reverts the whole claim and the balance stays
     *      his. Nothing is burned and nothing is stranded; he retries from a
     *      wallet that takes money.
     */
    function claim(uint256 brahId, uint256 amount) external nonReentrant {
        address owner_ = nft.ownerOf(brahId);
        require(msg.sender == owner_, "not owner");

        _settle(brahId);
        uint256 max = claimableOf(brahId);
        if (amount == 0) amount = max;
        require(amount > 0, "nothing claimable");
        require(amount <= max, "gate");

        _accounts[brahId].claimed += amount;
        (bool ok, ) = owner_.call{value: amount}("");
        require(ok, "eth refused");
        emit Claimed(brahId, owner_, amount);
    }

    /// @notice Sweep a whole stable in one transaction and one transfer.
    ///         Every id must belong to the caller, since claiming a
    ///         stranger's brah is a mistake worth stopping loudly. One of his
    ///         own with nothing to take is skipped for free, so a sweep raced
    ///         by another sweep still pays out whatever is left.
    function claimMany(uint256[] calldata brahIds) external nonReentrant {
        uint256 total;
        for (uint256 i = 0; i < brahIds.length; i++) {
            uint256 brahId = brahIds[i];
            require(msg.sender == nft.ownerOf(brahId), "not owner");
            _settle(brahId);
            uint256 amount = claimableOf(brahId);
            if (amount == 0) continue;
            _accounts[brahId].claimed += amount;
            total += amount;
            emit Claimed(brahId, msg.sender, amount);
        }
        require(total > 0, "nothing claimable");
        (bool ok, ) = msg.sender.call{value: total}("");
        require(ok, "eth refused");
    }

    /// @notice Materialise a brah's pending accrual. Anyone may crank a card
    ///         current; money still only moves through {claim}.
    function settle(uint256 brahId) external {
        _settle(brahId);
    }

    /**
     * @notice Sync one brah's weight to what the rock module actually says.
     *         Permissionless, because it can only move the ledger toward the
     *         module's truth, and it settles accrual at the old weight first.
     *
     * @dev Two jobs. Day to day it heals drift, so a missed push can be
     *      corrected by anyone. At a vault swap it is the seeder: a
     *      replacement vault starts with an empty weight ledger while brahs
     *      already hold rocks, and one call per activated brah rebuilds
     *      totalWeight straight from the module, with no admin-supplied
     *      numbers anywhere.
     */
    function syncWeight(uint256 brahId) external {
        uint256 w = rockModule.weightOf(brahId);
        BrahAccount storage a = _accounts[brahId];
        if (a.weight == w) return;
        _settle(brahId);
        totalWeight = totalWeight - a.weight + w;
        a.weight = w;
        emit WeightSynced(brahId, w);
    }

    // --------------------------------------------------------------------- //
    // Views
    // --------------------------------------------------------------------- //

    /// @notice The balance on his card: everything landed minus everything
    ///         claimed, pending accrual included.
    function walletOf(uint256 brahId) external view returns (uint256) {
        BrahAccount storage a = _accounts[brahId];
        return a.credited + _pendingOf(a) - a.claimed;
    }

    /// @notice What the current owner could withdraw right now, which is
    ///         everything he has not already taken. Note what this means for
    ///         a rockless brah: he stops accruing, but keeps every wei he
    ///         already earned.
    function claimableOf(uint256 brahId) public view returns (uint256) {
        BrahAccount storage a = _accounts[brahId];
        uint256 credited = a.credited + _pendingOf(a);
        return credited > a.claimed ? credited - a.claimed : 0;
    }

    function accountOf(
        uint256 brahId
    )
        external
        view
        returns (
            uint256 credited,
            uint256 claimed,
            uint256 weight,
            uint256 pending
        )
    {
        BrahAccount storage a = _accounts[brahId];
        return (a.credited, a.claimed, a.weight, _pendingOf(a));
    }

    // --------------------------------------------------------------------- //
    // Internal
    // --------------------------------------------------------------------- //

    function _settle(uint256 brahId) internal {
        BrahAccount storage a = _accounts[brahId];
        uint256 pending = _pendingOf(a);
        if (pending > 0) {
            a.credited += pending;
            emit Settled(brahId, pending);
        }
        a.lastIndexE18 = accIndexE18;
    }

    function _pendingOf(
        BrahAccount storage a
    ) internal view returns (uint256) {
        return (a.weight * (accIndexE18 - a.lastIndexE18)) / INDEX_SCALE;
    }
}
