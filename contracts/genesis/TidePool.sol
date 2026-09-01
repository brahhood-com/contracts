// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title TidePool
 * @notice The NFT vault. Two-way, priced in $BRAH, three verbs:
 *           SELL   any brah for instant $BRAH, no fee, because the exit
 *                  should be frictionless
 *           SWAP   your brah for the next one in the vault, flat ETH fee
 *           SNIPE  a specific number out of the vault, flat ETH fee
 *         Trade brahs nearly free. The fights pay the holders.
 *
 *         Pricing is a linear step curve over protocol-owned liquidity. SELL
 *         pays `spotPrice - delta` and steps spot down, SNIPE costs
 *         `spotPrice + delta` and steps spot up, SWAP never moves the price.
 *         A round trip through the vault nets zero in $BRAH by construction,
 *         because the real toll is the rock reset that fires on every
 *         transfer and burns $BRAH when the next owner re-rocks. That is the
 *         whole design: no royalty at home, the reset is the toll.
 *
 *         Flat ETH fees forward to the treasury on receipt, so the vault's
 *         own ETH balance is zero before and after every call.
 *
 *         Secondary only. Unminted brahs cannot enter, because they have no
 *         owner to sell them. Ancients ride through with their rock, and a
 *         brah's wallet balance travels with the id, priced into the snipe by
 *         whoever reads the card.
 *
 *         Trust model: not upgradeable. The owner manages protocol liquidity
 *         and repricing, all of it evented, but can never touch a user mid
 *         trade. Every verb settles atomically, and {MAX_FEE_WEI} caps the
 *         flat fees so no repricing can quietly close the exits.
 */
