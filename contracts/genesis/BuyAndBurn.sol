// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @dev The UniversalRouter, which is the only way into a V4 pool.
 *
 *      V4 has no per-pool router and no per-pool contract at all. Every pool
 *      lives inside one PoolManager singleton, reachable only through an
 *      `unlock` callback, and `execute` is that entry point. `commands` is
 *      one byte per top-level command, `inputs[i]` holds that command's
 *      encoded arguments, and `deadline` is the router's own, which is why a
 *      late crank fails as `TransactionDeadlinePassed()`.
 */
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

/**
 * @dev The V4 PoolKey, field for field.
 *
 *      This struct is the pool. There is no pair address on V4: the pool's
 *      identity is these five fields and their hash. Getting one wrong does
 *      not revert, it names a pool nobody ever created, so every read comes
 *      back empty and every swap fails. That is why the fields are pinned at
 *      deploy rather than passed per crank. See {BuyAndBurn.v4PoolKey}.
 *
 *      currency0 must sort strictly below currency1 by address. The zero
 *      address is native ETH and sorts below every token, so this pool always
 *      has native as currency0 and buying $BRAH is always zeroForOne.
 */
struct V4PoolKey {
    address currency0;
    address currency1;
    /// @dev LP fee in hundredths of a bip: 3000 is 0.30%
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/**
 * @dev The router's ExactInputSingleParams, field for field.
 *
 *      The field order is the wire format. The router decodes this by casting
 *      a calldata pointer, so reordering here would not fail to decode, it
 *      would decode into different values.
 */
struct V4ExactInputSingleParams {
    V4PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/**
 * @dev The only shape a migration may target: a burn sink for the same
 *      token. Read-only, so a destination that cannot answer is not a
 *      destination.
 */
interface IBurnSink {
    function brah() external view returns (address);
}

/**
 * @title BuyAndBurn
 * @notice The rake's burn leg. The escrow forwards it here in native ETH on
 *         every resolve, and a keeper then cranks: ETH into $BRAH on the V4
 *         pool seeded at launch, and all of it burned in the same
 *         transaction. Nothing bought here can ever leave as $BRAH.
 *
 *         Native only, V4 only. The escrow pays native, the pool wants
 *         native, and this contract holds the one currency both sides speak.
 *         There is nothing to convert: the balance is the burn pool.
 *
 *         The swap is not inline in resolve. Keeping it separate holds
 *         settlement gas flat, keeps the oracle path off DEX liveness, and
 *         means a sandwich cannot be timed off a public resolve transaction.
 *         Accumulating and cranking on the keeper's schedule, with its own
 *         minOut, is the boring shape.
 *
 *         The open door, named: {receive} takes ETH from anyone. Every wei
 *         that lands is spendable by the next {crank} and movable by
 *         {migrate}, so an open door costs nothing and a donation is exactly
 *         what it looks like, which is more $BRAH burned.
 *
 *         Trust model: not upgradeable. Router, token, hook and tick spacing
 *         are fixed at deploy. The only outputs are the swap, whose recipient
 *         is this contract, the burn, and {migrate}, which can only reach
 *         another burn sink on the same token. The owner tunes the pool fee
 *         tier and who may crank, never where funds go.
 *
 *         On the hook: it is set once in the constructor, by whoever deploys,
 *         auditable before it is set, exactly like `router` and `brah`, and
 *         there is no setter. The rule that matters is intact, which is that
 *         the rake never routes through code an owner chose after deploy.
 *         What the hook cannot be is hardcoded to zero, because on V4 the
 *         hook is part of pool identity. A pool created with a hook attached
 *         is not the pool a zero hook names, and the symptom of getting it
 *         wrong is every crank reverting forever with the ETH piling up
 *         behind it. Setting it at construction also lets one bytecode serve
 *         a hookless pool and a hooked one, with the difference stated once
 *         where it can be read.
 */
contract BuyAndBurn is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    ERC20Burnable public immutable brah;
    address public immutable router;

    /// @notice The V4 hook on the $BRAH pool, or address(0) for a pool with
    ///         none. Part of the pool's identity alongside {poolFee} and
    ///         {tickSpacing}, and immutable for the same reason: a different
    ///         hook is a different pool, so moving it is a redeploy.
    address public immutable hook;

    /**
     * @dev Tick spacing of the native ETH / $BRAH pool.
     *
     *      Immutable on purpose, unlike {poolFee}. Fee and spacing are both
     *      part of pool identity, so either one moving names a different
     *      pool. The owner's dial is exactly one number, the fee tier. A burn
     *      sink that needs different spacing is a redeploy and a {migrate},
     *      which is the blast radius this contract is built around.
     */
    int24 public immutable tickSpacing;

