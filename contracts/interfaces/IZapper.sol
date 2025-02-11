// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IZapper {
    function _swap(address _in, uint256 amount, address out, address recipient, address routerAddr, uint256 slippage) external returns (uint256);

    function _estimateSwap(address _in, uint256 amount, address out, address routerAddr) external view returns (uint256);

}
