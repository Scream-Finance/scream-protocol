// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/Address.sol";

interface IScream {
 function borrowBalanceStored(address account) external view returns (uint);
 
 function getAccountLiquidity(address account) external view returns (uint, uint, uint);
}


contract ScreamBadDebtOracle {
    using Address for address;
    
    /* ========== STATE VARIABLES ========== */
    address[] public badDebtAccounts; /// @notice These accounts hold borrows with no supplied assets
    address public owner; /// @notice The address of the owner, i.e. the Timelock contract, which can update parameters directly
    IScream public constant unitroller = IScream(0x260E596DAbE3AFc463e75B6CC05d8c46aCAcFB09); /// @notice Scream v1 unitroller
    mapping (address => bool) public addressHasBadDebt;

    /**
     * @notice Construct our bad debt oracle
     * @param _badDebtAccounts The accounts with outstanding borrows and no remaining supplied assets
     * @param _owner The address of the owner with the ability to update badDebtAccounts in the future
     */
    constructor(address[] memory _badDebtAccounts, address _owner) public {
        owner = _owner;
        badDebtAccounts = _badDebtAccounts;
        
        // go through our new bad debt holders and map to true        
        for (uint256 i = 0; i < _badDebtAccounts.length; i++) {
            address newbadDebtHolder = _badDebtAccounts[i];
            addressHasBadDebt[newbadDebtHolder] = true;
        }
    }

    /**
     * @notice View for how much bad debt our accounts have in total (in USD)
     * @return The total bad debt for all badDebtAccounts
     */
    function totalBadDebt(address scToken) external view returns (uint256) {
        uint256 allBadDebt;
        IScream scTokenContract = IScream(scToken);
        for (uint256 i = 0; i < badDebtAccounts.length; i++) {
            address badDebtHolder = badDebtAccounts[i];
            uint256 borrowed = scTokenContract.borrowBalanceStored(badDebtHolder);
            if (borrowed > 0) {
                allBadDebt += borrowed;
            }
        }
        return allBadDebt;
    }

    /**
     * @notice View for total bad debt of a single user
     * @return The total bad debt for the user
     */
    function getUserBadDebt(address _user) external view returns (uint256) {
        uint256 userBadDebt;
        (, , userBadDebt) = unitroller.getAccountLiquidity(_user);
        return userBadDebt;
    }
    
    /**
     * @notice View for if an account has bad debt or not
     * @return Bool for if an account has bad debt
     */
    function hasBadDebt(address _user) external view returns (bool) {
        return addressHasBadDebt[_user];
    }

    /**
     * @notice Update which accounts have bad debt on Scream v1
     * @param _badDebtAccounts The accounts with outstanding borrows and no remaining supplied assets
     */
    function updateBadDebtAccounts(address[] memory _badDebtAccounts) external {
        require(msg.sender == owner, "only the owner may call this function.");
        
        // first, we go through and reset our existing mappings
        for (uint256 i = 0; i < badDebtAccounts.length; i++) {
            address newbadDebtHolder = badDebtAccounts[i];
            addressHasBadDebt[newbadDebtHolder] = false;
        }
        
        // then, we go through our new bad debt holders and map to true        
        for (uint256 i = 0; i < _badDebtAccounts.length; i++) {
            address newbadDebtHolder = _badDebtAccounts[i];
            addressHasBadDebt[newbadDebtHolder] = true;
        }
        
        // now we can overwrite our array of accounts
        badDebtAccounts = _badDebtAccounts;
    }
}