    /// @dev Fee tier of the pool. Part of the pool key, where a wrong value
    ///      names a pool that does not exist and every crank simply reverts.
    uint24 public poolFee;

    /// @dev A static LP fee caps at 100%, in hundredths of a bip.
    uint24 private constant V4_MAX_LP_FEE = 1_000_000;

    /// @dev The router command meaning "hand this payload to the V4 router".
    uint8 private constant CMD_V4_SWAP = 0x10;

    /**
     * @dev V4 router actions, one byte each.
     *
     *      These come from the swap router's table, not the position
     *      manager's, and the difference has already cost one live debugging
     *      session. The two dispatchers number different action sets, the
     *      swap router implements only the swap, settle and take family, and
     *      it reverts with `UnsupportedAction(uint256)` on a byte that is
     *      perfectly valid for the other one.
     */
    uint8 private constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant ACT_SETTLE_ALL = 0x0c;
    uint8 private constant ACT_TAKE_ALL = 0x0f;

    /// @dev How a pool key spells the chain's own currency.
    address private constant NATIVE = address(0);

    event PoolFeeSet(uint24 fee);
    /// @dev The whole ETH balance left for a replacement burn sink.
    event Migrated(address indexed destination, uint256 ethMoved);
    event Cranked(uint256 ethIn, uint256 brahBurned);
    /// @dev $BRAH sent here directly, burned without a swap.
    event BurnedHeld(uint256 brahBurned);

    constructor(
        address _brah,
        address _router,
        uint24 _poolFee,
        int24 _tickSpacing,
        address _hook,
        address _admin
    ) {
        require(_brah != address(0), "brah=0");
        require(_router != address(0), "router=0");
        require(_admin != address(0), "admin=0");
        // Both halves of the pool's identity have to be real at deploy. A
        // zero spacing or an impossible fee names a pool nobody created, and
        // the symptom is every crank reverting forever with the ETH piling
        // up behind it.
        require(_tickSpacing > 0, "tickSpacing=0");
        require(_poolFee <= V4_MAX_LP_FEE, "poolFee");
        brah = ERC20Burnable(_brah);
        router = _router;
        // Not zero-checked, deliberately: address(0) is the right value for a
        // pool created without a hook.
        hook = _hook;
        poolFee = _poolFee;
        tickSpacing = _tickSpacing;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * @notice Re-point the fee tier of the pool the burn trades against.
     * @dev This is half the pool's identity, not a parameter of the trade. A
     *      fee no pool was created at is not a worse price, it is a pool that
     *      does not exist and a crank that reverts. Bounded to what the core
     *      will accept, so the mistake at least cannot be encoded.
     */
    function setPoolFee(uint24 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_fee <= V4_MAX_LP_FEE, "poolFee");
        poolFee = _fee;
        emit PoolFeeSet(_fee);
    }

    /**
     * @notice The pool this contract burns against, its whole identity in one
     *         read.
     * @dev Public because "which pool does the rake burn into" is a question
     *      anyone funding the rake is entitled to answer without decoding
     *      calldata, and because the keeper's off-chain quote and this
     *      contract's on-chain swap have to be talking about the same pool.
     *
     *      currency0 is native, so the direction is always zeroForOne. The
     *      zero address sorts below the token's, by construction rather than
     *      by convention.
     */
    function v4PoolKey() public view returns (V4PoolKey memory) {
        return
            V4PoolKey({
                currency0: NATIVE,
                currency1: address(brah),
                fee: poolFee,
                tickSpacing: tickSpacing,
                hooks: hook
            });
    }

    /// @notice Accept ETH from anyone. Every wei that lands here is burn
    ///         fuel: spendable by the next {crank}, movable by {migrate}, and
    ///         nothing else.
    receive() external payable {}

