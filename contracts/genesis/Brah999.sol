// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../interfaces/IERC6551Registry.sol";
import "./IGenesis.sol";

/**
 * @title Brah999
 * @notice 999 brahs, capped forever. The cap holds because this contract is
 *         not upgradeable: no proxy, no admin who can raise MAX_SUPPLY, and
 *         one mint path that the owner freezes with {lockWiring} once it has
 *         been proven, after which it cannot be re-pointed.
 *
 *         The pyramid is carved into the id space, ancients first:
 *           ancients  1..9    coral-born, true names, 1/1 art
 *           elders   10..99   their own trait pool
 *           commons 100..999  born bare
 *         Class is a pure function of the id. No storage write can move a
 *         brah between classes, ever.
 *
 *         Names and traits live in metadata: committed by {provenanceHash}
 *         before mint, frozen by {freezeMetadata} after the reveal.
 *
 *         Every brah gets a token-bound account at mint, recorded in both
 *         directions. The reverse map is how the escrow checks in one call
 *         that a staker is not a brah wallet.
 *
 *         On every transfer, never a mint, the rock module is told and it
 *         clears the brah's rock. Ancients are exempt, and that exemption
 *         lives in the module. The hook is a direct call rather than a
 *         try/catch: a swallowed reset would let a rock ride through a sale,
 *         which is worse than a revert. The module is not upgradeable, is
 *         frozen before launch, and only writes storage, so it cannot brick
 *         a transfer.
 *
 *         Royalties are asymmetric on purpose: 2.5% on outside marketplaces,
 *         nothing at all in the tide pool.
 */
