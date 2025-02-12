// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./shadow/interfaces/IPool.sol";
import "./owner/Operator.sol";

contract Oracle is Operator {
    using SafeMath for uint256;

    address public token0;
    address public token1;
    IPool public pair;

    constructor(IPool _pair) public {
        pair = _pair;
        token0 = pair.token0();
        token1 = pair.token1();
        uint256 reserve0;
        uint256 reserve1;
        (reserve0, reserve1, ) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "Oracle: No reserves");
    }

    function update() external {
        pair.sync();
    }

    function consult(
        address _token,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        if (_token == token0) {
            amountOut = _quote(_token, _amountIn, 12, 1);
        } else {
            require(_token == token1, "Oracle: Invalid token");
            amountOut = _quote(_token, _amountIn, 12, 1);
        }
    }

    function twap(
        address _token,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        if (_token == token0) {
            amountOut = _quote(_token, _amountIn, 2, 1);
        } else if (_token == token1) {
            amountOut = _quote(_token, _amountIn, 2, 1);
        }
    }

    function _quote(
        address tokenIn,
        uint256 amountIn,
        uint256 granularity, // number of observations to query
        uint256 window // time window to query
    ) internal view returns (uint256 amountOut) {
        uint256 observationLength = IPool(pair).observationLength();
        require(
            granularity <= observationLength,
            "Oracle: Not enough observations"
        );

        uint256 totalRatio = 0;
        address tkn = tokenIn;

        for (uint256 i = 1; i <= granularity; i++) {
            (
                uint256 timestamp,
                uint256 cumulative0,
                uint256 cumulative1
            ) = IPool(pair).observations(observationLength - i);

            (
                uint256 prevTimestamp,
                uint256 prevCumulative0,
                uint256 prevCumulative1
            ) = IPool(pair).observations(observationLength - i - 1);

            uint256 timeElapsed = timestamp - prevTimestamp;

            uint256 reserve0 = (cumulative0 - prevCumulative0) / timeElapsed;
            uint256 reserve1 = (cumulative1 - prevCumulative1) / timeElapsed;

            uint256 ratio = tkn == token0
                ? (reserve1 * 10 ** 18) / reserve0
                : (reserve0 * 10 ** 18) / reserve1;

            totalRatio += ratio;
        }

        // Calculate the average ratio
        uint256 averageRatio = totalRatio / granularity;

        // Set the output amount based on the average ratio
        amountOut = averageRatio;
    }
}
