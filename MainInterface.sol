pragma solidity 0.4.25;

contract MainInterface {
    function transferCallback(int64 x, int64 y, uint16 regionId, address from, address to) external;
    function addToRegionShareBank(uint16 regionId, int256 value) external;
    function setResourcesInfluence(int64 x, int64 y, uint16 regionId, uint8 resources, address owner) external;
    function addToGlobalShareBankCallable(int256 value) external;
    function sendToBeneficiary(uint256 value) external;
    function regionOwner(uint16 regionId) external returns (address);
}