contract Brah999 is ERC721, ERC2981, Ownable, IBrah999 {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 999;
    uint256 public constant ANCIENTS_END = 9; // ids 1..9, the nine true names
    uint256 public constant ELDERS_END = 99; // ids 10..99
    // ids 100..999 are the 900 commons.

    /// @dev Token-bound account wiring, fixed at deploy.
    IERC6551Registry public immutable tbaRegistry;
    address public immutable tbaImplementation;
    uint256 public immutable tbaSalt;

    /// @dev The only address allowed to mint. Settable until {lockWiring}.
    address public minter;

    /// @dev Told on every transfer. Settable until {lockWiring}.
    IRockModule public rockModule;

    /// @dev Once true, {setMinter} and {setRockModule} are closed for good.
    bool public wiringLocked;

    /// @dev id -> token-bound account, and back the other way.
    mapping(uint256 => address) private _tbaOf;
    mapping(address => uint256) private _tbaToBrahId;

    uint256 public totalMinted;

    /// @dev Commitment to the full 999 metadata set, published before mint
    ///      so the art and name assignment is provably fixed while the wilds
    ///      are still asleep in the kelp.
    bytes32 public provenanceHash;

    string private _baseTokenURI;
    string private _contractURI;
    bool public metadataFrozen;

    event MinterSet(address minter);
    event RockModuleSet(address rockModule);
    event WiringLocked();
    event ProvenanceCommitted(bytes32 hash);
    event BaseURISet(string baseURI);
    event ContractURISet(string uri);
    event MetadataFrozen();
    event BrahBorn(uint256 indexed brahId, address indexed to, address tba);

    constructor(
        address _tbaRegistry,
        address _tbaImplementation,
        uint256 _tbaSalt,
        address _royaltyReceiver,
        address _owner
    ) ERC721("brahhood: the 999", "BRAH999") Ownable(_owner) {
        require(_tbaRegistry != address(0), "registry=0");
        require(_tbaImplementation != address(0), "tbaImpl=0");
        require(_royaltyReceiver != address(0), "royalty=0");
        tbaRegistry = IERC6551Registry(_tbaRegistry);
        tbaImplementation = _tbaImplementation;
        tbaSalt = _tbaSalt;
        // 2.5% outside. Nothing at home is the tide pool's behaviour, not a
        // royalty entry.
        _setDefaultRoyalty(_royaltyReceiver, 250);
    }

    // --------------------------------------------------------------------- //
    // Wiring, settable until locked
    // --------------------------------------------------------------------- //

    /// @notice Set the minter. Re-pointable only until {lockWiring}.
    function setMinter(address _minter) external onlyOwner {
        require(!wiringLocked, "wiring locked");
        require(_minter != address(0), "minter=0");
        minter = _minter;
        emit MinterSet(_minter);
    }

    /// @notice Set the rock module. Re-pointable only until {lockWiring}.
    ///         The reset hook is economics, not a tunable.
    function setRockModule(address _rockModule) external onlyOwner {
        require(!wiringLocked, "wiring locked");
        require(_rockModule != address(0), "module=0");
        rockModule = IRockModule(_rockModule);
        emit RockModuleSet(_rockModule);
    }

    /**
     * @notice Freeze {setMinter} and {setRockModule} forever.
     * @dev Bought after the rehearsal proves the modules rather than before.
     *      Until this lands, a bug in the mint or the rock module is a
     *      redeploy and a re-point. After it, both are as fixed as
     *      MAX_SUPPLY. Both pointers must already be set, since locking a
     *      half-wired collection would brick it in exactly the way this call
     *      exists to prevent.
     */
    function lockWiring() external onlyOwner {
        require(!wiringLocked, "locked");
        require(minter != address(0), "minter unset");
        require(address(rockModule) != address(0), "module unset");
        wiringLocked = true;
        emit WiringLocked();
    }

    /// @notice Commit the metadata provenance hash. Once, before mint opens.
    function commitProvenance(bytes32 hash) external onlyOwner {
        require(provenanceHash == bytes32(0), "committed");
        require(hash != bytes32(0), "hash=0");
        provenanceHash = hash;
        emit ProvenanceCommitted(hash);
    }

    function setBaseURI(string calldata baseURI) external onlyOwner {
        require(!metadataFrozen, "frozen");
        _baseTokenURI = baseURI;
        emit BaseURISet(baseURI);
    }

    /// @notice Freeze metadata forever, after the reveal. Names are born and
    ///         permanent; from here the pointer is too.
    function freezeMetadata() external onlyOwner {
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    /// @notice Re-point the royalty receiver. The rate can only come down
    ///         from the launch 2.5%, so nobody is ever asked for more than
    ///         was promised.
    function setDefaultRoyalty(
        address receiver,
        uint96 feeNumerator
    ) external onlyOwner {
        require(receiver != address(0), "royalty=0");
        require(feeNumerator <= 250, "royalty>2.5%");
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    // --------------------------------------------------------------------- //
    // Mint
    // --------------------------------------------------------------------- //

    /// @notice Mint brah `brahId` to `to` and give him his wallet. Prices,
    ///         the ladder and per-transaction caps live in GenesisMint. This
    ///         contract enforces only what can never change: a valid id and
    ///         no double mint.
    function mint(address to, uint256 brahId) external {
        require(msg.sender == minter, "not minter");
        require(brahId >= 1 && brahId <= MAX_SUPPLY, "bad id");
        // No brah wakes before the id to identity mapping is committed, so
        // the sealed order is enforced on chain rather than promised.
        require(provenanceHash != bytes32(0), "provenance first");

        totalMinted += 1;
        _mint(to, brahId); // reverts on double-mint

        address tba = tbaRegistry.createAccount(
            tbaImplementation,
            block.chainid,
            address(this),
            brahId,
            tbaSalt
        );
        _tbaOf[brahId] = tba;
        _tbaToBrahId[tba] = brahId;

        emit BrahBorn(brahId, to, tba);
    }

    // --------------------------------------------------------------------- //
    // Views
    // --------------------------------------------------------------------- //

    function classOf(uint256 brahId) public pure returns (Class) {
        if (brahId == 0 || brahId > MAX_SUPPLY) return Class.None;
        if (brahId <= ANCIENTS_END) return Class.Ancient;
        if (brahId <= ELDERS_END) return Class.Elder;
        return Class.Common;
    }

    function minted(uint256 brahId) public view returns (bool) {
        return _ownerOf(brahId) != address(0);
    }

    function tbaOf(uint256 brahId) external view returns (address) {
        return _tbaOf[brahId];
    }

    function tbaToBrahId(address account) external view returns (uint256) {
        return _tbaToBrahId[account];
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @notice `<baseURI><tokenId>.json`, the metadata pointer for one brah.
     *
     * Overridden because the default 404s. ERC721 joins the base and the id
     * and stops, which points at a directory entry that does not exist: the
     * pinned folder holds `1.json` through `999.json`, not `1` through
     * `999`. The suffix is the whole reason for this override.
     *
     * Returns "" while the base is unset, instead of a bare ".json". A
     * marketplace reads the empty string as "no metadata yet", which is true
     * before the reveal, and reads ".json" as a broken link.
     *
     * URIs stay `ipfs://`. A gateway hostname baked in here would outlive
     * the gateway, and every marketplace resolves ipfs:// on its own.
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId); // reverts for an id nobody has adopted
        string memory base = _baseTokenURI;
        if (bytes(base).length == 0) return "";
        return string.concat(base, tokenId.toString(), ".json");
    }

    /// @notice Collection-level metadata: name, description, image, and the
    ///         royalty a marketplace shows before anything has sold. One
    ///         file, so unlike {tokenURI} there is no id or suffix to append.
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Point at the collection metadata file. {freezeMetadata}
    ///         closes this alongside the token base, so the two cannot end
    ///         up one frozen and one editable.
    function setContractURI(string calldata uri) external onlyOwner {
        require(!metadataFrozen, "frozen");
        _contractURI = uri;
        emit ContractURISet(uri);
    }

    function ownerOf(
        uint256 tokenId
    ) public view override(ERC721, IBrah999) returns (address) {
        return super.ownerOf(tokenId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // --------------------------------------------------------------------- //
    // Transfer hook: the rock reset
    // --------------------------------------------------------------------- //

    /// @dev Every real transfer clears the rock; the module exempts
    ///      ancients. Mints skip the hook, since a newborn has no rock to
    ///      clear and the elder and ancient grants happen after the mint
    ///      call in GenesisMint.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0) && address(rockModule) != address(0)) {
            rockModule.onBrahTransfer(tokenId);
        }
        return from;
    }
}
