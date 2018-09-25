pragma solidity 0.4.25;


import "./Beneficiary.sol";


contract Manageable is Beneficiary {
    mapping(address => bool) public managers;

    modifier onlyManager() {

        require(managers[msg.sender] || msg.sender == address(this), "Only managers allowed");
        _;
    }

    constructor() public {
        managers[msg.sender] = true;
    }

    function setManager(address _manager) public onlyOwner {
        managers[_manager] = true;
    }

    function deleteManager(address _manager) public onlyOwner {
        delete managers[_manager];
    }

}
