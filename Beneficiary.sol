pragma solidity 0.4.25;

import "./Ownable.sol";


contract Beneficiary is Ownable {

    address public beneficiary;

    constructor() public {
        beneficiary = msg.sender;
    }

    function setBeneficiary(address _beneficiary) public onlyOwner {
        beneficiary = _beneficiary;
    }

    function withdrawal(uint256 value) public onlyOwner {
        if (value > address(this).balance) {
            revert("Insufficient balance");
        }

        beneficiary.transfer(value);
    }

    function withdrawalAll() public onlyOwner {
        beneficiary.transfer(address(this).balance);
    }
}
