// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IOracle.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IZapper.sol";

import "./owner/Operator.sol";

contract GsnakeSwapper is Operator {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public snake;
    address public gsnake;
    address public bsnake;

    address public snakeOracle;
    address public gsnakeOracle;
    address public treasury;
    address public zapper;

    

    mapping (address => bool) public useNativeRouter;

    event BsnakeSwapPerformed(address indexed sender, uint256 bsnakeAmount, uint256 gsnakeAmount);


    constructor(
        address _snake,
        address _bsnake,
        address _gsnake,
        address _snakeOracle,
        address _gsnakeOracle,
        address _treasury,
        address _zapper
    ) {
        snake = _snake;
        bsnake = _bsnake;
        gsnake = _gsnake;
        snakeOracle = _snakeOracle;
        gsnakeOracle = _gsnakeOracle;
        treasury = _treasury;
        zapper = _zapper;
    }
   modifier whitelist(address route) {
        require(useNativeRouter[route], "route not allowed");
        _;
    }

     function _approveTokenIfNeeded(address token, address router) private {
        if (IERC20(token).allowance(address(this), router) == 0) {
            IERC20(token).safeApprove(router, type(uint256).max);
        }
    }

    function getSnakePrice() public view returns (uint256 snakePrice) {
        try IOracle(snakeOracle).consult(snake, 1e18) returns (uint256 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult SNAKE price from the oracle");
        }
    }
    function getGsnakePrice() public view returns (uint256 gsnakePrice) {
        try IOracle(gsnakeOracle).consult(gsnake, 1e18) returns (uint256 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult GSNAKE price from the oracle");
        }
    }
    function redeemBonds(uint256 _bsnakeAmount, uint256 snakePrice) private returns (uint256) {

         IERC20(bsnake).safeTransferFrom(msg.sender, address(this), _bsnakeAmount);
         _approveTokenIfNeeded(bsnake, treasury);
       
        try ITreasury(treasury).redeemBonds(_bsnakeAmount, snakePrice) {
        } catch {
            revert("Treasury: cant redeem bonds");
        }
        return getSnakeBalance();
    }

    function swap(address _in, uint256 amount, address out, address recipient, address routerAddr, uint256 minAmountOfGsnake) private returns (uint256) {
        
        IERC20(snake).safeTransferFrom(address(this), zapper, amount);
        _approveTokenIfNeeded(snake, routerAddr);
        
         try IZapper(zapper)._swap(_in, amount, out, recipient, routerAddr , minAmountOfGsnake) returns (uint256 _gsnakeAmount) {
             require( _gsnakeAmount >= minAmountOfGsnake, "amt < minAmountNeeded");
            return uint256(_gsnakeAmount);
        } catch {
            revert("Treasury: failed to get GSNAKE price");
        }
    }
   

    function estimateAmountOfGsnake(uint256 _bsnakeAmount) external view returns (uint256) {
        uint256 gsnakeAmountPerSnake = getGsnakeAmountPerSnake();
        return _bsnakeAmount.mul(gsnakeAmountPerSnake).div(1e18);
    }

    function swapBsnakeToGsnake(uint256 _bsnakeAmount, address routerAddr, uint256 minAmountofGsnake) external whitelist(routerAddr) {
        //check if we have the amount of bsnakes we want to swap
        require(getBsnakeBalance(msg.sender) >= _bsnakeAmount, "Not enough Bsnake in wallet");
        
       // send bsnake to treasury(call redeem bonds in treasury) and receive snake back
        uint256 snakePrice = getSnakePrice();
        uint256 snakeToSwap = redeemBonds(_bsnakeAmount, snakePrice);
       // check if we received snake(should be more than bsnakes because of higher rate in redeem in treasury)
       require ( snakeToSwap >= _bsnakeAmount, "redeem bonds reverted"); 
       // swap snake to gsnake
        uint256 gsnakeReceived = swap(snake, snakeToSwap, gsnake, msg.sender, routerAddr, minAmountofGsnake);

        emit BsnakeSwapPerformed(msg.sender, _bsnakeAmount, gsnakeReceived);
    }


    function getSnakeBalance() public view returns (uint256) {
        return IERC20(snake).balanceOf(address(this));
    }
    function getGsnakeBalance() public view returns (uint256) {
        return IERC20(gsnake).balanceOf(address(this));
    }

    function getBsnakeBalance(address _user) public view returns (uint256) {
        return IERC20(bsnake).balanceOf(_user);
    }
    
    function getGsnakeAmountPerSnake() public view returns (uint256) {
        uint256 snakePrice = getSnakePrice();
        uint256 gsnakePrice = getGsnakePrice();
        return snakePrice.mul(1e18).div(gsnakePrice);
    }
    function setUseNativeRouter(address router) external onlyOwner {
        useNativeRouter[router] = true;
    }

    function removeNativeRouter(address router) external onlyOwner {
        useNativeRouter[router] = false;
    }

}