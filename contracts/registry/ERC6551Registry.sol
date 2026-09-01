// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Create2.sol";
import "../interfaces/IERC6551Registry.sol";
import "../libs/ERC6551BytecodeLib.sol";

contract ERC6551Registry is IERC6551Registry {
    /** @dev Error thrown when account initialization fails */
    error InitializationFailed();

    /**
     * @dev Creates a new account using CREATE2 deployment if it doesn't already exist
     * @param implementation Address of the account implementation contract
     * @param chainId Chain ID where the token exists
     * @param tokenContract Address of the ERC721 token contract
     * @param tokenId ID of the specific token
     * @param salt Unique salt for deterministic address generation
     * @return address Address of the created or existing account
     */
    function createAccount(
        address implementation,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId,
        uint256 salt
    ) external returns (address) {
        bytes memory code = ERC6551BytecodeLib.getCreationCode(
            implementation,
            chainId,
            tokenContract,
            tokenId,
            salt
        );

        address _account = Create2.computeAddress(bytes32(salt), keccak256(code));

        if (_account.code.length != 0) return _account;

        emit AccountCreated(_account, implementation, chainId, tokenContract, tokenId, salt);

        _account = Create2.deploy(0, bytes32(salt), code);

        return _account;
    }

    /**
     * @dev Computes the deterministic address of an account without deploying it
     * @param implementation Address of the account implementation contract
     * @param chainId Chain ID where the token exists
     * @param tokenContract Address of the ERC721 token contract
     * @param tokenId ID of the specific token
     * @param salt Unique salt for deterministic address generation
     * @return address Computed address of the account
     */
    function account(
        address implementation,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId,
        uint256 salt
    ) external view returns (address) {
        bytes32 bytecodeHash = keccak256(
            ERC6551BytecodeLib.getCreationCode(
                implementation,
                chainId,
                tokenContract,
                tokenId,
                salt
            )
        );

        return Create2.computeAddress(bytes32(salt), bytecodeHash);
    }
}