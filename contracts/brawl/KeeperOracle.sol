// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IOracle.sol";

/**
 * @title KeeperOracle
 * @notice Testnet fact source for brawls. A keeper holding OPERATOR_ROLE
 *         publishes values with {setValue}; everything reads them back
 *         through {IOracle}, so mainnet can swap in a real feed adapter
 *         without touching the escrow.
 */
contract KeeperOracle is IOracle, AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct Feed {
        int256 value;
        uint256 updatedAt;
    }

    mapping(bytes32 => Feed) private _feeds;

    event ValueSet(bytes32 indexed feedId, int256 value, uint256 updatedAt);

    constructor(address admin, address operator) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    /// @notice Publish or overwrite a feed value. Testnet only.
    function setValue(
        bytes32 feedId,
        int256 value
    ) external onlyRole(OPERATOR_ROLE) {
        _feeds[feedId] = Feed({value: value, updatedAt: block.timestamp});
        emit ValueSet(feedId, value, block.timestamp);
    }

    /// @inheritdoc IOracle
    function latestValue(
        bytes32 feedId
    ) external view override returns (int256 value, uint256 updatedAt) {
        Feed memory f = _feeds[feedId];
        return (f.value, f.updatedAt);
    }
}