    /**
     * @notice Swap `amountIn` of held ETH into $BRAH and burn all of it.
     * @param amountIn ETH to spend; 0 spends the whole balance.
     * @param minOut   Slippage floor, required non-zero. The keeper computes
     *                 it off chain, so a sandwich can only fail the crank,
     *                 never shave the burn.
     *
     * @dev What was burned is measured, not reported. `got` is the change in
     *      this contract's own $BRAH balance across the swap, because
     *      `execute` returns nothing at all and the delta is the only figure
     *      there is. Measuring also means the crank enforces `minOut` itself
     *      rather than trusting the router to have done it, so the keeper's
     *      guard holds even against the router, which is the one party in
     *      this transaction the contract cannot choose after deploy.
     *
     *      A delta and not a balance, so $BRAH already sitting here is left
     *      for {burnHeld} instead of being folded into a burn the keeper
     *      quoted a floor for.
     */
    function crank(
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) external onlyRole(KEEPER_ROLE) {
        if (amountIn == 0) amountIn = address(this).balance;
        require(amountIn > 0, "nothing to burn");
        require(minOut > 0, "minOut=0");
        // V4 carries amounts as uint128. A silent downcast here would swap a
        // wrapped-around amount, or worse, a wrapped-around floor, which is
        // the keeper's sandwich guard quietly set to nearly zero.
        require(amountIn <= type(uint128).max, "amountIn>u128");
        require(minOut <= type(uint128).max, "minOut>u128");

        uint256 held = brah.balanceOf(address(this));

        /**
         * The shape of the call, and why each byte is what it is:
         *
         *   commands = [V4_SWAP]           one top-level command
         *   actions  = [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]
         *
         * Flash accounting means the three actions close one set of deltas.
         * The swap opens a debt in ETH and a credit in $BRAH, SETTLE_ALL pays
         * the debt out of the value sent with `execute`, and TAKE_ALL
         * collects the credit to the sender, which for a router call is this
         * contract. There is no recipient field to get wrong, and no moment
         * at which the bought $BRAH belongs to anyone else.
         *
         * No sweep command, deliberately. Exact input means the input is
         * exact: the value sent, the swap's `amountIn` and SETTLE_ALL's
         * ceiling are one number, so there is nothing left in the router to
         * sweep. An exact-output buy would need one, and it would be a router
         * command rather than a V4 action. Named here so the trap is not
         * re-set by whoever adds an exact-out path.
         *
         * minOut goes into both the swap's `amountOutMinimum` and TAKE_ALL's
         * floor, because different code in the router checks each and neither
         * substitutes for the other. The crank then checks the delta a third
         * time on its own balance, which is the only one of the three that
         * does not depend on the router being honest. Any router change lands
         * back through {receive} and waits for the next crank.
         */
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            V4ExactInputSingleParams({
                poolKey: v4PoolKey(),
                zeroForOne: true, // native is currency0; buying $BRAH is 0 to 1
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                hookData: ""
            })
        );
        params[1] = abi.encode(NATIVE, amountIn); // SETTLE_ALL: pay at most this
        params[2] = abi.encode(address(brah), minOut); // TAKE_ALL: take at least this

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(
                ACT_SWAP_EXACT_IN_SINGLE,
                ACT_SETTLE_ALL,
                ACT_TAKE_ALL
            ),
            params
        );

        IUniversalRouter(router).execute{value: amountIn}(
            abi.encodePacked(CMD_V4_SWAP),
            inputs,
            deadline
        );

        uint256 got = brah.balanceOf(address(this)) - held;
        require(got >= minOut, "minOut");

        brah.burn(got);
        emit Cranked(amountIn, got);
    }

    /**
     * @notice Move the accumulated ETH to a replacement burn sink.
     * @dev The exit this contract would otherwise not have. `router` is
     *      immutable and the keeper skips the crank when it cannot quote
     *      honestly, so a dead router, or a pool that never materialises,
     *      would leave the burn leg's ETH here with no way out.
     *
     *      Deliberately not a withdraw. `destination` must be a contract that
     *      answers the same {brah} as this one, so migrated funds can only
     *      land somewhere that buys and burns the same token. An admin can
     *      replace the plumbing, never redirect the burn into a wallet. The
     *      check bounds the mistake, not a determined admin: the admin role
     *      belongs on the multisig, and that is this leg's trust anchor.
     */
    function migrate(
        address destination
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(destination != address(0), "dest=0");
        require(destination != address(this), "dest=self");
        require(destination.code.length > 0, "dest not contract");
        require(IBurnSink(destination).brah() == address(brah), "dest brah");

        uint256 bal = address(this).balance;
        require(bal > 0, "nothing");
        (bool ok, ) = destination.call{value: bal}("");
        require(ok, "dest refused");
        emit Migrated(destination, bal);
    }

    /// @notice Burn any $BRAH sitting here, no swap needed. Permissionless,
    ///         because burning more $BRAH needs no privilege.
    function burnHeld() external {
        uint256 bal = brah.balanceOf(address(this));
        require(bal > 0, "nothing");
        brah.burn(bal);
        emit BurnedHeld(bal);
    }
}
