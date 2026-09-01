// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "../interfaces/IERC6551Account.sol";
import "../interfaces/IERC6551Executable.sol";

contract BrahTbaAccount is IERC165, IERC1271, IERC6551Account, IERC6551Executable {
    /** @dev State variable to track the number of executed transactions */
    uint256 public state;

    /** @dev Fallback function to allow the contract to receive ETH */
    receive() external payable {}

    /**
     * @dev Executes a call to a target address with provided value and data
     * @param to Target address to call
     * @param value ETH value to send with the call
     * @param data Calldata to send to the target
     * @param operation Operation type (must be 0 for call)
     * @return result Bytes result from the call
     */
    function execute(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 operation
    ) external payable returns (bytes memory result) {
        require(_isValidSigner(msg.sender), "Invalid signer");
        require(operation == 0, "Only call operations are supported");

        ++state;

        bool success;
        (success, result) = to.call{value: value}(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /**
     * @dev Checks if an address is a valid signer for this account
     * @param signer Address to check
     * @return bytes4 Magic value if valid, otherwise 0x0
     */
    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        if (_isValidSigner(signer)) {
            return IERC6551Account.isValidSigner.selector;
        }

        return bytes4(0);
    }

    /**
     * @dev Validates a signature against the owner's address
     * @param hash Message hash to validate
     * @param signature Signature to check
     * @return magicValue IERC1271 magic value if valid, otherwise empty bytes4
     */
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        returns (bytes4 magicValue)
    {
        bool isValid = SignatureChecker.isValidSignatureNow(owner(), hash, signature);

        if (isValid) {
            return IERC1271.isValidSignature.selector;
        }

        return "";
    }

    /**
     * @dev Checks if the contract supports a given interface
     * @param interfaceId Interface ID to check
     * @return bool True if the interface is supported, false otherwise
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return (interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC6551Account).interfaceId ||
            interfaceId == type(IERC6551Executable).interfaceId);
    }

    /**
     * @dev Retrieves the token details (chain ID, contract address, token ID) from contract code
     * @return chainId Chain ID of the token
     * @return tokenContract Address of the ERC721 contract
     * @return tokenId ID of the token
     */
    function token()
        public
        view
        returns (
            uint256,
            address,
            uint256
        )
    {
        bytes memory footer = new bytes(0x60);

        assembly {
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }

        return abi.decode(footer, (uint256, address, uint256));
    }

    /**
     * @dev Returns the current owner of the associated ERC721 token
     * @return address Owner address, or 0 if chain ID mismatches
     */
    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);

        return IERC721(tokenContract).ownerOf(tokenId);
    }

    /**
     * @dev Internal function to check if an address is the valid signer (owner)
     * @param signer Address to verify
     * @return bool True if the signer is the owner, false otherwise
     */
    function _isValidSigner(address signer) internal view returns (bool) {
        return signer == owner();
    }
}