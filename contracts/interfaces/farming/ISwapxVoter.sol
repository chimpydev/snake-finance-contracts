// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
pragma abicoder v2;

interface ISwapxVoter {
    function gauges(address _pool) external view returns (address);
}