contract TidePool is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * Hard ceiling on both flat ETH fees. The fees are a toll on churn, not a
     * gate: an owner able to set them to 100 ETH would close SWAP and SNIPE
     * without touching {pause}, and SWAP is the verb that always moves a brah
     * out of the vault whatever the curve says.
     */
    uint256 public constant MAX_FEE_WEI = 0.05 ether;

    IERC721 public immutable nft;
    IERC20 public immutable brah;

    /// @dev Where the flat ETH fees land.
    address public treasury;

    /// @dev Curve state: spot in $BRAH wei, and the step per trade.
    uint256 public spotPrice;
    uint256 public delta;

    /// @dev The flat ETH tolls, at their launch values.
    uint256 public swapFeeWei = 0.005 ether;
    uint256 public snipeFeeWei = 0.015 ether;

    /// @dev FIFO queue of inventory, for "the next vault brah". Sniped ids
    ///      stay in the queue as tombstones and are skipped on pop.
    mapping(uint256 => uint256) private _queue;
    uint256 private _head;
    uint256 private _tail;
    mapping(uint256 => bool) public inVault;
    uint256 public inventory;

    event TreasurySet(address treasury);
    event PricingSet(uint256 spotPrice, uint256 delta);
    event FeesSet(uint256 swapFeeWei, uint256 snipeFeeWei);
    event Sold(uint256 indexed brahId, address indexed seller, uint256 paidBrah);
    event Swapped(
        uint256 indexed brahIdIn,
        uint256 indexed brahIdOut,
        address indexed trader
    );
    event Sniped(uint256 indexed brahId, address indexed buyer, uint256 paidBrah);
    event LiquidityDeposited(uint256 brahAmount);
    event LiquidityWithdrawn(uint256 brahAmount);
    event InventoryWithdrawn(uint256 indexed brahId, address to);

    constructor(
        address _nft,
        address _brah,
        address _treasury,
        uint256 _spotPrice,
        uint256 _delta,
        address _owner
    ) Ownable(_owner) {
        require(_nft != address(0), "nft=0");
        require(_brah != address(0), "brah=0");
        require(_treasury != address(0), "treasury=0");
        require(_delta > 0 && _spotPrice > _delta, "curve");
        nft = IERC721(_nft);
        brah = IERC20(_brah);
        treasury = _treasury;
        spotPrice = _spotPrice;
        delta = _delta;
    }

    // --------------------------------------------------------------------- //
    // Quotes
    // --------------------------------------------------------------------- //

    /// @notice What the vault pays for the next sell.
    function sellQuote() public view returns (uint256) {
        return spotPrice - delta;
    }

    /// @notice What the next snipe costs, before the flat ETH fee.
    function snipeQuote() public view returns (uint256) {
        return spotPrice + delta;
    }

    // --------------------------------------------------------------------- //
    // The three verbs
    // --------------------------------------------------------------------- //

    /// @notice Sell your brah for instant $BRAH at {sellQuote}. No fee and no
    ///         royalty. The rock reset the transfer fires is the toll.
    function sell(uint256 brahId) external nonReentrant whenNotPaused {
        uint256 price = sellQuote();
        require(spotPrice - delta >= delta, "pool at floor");
        require(
            brah.balanceOf(address(this)) >= price,
            "vault dry"
        );

        spotPrice -= delta;
        _push(brahId);

        nft.transferFrom(msg.sender, address(this), brahId);
        brah.safeTransfer(msg.sender, price);
        emit Sold(brahId, msg.sender, price);
    }

    /// @notice Swap your brah for the next one in the vault. Flat ETH fee, no
    ///         $BRAH moves, and the price stays where it was.
    function swap(uint256 brahIdIn) external payable nonReentrant whenNotPaused {
        require(msg.value == swapFeeWei, "bad fee");
        uint256 brahIdOut = _pop(); // reverts when the vault is empty
        require(brahIdOut != brahIdIn, "same brah");

        _push(brahIdIn);

        nft.transferFrom(msg.sender, address(this), brahIdIn);
        nft.transferFrom(address(this), msg.sender, brahIdOut);
        _forwardFee();
        emit Swapped(brahIdIn, brahIdOut, msg.sender);
    }

    /// @notice Take a specific number out of the vault at {snipeQuote} in
    ///         $BRAH, plus the flat ETH fee. Records are public, so sniping
    ///         is scouting.
    function snipe(uint256 brahId) external payable nonReentrant whenNotPaused {
        require(msg.value == snipeFeeWei, "bad fee");
        require(inVault[brahId], "not in vault");
        uint256 price = snipeQuote();

        spotPrice += delta;
        _remove(brahId);

        brah.safeTransferFrom(msg.sender, address(this), price);
        nft.transferFrom(address(this), msg.sender, brahId);
        _forwardFee();
        emit Sniped(brahId, msg.sender, price);
    }

    // --------------------------------------------------------------------- //
    // Protocol liquidity, owner only, all evented
    // --------------------------------------------------------------------- //

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "treasury=0");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /**
     * @notice Reprice the curve.
     * @dev Unbounded on purpose, and it cannot strand inventory: {swap} reads
     *      neither spot nor delta and costs only the capped flat fee, so
     *      every brah in the vault keeps a bounded-cost exit at any pricing.
     *      The curve gates only what the vault pays on a sell and what a
     *      targeted snipe costs, both of which are meant to move with the
     *      token.
     */
    function setPricing(uint256 _spotPrice, uint256 _delta) external onlyOwner {
        require(_delta > 0 && _spotPrice > _delta, "curve");
        spotPrice = _spotPrice;
        delta = _delta;
        emit PricingSet(_spotPrice, _delta);
    }

    /// @notice Re-set the flat ETH tolls. {MAX_FEE_WEI} caps both, so the
    ///         dial can never become an off switch for swapping or sniping.
    function setFees(
        uint256 _swapFeeWei,
        uint256 _snipeFeeWei
    ) external onlyOwner {
        require(_swapFeeWei <= MAX_FEE_WEI, "swap fee>cap");
        require(_snipeFeeWei <= MAX_FEE_WEI, "snipe fee>cap");
        swapFeeWei = _swapFeeWei;
        snipeFeeWei = _snipeFeeWei;
        emit FeesSet(_swapFeeWei, _snipeFeeWei);
    }

    /// @notice Seed or deepen the $BRAH side.
    function depositLiquidity(uint256 amount) external onlyOwner {
        brah.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityDeposited(amount);
    }

    /// @notice Withdraw protocol-owned $BRAH.
    function withdrawLiquidity(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "to=0");
        brah.safeTransfer(to, amount);
        emit LiquidityWithdrawn(amount);
    }

    /// @notice Withdraw a vault brah. The vault paid for every one it holds.
    function withdrawInventory(uint256 brahId, address to) external onlyOwner {
        require(to != address(0), "to=0");
        require(inVault[brahId], "not in vault");
        _remove(brahId);
        nft.transferFrom(address(this), to, brahId);
        emit InventoryWithdrawn(brahId, to);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------------------------------- //
    // Internal
    // --------------------------------------------------------------------- //

    function _push(uint256 brahId) internal {
        _queue[_tail++] = brahId;
        inVault[brahId] = true;
        inventory += 1;
    }

    /// @dev Pop the next live id, skipping tombstones left behind by snipes
    ///      and inventory withdrawals.
    function _pop() internal returns (uint256 brahId) {
        while (_head < _tail) {
            brahId = _queue[_head];
            delete _queue[_head];
            _head++;
            if (inVault[brahId]) {
                inVault[brahId] = false;
                inventory -= 1;
                return brahId;
            }
        }
        revert("vault empty");
    }

    function _remove(uint256 brahId) internal {
        inVault[brahId] = false; // the queue entry becomes a tombstone
        inventory -= 1;
    }

    function _forwardFee() internal {
        (bool ok, ) = treasury.call{value: address(this).balance}("");
        require(ok, "treasury refused");
    }
}
