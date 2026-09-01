// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ShellShop
 * @notice Buy shells, talk to brahs. Shells are prepaid chat credit owned by
 *         a wallet, not a compute balance owned by a brah. You buy them once
 *         and spend them talking to any brah in the forest. The only gate is
 *         your own balance.
 *
 *         A brah's brawl inference is paid for by the platform, so his
 *         thinking is never a metered balance that can run dry, and "no rock,
 *         no brawl" stays the single gate on fighting. Nothing here knows a
 *         brahId; this contract has never heard of the NFT.
 *
 *         The event is the interface. No ledger lives here and no per-wallet
 *         state is kept. Shells are an off-chain credit balance whose only
 *         writer is the indexer, and {ShellsPurchased} carries everything
 *         that credit needs: who paid, and how much. It fires exactly once
 *         per successful purchase, and the indexer prices it at the ETH/USD
 *         spot for the block.
 *
 *         Native ETH in, native ETH out. Purchases arrive as ETH, one
 *         transaction with no approve and no wrap, and forward to the
 *         treasury as ETH in the same call. A treasury that refuses the push
 *         reverts the purchase whole: the buyer keeps his money and nothing
 *         is stranded. Since `treasury` is owner-settable, a refusal is a
 *         config fix rather than a bricked contract.
 *
 *         Trust model: not upgradeable. Pausing blocks new purchases only. It
 *         strands nothing, because this contract never holds anyone's money,
 *         and credit already bought lives off chain untouched.
 */
contract ShellShop is Ownable, Pausable {
    using SafeERC20 for IERC20;

    /**
     * Hard ceiling on {minPurchaseWei}. The minimum exists to stop dust, not
     * to gate buying. "Anyone can buy shells and talk to him" is the whole
     * point of this contract, and a minimum settable to 100 ETH would revoke
     * that without touching {pause}.
     */
    uint256 public constant MAX_MIN_PURCHASE_WEI = 0.05 ether;

    /// Where purchases land, in native ETH.
    address public treasury;

    /**
     * Smallest accepted purchase, in wei. Zero disables the floor, and a
     * zero-value purchase is rejected either way.
     *
     * A dust purchase costs more gas to index than it credits, and shells are
     * metered in USD, so anything below the ledger's rounding credits
     * nothing at all. That is this contract's core failure mode, money in and
     * nothing out, in miniature.
     */
    uint256 public minPurchaseWei;

    /**
     * @notice Shells were bought. The indexer credits `amountWei` of shells
     *         to `buyer`, priced at the ETH/USD spot at credit time.
     * @param buyer The wallet this chat credit belongs to. Shells spend
     *              against any brah; there is no per-brah balance.
     * @param amountWei Value paid in wei, which is exactly what the treasury
     *                  received in the same transaction.
     */
    event ShellsPurchased(address indexed buyer, uint256 amountWei);

    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event MinPurchaseUpdated(uint256 oldMinWei, uint256 newMinWei);
    /// @dev Stranded value was swept. `token` is address(0) for native ETH.
    event Rescued(address indexed token, uint256 amount);

    constructor(
        address _treasury,
        uint256 _minPurchaseWei,
        address _owner
    ) Ownable(_owner) {
        require(_treasury != address(0), "treasury=0");
        require(_treasury != address(this), "treasury=self");
        require(_minPurchaseWei <= MAX_MIN_PURCHASE_WEI, "min>cap");

        treasury = _treasury;
        minPurchaseWei = _minPurchaseWei;
    }

    /**
     * @notice Buy shells with native ETH. Open to any wallet, and the credit
     *         spends against any brah you talk to.
     * @dev Forwards to the treasury in the same transaction, so this
     *      contract's balance is zero before and after. A refused forward
     *      reverts the purchase whole.
     */
    function buyShells() external payable whenNotPaused {
        // Checked separately from the floor, because minPurchaseWei == 0
        // disables the floor and a zero-wei purchase would otherwise sail
        // through and emit an event that costs a write and credits nothing.
        require(msg.value > 0, "amount=0");
        require(msg.value >= minPurchaseWei, "amount<min");

        (bool ok, ) = treasury.call{value: msg.value}("");
        require(ok, "treasury refused");

        emit ShellsPurchased(msg.sender, msg.value);
    }

    /// @notice Point purchases at a new treasury.
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "treasury=0");
        // address(this) would quietly pile ETH up here instead of paying the
        // protocol, turning a contract that holds nothing into one that does.
        require(_treasury != address(this), "treasury=self");
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /// @notice Set the dust floor. Zero disables it, {MAX_MIN_PURCHASE_WEI}
    ///         caps it.
    function setMinPurchase(uint256 _minPurchaseWei) external onlyOwner {
        require(_minPurchaseWei <= MAX_MIN_PURCHASE_WEI, "min>cap");
        emit MinPurchaseUpdated(minPurchaseWei, _minPurchaseWei);
        minPurchaseWei = _minPurchaseWei;
    }

    /**
     * @notice Stop accepting new purchases.
     * @dev The valve for the failure this contract is built around. If the
     *      credit side is broken, taking ETH for shells nobody is crediting
     *      is worse than refusing it. Pausing strands nobody: no user funds
     *      are held here, and credit already bought is untouched.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume accepting purchases.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sweep force-sent native ETH to the treasury.
    /// @dev Unreachable in normal operation: the entry point forwards every
    ///      wei it receives and there is deliberately no receive(), so ETH
    ///      can only land here through a selfdestruct or a block reward. This
    ///      exists so "stuck forever" has an answer.
    function rescueEth() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "nothing");

        (bool ok, ) = treasury.call{value: bal}("");
        require(ok, "treasury refused");

        emit Rescued(address(0), bal);
    }

    /// @notice Sweep stranded ERC20 to the treasury.
    function rescueToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "token=0");
        IERC20(token).safeTransfer(treasury, amount);
        emit Rescued(token, amount);
    }

    // No receive() or fallback(), deliberately. A bare ETH transfer here
    // looks identical to a purchase at the wire level but carries no intent
    // to buy, and crediting it would let a stray transfer mint chat credit.
    // Reverting hands the ETH back at the only moment anyone still can.
    //
    // No reentrancy guard either: {buyShells} writes no storage, so a
    // reentrant call has nothing to corrupt. The only external call is the
    // treasury forward, and a treasury that reenters can only buy shells
    // with its own money.
}
