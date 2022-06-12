// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/Address.sol";

contract ScreamBadDebtOracle {
    using Address for address;
    
    /* ========== STATE VARIABLES ========== */
    address[] public badDebtAccounts; //@notice These accounts hold borrows with no supplied assets
    address public owner; //@notice The address of the owner, i.e. the Timelock contract, which can update parameters directly

    /**
     * @notice Construct our bad debt oracle
     * @param _badDebtAccounts The accounts with outstanding borrows and no remaining supplied assets
     * @param _owner The address of the owner with the ability to update badDebtAccounts in the future
     */
    constructor(address[] memory _badDebtAccounts, address _owner) public {
        owner = _owner;
        badDebtAccounts = _badDebtAccounts;
    }

    /**
     * @notice Update which accounts have bad debt on Scream v1
     * @param _badDebtAccounts The accounts with outstanding borrows and no remaining supplied assets
     */
    function updateBadDebtAccounts(address[] memory _badDebtAccounts) external {
        require(msg.sender == owner, "only the owner may call this function.");

        badDebtAccounts = _badDebtAccounts;
    }
}