// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./shadow/interfaces/IPool.sol";
import "./owner/Operator.sol";

contract OracleBased is Operator {
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

    function consult(address _token, uint256 _amountIn) external view returns (uint256 amountOut) {
        if (_token == token0) {
            amountOut = _quote(_token, _amountIn, 12, 1);
        } else {
            require(_token == token1, "Oracle: Invalid token");
            amountOut = _quote(_token, _amountIn, 12, 1);
        }
    }

    function twap(address _token, uint256 _amountIn) external view returns (uint256 amountOut) {
        if (_token == token0) {
            amountOut = _quote(_token, _amountIn, 12, 1);
        } else if (_token == token1) {
            amountOut = _quote(_token, _amountIn, 12, 1);
        }
    }

    function _quote(address tokenIn, uint256 amountIn, uint256 granularity, uint256 window) internal view returns (uint256 amountOut) {
        uint256[] memory _prices = pair.sample(tokenIn, amountIn, granularity, window);
        uint256 priceAverageCumulative;
        uint256 _length = _prices.length;
        for (uint256 i = 0; i < _length; i++) {
            priceAverageCumulative += _prices[i];
        }
        return priceAverageCumulative / granularity;
    }
}