pragma solidity 0.4.24;

import "./Manageable.sol";


contract UserBalance is Manageable {

    struct Journal {
        uint256 value;
        bool charge;
        uint8 transactionType;// 0 - land payout, 1 - region payout, 2 - change, 3 - auction, 4 - influence payout
        uint ts;
    }

    mapping (address => uint256) public userBalance;
    mapping (address => Journal[]) public userJournal;

    uint256 totalBalance = 0;

    function addBalance(address user, uint256 value, uint8 transactionType) external onlyManager returns (uint256) {

        userBalance[user] += value;
        totalBalance += value;
        
        userJournal[user].push(Journal({
            value: value,
            charge: true,
            transactionType: transactionType,
            // solium-disable-next-line
            ts: now
        }));

        return userBalance[user];
    }

    function decBalance(address user, uint256 value, uint8 transactionType) public onlyManager returns (uint256) {
        require(userBalance[user] >= value, "Insufficient balance");

        userBalance[user] -= value;
        totalBalance -= value;

        userJournal[user].push(Journal({
            value: value,
            charge: false,
            transactionType: transactionType,
            // solium-disable-next-line
            ts: now
        }));

        return userBalance[user];
    }

    function getBalance(address user) public view returns (uint256) {
        return userBalance[user];
    }

    function userWithdrawal(uint256 value, address user) external onlyManager returns (uint256) {
        require(
            userBalance[user] >= value && address(this).balance >= value,
            "Insufficient balance"
        );

        decBalance(user, value, 3);
        emit UserWithdrawalDone(msg.sender, value);

        return value;
    }

    function getLog20(
        address user, uint256 page
    ) public view returns (
        uint256[20] value, bool[20] charge, uint8[20] transactionType, uint256[20] ts
    ) {
        uint256 lastLog = userJournal[user].length - 1;
        for (uint256 i = 0; i < 20; i++) {
            if(lastLog < page * 20 + i) {
                break;
            }

            uint256 current = lastLog - page * 20 - i;
            value[i] = userJournal[user][current].value;
            charge[i] = userJournal[user][current].charge;
            transactionType[i] = userJournal[user][current].transactionType;
            ts[i] = userJournal[user][current].ts;
        }
    }

    function getLogLength(address user) public view returns (uint256) {
        return userJournal[user].length;
    }

    event UserWithdrawalDone(address user, uint256 value);

}
