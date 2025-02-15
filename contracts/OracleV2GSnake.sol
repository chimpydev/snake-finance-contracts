// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./shadow/interfaces/IPool.sol";
import "./owner/Operator.sol";

contract OracleV2GSnake is Operator {
    using SafeMath for uint256;

    address public token0;
    address public token1;
    uint256 public granularityToUse = 1; // 1 observation every 30 minutes
    bool public useTwap = false;
    bool public useInstantPrice = true;
    IPool public pair;

    constructor(IPool _pair) public {
        pair = _pair;
        token0 = pair.token0();
        token1 = pair.token1();
        // uint256 reserve0;
        // uint256 reserve1;
        // (reserve0, reserve1, ) = pair.getReserves();
        // require(reserve0 != 0 && reserve1 != 0, "Oracle: No reserves");
    }

    function update() external {
        pair.sync();
    }

    function consult(
        address _token,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        if (_token == token0) {
            amountOut = _quote(_token, _amountIn, 12);
        } else {
            require(_token == token1, "Oracle: Invalid token");
            amountOut = _quote(_token, _amountIn, 12);
        }
    }

    function twap(
        address _token,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        if (_token == token0) {
            if (useTwap) {
                amountOut = _quote(_token, _amountIn, granularityToUse);
            } else {
                if (useInstantPrice) {
                    amountOut = _getAmountOut(_token, _amountIn);
                } else {
                    amountOut = _current(_token, _amountIn);
                }
            }
        } else {
            require(_token == token1, "Oracle: Invalid token");
            if (useTwap) {
                amountOut = _quote(_token, _amountIn, granularityToUse);
            } else {
                if (useInstantPrice) {
                    amountOut = _getAmountOut(_token, _amountIn);
                } else {
                    amountOut = _current(_token, _amountIn);
                }
            }
        }
    }

    // Note the window parameter is removed as its always 1 (30min), granularity at 12 for example is (12 * 30min) = 6 hours
    function _quote(
        address tokenIn,
        uint256 amountIn,
        uint256 granularity // number of observations to query
    ) internal view returns (uint256 amountOut) {
        uint256 observationLength = IPool(pair).observationLength();
        require(
            granularity <= observationLength,
            "Oracle: Not enough observations"
        );

        uint256 price = IPool(pair).quote(tokenIn, amountIn, granularity);
        amountOut = price;
    }

    // Note the window parameter is removed as its always 1 (30min), granularity at 12 for example is (12 * 30min) = 6 hours
    function _getAmountOut(
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        uint256 reserve0;
        uint256 reserve1;
        (reserve0, reserve1, ) = IPool(pair).getReserves();
        require(reserve0 != 0 && reserve1 != 0, "Oracle: No reserves");

        uint256 price = IPool(pair).getAmountOut(amountIn, tokenIn);
        amountOut = price;
    }

    // Note the window parameter is removed as its always 1 (30min), granularity at 12 for example is (12 * 30min) = 6 hours
    function _current(
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        uint256 observationLength = IPool(pair).observationLength();
        require(
            observationLength > 0,
            "Oracle: Not enough observations"
        );

        uint256 price = IPool(pair).current(tokenIn, amountIn);
        amountOut = price;
    }

    function setGranularity(uint256 _granularity) external onlyOperator {
        granularityToUse = _granularity;
    }

    function setUseTwap(bool _useTwap) external onlyOperator {
        useTwap = _useTwap;
    }

    function setUseInstantPrice(bool _useInstantPrice) external onlyOperator {
        useInstantPrice = _useInstantPrice;
    }
}
