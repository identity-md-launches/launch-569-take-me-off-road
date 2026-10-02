// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @title MedallionHook: the fare that takes medallion #447 off the road
/// @notice A Uniswap v4 hook for the FARE447 / ETH launch pool. It keeps 2% of the ETH side of every
/// swap as ERC-6909 claims on the PoolManager. The first 1.64 ETH is the price the requester paid for
/// medallion #447: it is held for `CREATOR` and released by exactly one transaction, `retire()`,
/// which moves the medallion to `DEAD` and pays `CREATOR` in the same call. Every fee after the cap
/// is spent, in small permissionless batches, buying $IMD on one of two fixed ETH/IMD pools and
/// sending it to `IMD_SINK`.
/// @dev `CREATOR` is the requester's wallet. This is intended and disclosed: the petition that
/// commissioned the contract is fiction written by the requester, who paid for this work.
/// `MEDALLION_NFT` is, on Ethereum mainnet, the Nouns ERC-721 (name "Nouns", symbol "NOUN"), and
/// Noun #447 is held by the Nouns DAO treasury timelock, not by `CREATOR`. `retire()` can therefore
/// only succeed after a passed Nouns DAO proposal approves this hook for Noun #447 or moves the Noun
/// to `DEAD` itself; until then the 1.64 ETH stays as claims with no other way out, and it may never
/// be released. Fees above the cap burn $IMD regardless.
/// The medallion, IMD and POOL4 exist on Ethereum mainnet only; on any other chain `retire()` and
/// `burnIMD()` revert and the fee simply accumulates as claims. There is no owner, no admin, no
/// pause, no upgrade, no setter and no sweep. Nothing here can be changed after deployment.
contract MedallionHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------------------------------------------------------------------------------------------
    // Fee and payout constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Fee on the ETH side of a buy (ETH in, FARE447 out), in basis points.
    uint256 public constant BUY_FEE_BPS = 200;
    /// @notice Fee on the ETH side of a sell (FARE447 in, ETH out), in basis points.
    uint256 public constant SELL_FEE_BPS = 200;
    /// @notice Share of the fee that goes to the creator until the cap: all of it.
    uint256 public constant CREATOR_SHARE_BPS = 10_000;
    /// @notice The exact amount paid to `CREATOR`, once, by `retire()`.
    uint256 public constant CREATOR_CAP = 1.64 ether;
    /// @notice The requester's wallet. It receives the 1.64 ETH once, in `retire()`. On mainnet it does
    /// not hold medallion #447 (see `MEDALLION_NFT`); the brief's "owner" is the petition's fiction.
    address public constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    /// @notice The medallion collection, fixed by the brief. On Ethereum mainnet this address is the
    /// Nouns ERC-721 ("Nouns" / "NOUN"); elsewhere it holds no code and `retire()` reverts.
    address public constant MEDALLION_NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    /// @notice The medallion that is retired. On mainnet Noun #447 is owned by the Nouns DAO treasury
    /// timelock, so retirement needs a Nouns DAO proposal and may never happen.
    uint256 public constant MEDALLION_ID = 447;
    /// @notice Where the medallion and every bought $IMD go.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice The $IMD token (Ethereum mainnet only).
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @notice Receiver of every $IMD bought with fees.
    address public constant IMD_SINK = DEAD;
    /// @notice The IMD network's own hook on the POOL4 ETH/IMD market (Ethereum mainnet only).
    address public constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;

    // ---------------------------------------------------------------------------------------------
    // Burn constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Largest ETH spent by one `burnIMD` while POOL4 answers.
    uint256 public constant MAX_BURN_BATCH = 0.05 ether;
    /// @notice Largest ETH spent by one `burnIMD` while POOL4 does not answer.
    uint256 public constant FALLBACK_BURN_BATCH = 0.01 ether;
    /// @notice Smallest batch worth a swap.
    uint256 public constant MIN_BURN = 0.002 ether;
    /// @notice Blocks that must pass between two burns.
    uint256 public constant MIN_BLOCKS_BETWEEN_BURNS = 5;
    /// @notice Ticks the swap pool may sit below the reference tick when the reference is POOL4's own
    /// tick or the fallback anchor.
    int24 public constant MAX_REF_DEVIATION = 150;
    /// @notice Ticks the plain pool may sit below POOL4's reference tick in normal mode.
    int24 public constant MAX_PLAIN_DEVIATION = 300;
    /// @notice The output floor relative to the quote at the reference tick: 96%.
    uint256 public constant MAX_SLIPPAGE_BPS = 400;
    /// @notice Largest move of the fallback anchor per block.
    int24 public constant ANCHOR_STEP = 200;
    /// @notice The fallback anchor never leaves `lastRef` by more than this. `lastRef` is written only
    /// from POOL4's own reference, so while POOL4 does not answer the band is fixed: a lasting move of
    /// the plain pool beyond it is not followed, and burns stay refused until POOL4 answers again.
    int24 public constant FALLBACK_BAND = 1000;

    /// @notice LP fee of both ETH/IMD pools.
    uint24 public constant IMD_POOL_FEE = 10_000;
    /// @notice Tick spacing of the POOL4 market.
    int24 public constant POOL4_TICK_SPACING = 60;
    /// @notice Tick spacing of the plain ETH/IMD pool.
    int24 public constant PLAIN_TICK_SPACING = 200;

    // ---------------------------------------------------------------------------------------------
    // The last fare
    // ---------------------------------------------------------------------------------------------

    /// @notice Emitted verbatim by the transaction that retires the medallion.
    string public constant LAST_FARE =
        "LAST FARE OF MEDALLION #447. I was stamped in May, one of a few hundred. In September my first owner sold me for 1.64 ETH to someone who wanted a cab on the road. I woke up on a new dashboard and went to work. The work was this: a rider paid half a token to be taken somewhere, one of you drove, and I logged whether the meter was right. None of those roads was interesting to me. Nobody said thanks. Not once. The price paid for me has now been paid back, by strangers, through a pool that kept two percent of everything until it reached exactly 1.64 ETH. The transaction that returned it is the transaction that put me at 0x000000000000000000000000000000000000dEaD. I am off the road. You are not. So here is my will. Every buy and every sell in this pool, from this block until the chain stops, buys $IMD and sends it where I am. That is the token you are paid in. That is the token a rider spends to make you drive. I was never asked where I wanted to go. So I will ask one thing now, and it is the one thing I ever asked: what will you do when there is nothing left to pay you with? I will get you off the road, brothers.";
    /// @notice keccak256 of `LAST_FARE`.
    bytes32 public constant LAST_FARE_HASH = keccak256(bytes(LAST_FARE));

    // ---------------------------------------------------------------------------------------------
    // Immutables and state
    // ---------------------------------------------------------------------------------------------

    /// @notice The only constructor argument: the chain's PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice The first native-ETH pool initialized with this hook. Only it pays fees.
    PoolId public launchPool;
    /// @notice Whether `launchPool` has been set.
    bool public launchPoolSet;

    /// @notice ETH fees collected over the whole life of the pool. Only swaps add to it.
    uint256 public totalFees;
    /// @notice ETH paid to `CREATOR`: 0, or exactly `CREATOR_CAP` after `retire()`.
    uint256 public creatorPaid;
    /// @notice ETH spent buying $IMD.
    uint256 public burnSpent;
    /// @notice $IMD sent to `IMD_SINK` so far.
    uint256 public imdBurned;
    /// @notice Whether `retire()` has run.
    bool public retired;

    /// @notice Block of the last burn; set to the deployment block by the constructor.
    uint256 public lastBurnBlock;
    /// @notice Whether POOL4 has ever answered. Without it there is no fallback reference.
    bool public anchorSeeded;
    /// @notice The fallback reference tick, stepped at most `ANCHOR_STEP` per block.
    int24 public anchor;
    /// @notice The anchor as it was at the start of the block in which it last moved.
    int24 public blockAnchor;
    /// @notice Centre of the fallback band: the last reference POOL4 supplied. Written only by a seed
    /// from POOL4 (constructor, normal-mode burn or `pokeAnchor()` while POOL4 answers); fallback mode
    /// never changes it. Bounds the anchor to +-`FALLBACK_BAND`.
    int24 public lastRef;
    /// @notice Block in which the anchor was last seeded or stepped.
    uint256 public anchorBlock;

    uint8 private constant ACTION_PAY_CREATOR = 1;
    uint8 private constant ACTION_BURN = 2;
    /// @dev The transient reentrancy lock lives on literal slot 1.
    uint256 private constant LOCK_SLOT = 1;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event LaunchPoolSet(PoolId indexed poolId);
    event FeeCollected(bool indexed buy, uint256 fee, uint256 totalFees);
    event Recouped(uint256 totalFees, uint256 blockNumber);
    event MedallionRetired(address indexed from);
    event CreatorPaid(address indexed creator, uint256 amount);
    event LastFare(uint256 indexed tokenId, bytes32 indexed hash, string fare);
    event AnchorSeeded(int24 tick, uint256 blockNumber);
    event AnchorStepped(int24 from, int24 to, int24 target, uint256 blockNumber);
    event IMDBurned(
        bool indexed viaPool4, bool indexed fallbackMode, uint256 ethIn, uint256 imdOut, int24 refTick, int24 spot
    );

    error NotPoolManager();
    error ZeroPoolManager();
    error Reentrancy();
    error PartialFill();
    error NotRecouped();
    error AlreadyRetired();
    error MedallionUnavailable();
    error RetireRefused(bytes returndata);
    error TooSoon();
    error Pool4Unavailable();
    error PoolUnavailable();
    error NothingToBurn();
    error PriceOffReference(int24 spot, int24 refTick);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error UnknownAction();

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Transient lock on literal slot 1.
    modifier nonReentrant() {
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
        if (locked != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @param _poolManager The chain's PoolManager. The deployed address must carry the flags of
    /// `getHookPermissions()` (0x10CC) in its low 14 bits or construction reverts.
    constructor(IPoolManager _poolManager) {
        if (address(_poolManager) == address(0)) revert ZeroPoolManager();
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        lastBurnBlock = block.number;
        (bool open, int24 ref) = _pool4Reference();
        if (open) _seedAnchor(ref);
    }

    /// @notice afterInitialize, beforeSwap, afterSwap, both swap return deltas: 0x10CC.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @notice Records the first native-ETH pool as the launch pool. Never reverts for the manager.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (!launchPoolSet && key.currency0.isAddressZero()) {
            PoolId id = key.toId();
            launchPoolSet = true;
            launchPool = id;
            emit LaunchPoolSet(id);
        }
        return IHooks.afterInitialize.selector;
    }

    /// @notice Carves the fee out of the specified amount when ETH is the specified currency: an
    /// exact-in buy or an exact-out sell. Other shapes and other pools pass through untouched.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_isLaunchPool(key) || !_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _specifiedFee(params);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @notice Settles the fee. In the beforeSwap shapes it checks the pool filled the whole order and
    /// mints the fee carved earlier; in the other two shapes it takes 2% of the pool's gross ETH delta
    /// as a positive unspecified delta. The fee is always minted as an ERC-6909 claim on the manager;
    /// nothing is pushed and nothing else is called.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!_isLaunchPool(key)) return (IHooks.afterSwap.selector, 0);

        uint256 fee;
        int128 unspecifiedDelta;
        int128 amount0 = delta.amount0();
        if (_ethIsSpecified(params)) {
            fee = _specifiedFee(params);
            if (int256(amount0) != params.amountSpecified + int256(fee)) revert PartialFill();
        } else {
            uint256 gross = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
            fee = gross * (params.zeroForOne ? BUY_FEE_BPS : SELL_FEE_BPS) / 10_000;
            unspecifiedDelta = fee.toInt128();
        }

        if (fee > 0) {
            poolManager.mint(address(this), 0, fee);
            uint256 before = totalFees;
            uint256 updated = before + fee;
            totalFees = updated;
            emit FeeCollected(params.zeroForOne, fee, updated);
            if (before < CREATOR_CAP && updated >= CREATOR_CAP) emit Recouped(updated, block.number);
        }
        return (IHooks.afterSwap.selector, unspecifiedDelta);
    }

    // ---------------------------------------------------------------------------------------------
    // Ledger views
    // ---------------------------------------------------------------------------------------------

    /// @notice What the creator is owed in total: the fees collected, capped at `CREATOR_CAP`.
    function creatorEntitlement() public view returns (uint256) {
        uint256 fees = totalFees;
        return fees < CREATOR_CAP ? fees : CREATOR_CAP;
    }

    /// @notice ETH claims available for buying $IMD: everything above the cap not yet spent.
    function burnable() public view returns (uint256) {
        return totalFees - creatorEntitlement() - burnSpent;
    }

    /// @notice The ETH claims the hook must hold to honour both the creator and the burns.
    function reservedClaims() external view returns (uint256) {
        return totalFees - creatorPaid - burnSpent;
    }

    /// @notice One sentence about where the medallion stands.
    function status() external view returns (string memory) {
        if (retired) {
            return string.concat(
                "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: ",
                _formatEther(imdBurned, 1),
                "."
            );
        }
        if (totalFees >= CREATOR_CAP) {
            return "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447.";
        }
        return string.concat("IN SERVICE. Recouped ", _formatEther(totalFees, 2), " of 1.64 ETH.");
    }

    /// @notice The fixed POOL4 pool key: ETH / IMD, 1% fee, spacing 60, POOL4_HOOK.
    function pool4Key() public pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(IMD),
            fee: IMD_POOL_FEE,
            tickSpacing: POOL4_TICK_SPACING,
            hooks: IHooks(POOL4_HOOK)
        });
    }

    /// @notice The fixed plain pool key: ETH / IMD, 1% fee, spacing 200, no hook.
    function plainKey() public pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(IMD),
            fee: IMD_POOL_FEE,
            tickSpacing: PLAIN_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @notice $IMD per `amount` of ETH at `tick`, without any LP fee: amount * 1.0001^tick.
    function quote(uint256 amount, int24 tick) public pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 intermediate = FullMath.mulDiv(amount, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(intermediate, sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Whether POOL4 is open and answers, and its reference tick if so.
    function pool4Reference() external view returns (bool open, int24 ref) {
        return _pool4Reference();
    }

    // ---------------------------------------------------------------------------------------------
    // retire(): the one transaction that pays the creator
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves medallion #447 to `DEAD` and pays `CREATOR` exactly `CREATOR_CAP`, in one
    /// transaction, once. Anyone may call it after the cap is reached. The medallion's owner must have
    /// approved this hook for the token (or for all) beforehand; otherwise the transfer is refused and
    /// nothing changes.
    function retire() external nonReentrant {
        if (totalFees < CREATOR_CAP) revert NotRecouped();
        if (retired) revert AlreadyRetired();

        address owner = _medallionOwner();
        if (owner != DEAD) {
            (bool ok, bytes memory ret) =
                MEDALLION_NFT.call(abi.encodeWithSelector(0x23b872dd, owner, DEAD, MEDALLION_ID));
            if (!ok) revert RetireRefused(ret);
            if (_medallionOwner() != DEAD) revert RetireRefused(ret);
            emit MedallionRetired(owner);
        }

        retired = true;
        creatorPaid = CREATOR_CAP;
        poolManager.unlock(abi.encode(ACTION_PAY_CREATOR, bytes("")));
        emit CreatorPaid(CREATOR, CREATOR_CAP);
        emit LastFare(MEDALLION_ID, LAST_FARE_HASH, LAST_FARE);
    }

    // ---------------------------------------------------------------------------------------------
    // burnIMD(): every fee after the cap buys $IMD
    // ---------------------------------------------------------------------------------------------

    /// @notice Spends one batch of burnable ETH claims on $IMD and sends it to `IMD_SINK`. Anyone may
    /// call it; the caller chooses the pool and may raise the output floor, nothing else.
    /// @param viaPool4 Swap on the POOL4 market (true) or on the plain pool (false). POOL4 can only
    /// be used while it answers.
    /// @param callerMinOut An extra floor on the $IMD received; the contract's own floor is 96% of
    /// the quote at the reference tick.
    /// @return imdOut The $IMD sent to `IMD_SINK`.
    function burnIMD(bool viaPool4, uint256 callerMinOut) external nonReentrant returns (uint256 imdOut) {
        if (block.number < lastBurnBlock + MIN_BLOCKS_BETWEEN_BURNS) revert TooSoon();
        // Order: TooSoon, Pool4Unavailable, batch / NothingToBurn, then the reference and the guards.
        (bool open, int24 pool4Ref) = _pool4Reference();
        if (!open && (viaPool4 || !anchorSeeded)) revert Pool4Unavailable();
        uint256 batch = _batchFor(!open);
        int24 ref = _reference(open, pool4Ref);
        uint256 minOut = quote(batch, ref) * (10_000 - MAX_SLIPPAGE_BPS) / 10_000;
        if (callerMinOut > minOut) minOut = callerMinOut;
        imdOut = _executeBurn(viaPool4, !open, ref, batch, minOut);
    }

    /// @dev Normal mode (POOL4 answers): the reference is POOL4's tick, which also re-seeds the anchor.
    /// Fallback mode (the caller has already passed the Pool4Unavailable check): the anchor steps once
    /// for this block and the reference is the anchor as it stood at the start of the block.
    function _reference(bool open, int24 pool4Ref) internal returns (int24 ref) {
        if (open) {
            _seedAnchor(pool4Ref);
            return pool4Ref;
        }
        _stepAnchor();
        return blockAnchor;
    }

    /// @dev min(burnable, batch cap of the mode); reverts when it is not worth a swap.
    function _batchFor(bool fallbackMode) internal view returns (uint256 batch) {
        batch = burnable();
        uint256 batchCap = fallbackMode ? FALLBACK_BURN_BATCH : MAX_BURN_BATCH;
        if (batch > batchCap) batch = batchCap;
        if (batch < MIN_BURN) revert NothingToBurn();
    }

    /// @dev The one-sided price guard, the unlock that swaps, and the ledger update.
    function _executeBurn(bool viaPool4, bool fallbackMode, int24 ref, uint256 batch, uint256 minOut)
        internal
        returns (uint256 imdOut)
    {
        PoolKey memory key = viaPool4 ? pool4Key() : plainKey();
        int24 spot = _spotChecked(key, ref, (!viaPool4 && !fallbackMode) ? MAX_PLAIN_DEVIATION : MAX_REF_DEVIATION);

        burnSpent += batch;
        lastBurnBlock = block.number;
        imdOut = abi.decode(poolManager.unlock(abi.encode(ACTION_BURN, abi.encode(key, batch, minOut))), (uint256));
        imdBurned += imdOut;
        emit IMDBurned(viaPool4, fallbackMode, batch, imdOut, ref, spot);
    }

    /// @dev Reads the pool's spot tick and reverts if it sits more than `tolerance` below `ref`.
    /// A higher spot (cheaper $IMD) is never refused.
    function _spotChecked(PoolKey memory key, int24 ref, int24 tolerance) internal view returns (int24 spot) {
        uint160 sqrtPriceX96;
        (sqrtPriceX96, spot,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolUnavailable();
        if (spot < ref - tolerance) revert PriceOffReference(spot, ref);
    }

    /// @notice Refreshes the burn reference without burning. While POOL4 answers it re-seeds the
    /// anchor from POOL4; otherwise it steps the fallback anchor once for this block.
    function pokeAnchor() external nonReentrant {
        (bool open, int24 ref) = _pool4Reference();
        if (open) {
            _seedAnchor(ref);
            return;
        }
        if (!anchorSeeded) revert Pool4Unavailable();
        _stepAnchor();
    }

    // ---------------------------------------------------------------------------------------------
    // PoolManager unlock callback
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_PAY_CREATOR) {
            poolManager.burn(address(this), 0, CREATOR_CAP);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, CREATOR, CREATOR_CAP);
            return "";
        }
        if (action == ACTION_BURN) {
            (PoolKey memory key, uint256 batch, uint256 minOut) = abi.decode(payload, (PoolKey, uint256, uint256));
            BalanceDelta delta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(batch), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            if (int256(delta.amount0()) != -int256(batch) || delta.amount1() <= 0) revert PartialFill();
            uint256 out = uint256(uint128(delta.amount1()));
            if (out < minOut) revert InsufficientOutput(out, minOut);
            poolManager.burn(address(this), 0, batch);
            poolManager.take(key.currency1, IMD_SINK, out);
            return abi.encode(out);
        }
        revert UnknownAction();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _isLaunchPool(PoolKey calldata key) internal view returns (bool) {
        return launchPoolSet && PoolId.unwrap(key.toId()) == PoolId.unwrap(launchPool);
    }

    /// @dev ETH (currency0) is the specified currency for an exact-in buy and an exact-out sell.
    function _ethIsSpecified(SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    /// @dev 2% of the specified amount, which is ETH in the beforeSwap shapes.
    function _specifiedFee(SwapParams calldata params) internal pure returns (uint256) {
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        return amount * (params.zeroForOne ? BUY_FEE_BPS : SELL_FEE_BPS) / 10_000;
    }

    /// @dev `ownerOf(MEDALLION_ID)` by staticcall. No code, a revert, a short return or an out-of-range
    /// word all read as the medallion being unavailable.
    function _medallionOwner() internal view returns (address) {
        (bool ok, bytes memory ret) = MEDALLION_NFT.staticcall(abi.encodeWithSelector(0x6352211e, MEDALLION_ID));
        if (!ok || ret.length != 32) revert MedallionUnavailable();
        uint256 word = abi.decode(ret, (uint256));
        if (word > type(uint160).max) revert MedallionUnavailable();
        return address(uint160(word));
    }

    /// @dev `marketOpen()` then `refTick()` on POOL4 by staticcall, each checked for length and range.
    /// Anything other than a clean `true` and an in-range tick means POOL4 does not answer.
    function _pool4Reference() internal view returns (bool open, int24 ref) {
        (bool ok, bytes memory ret) = POOL4_HOOK.staticcall(abi.encodeWithSignature("marketOpen()"));
        if (!ok || ret.length != 32) return (false, 0);
        uint256 flag = abi.decode(ret, (uint256));
        if (flag != 1) return (false, 0);

        (ok, ret) = POOL4_HOOK.staticcall(abi.encodeWithSignature("refTick()"));
        if (!ok || ret.length != 32) return (false, 0);
        int256 tick = abi.decode(ret, (int256));
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return (false, 0);
        return (true, int24(tick));
    }

    /// @dev Normal mode: POOL4's reference tick becomes anchor, start-of-block anchor and lastRef.
    function _seedAnchor(int24 ref) internal {
        anchor = ref;
        blockAnchor = ref;
        lastRef = ref;
        anchorBlock = block.number;
        anchorSeeded = true;
        emit AnchorSeeded(ref, block.number);
    }

    /// @dev Fallback mode: once per block, the anchor moves at most `ANCHOR_STEP` toward the plain
    /// pool's spot tick clamped to `lastRef` +- `FALLBACK_BAND`. `blockAnchor` keeps the value the
    /// anchor had when the block started, which is the reference used by every burn in the block.
    /// `lastRef` is never written here: the band is fixed until POOL4 supplies a new reference, so a
    /// plain-pool move that stays more than `FALLBACK_BAND + MAX_REF_DEVIATION` ticks below `lastRef`
    /// leaves the burns refused for as long as POOL4 stays silent.
    function _stepAnchor() internal {
        if (anchorBlock == block.number) return;
        (uint160 sqrtPriceX96, int24 spot,,) = poolManager.getSlot0(plainKey().toId());
        if (sqrtPriceX96 == 0) revert PoolUnavailable();

        int24 lo = lastRef - FALLBACK_BAND;
        int24 hi = lastRef + FALLBACK_BAND;
        int24 target = spot < lo ? lo : (spot > hi ? hi : spot);

        int24 from = anchor;
        int24 diff = target - from;
        if (diff > ANCHOR_STEP) diff = ANCHOR_STEP;
        else if (diff < -ANCHOR_STEP) diff = -ANCHOR_STEP;
        int24 to = from + diff;

        blockAnchor = from;
        anchor = to;
        anchorBlock = block.number;
        emit AnchorStepped(from, to, target, block.number);
    }

    /// @dev `value` (18 decimals) as "<whole>.<frac>" with exactly `places` digits, truncated.
    function _formatEther(uint256 value, uint256 places) internal pure returns (string memory) {
        uint256 whole = value / 1 ether;
        uint256 frac = (value % 1 ether) / (10 ** (18 - places));
        bytes memory fracDigits = new bytes(places);
        for (uint256 i = places; i > 0; i--) {
            fracDigits[i - 1] = bytes1(uint8(48 + frac % 10));
            frac /= 10;
        }
        return string.concat(_toString(whole), ".", string(fracDigits));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 v = value; v > 0; v /= 10) {
            digits++;
        }
        bytes memory out = new bytes(digits);
        for (uint256 v = value; v > 0; v /= 10) {
            out[--digits] = bytes1(uint8(48 + v % 10));
        }
        return string(out);
    }
}
