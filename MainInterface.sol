pragma solidity 0.4.24;

contract MainInterface {
    function transferCallback(int256 x, int256 y, uint16 regionId, address from, address to) external;
}
