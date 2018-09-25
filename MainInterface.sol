pragma solidity 0.4.25;

contract MainInterface {
    function transferCallback(int256 x, int256 y, uint16 regionId, address from, address to) external;
    function addToRegionShareBank(uint16 regionId, int256 value) external;
    function setResourcesInfluence(int256 x, int256 y, uint16 regionId, uint8 resources, address owner) external;
}
