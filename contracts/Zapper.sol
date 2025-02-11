// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IHyperswapRouter.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IVault.sol";
import "./lib/TransferHelper.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Zapper is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // @NATIVE - native token that is not a part of our zap-in LP
    address private NATIVE;

    struct LiquidityPair {
        address _token0;
        address _token1;
        uint256 _amountToken0;
        uint256 _amountToken1;
        uint256 _liqTokenAmt;
    }

    struct FunctionArgs {
        address _LP;
        address _in;
        address _out;
        address _recipient;
        address _routerAddr;
        address _token;
        uint256 _amount;
        
        uint256 _otherAmt;
        uint256 _swapAmt;
    }

    mapping(address => mapping(address => address)) private tokenBridgeForRouter;

    mapping (address => bool) public useNativeRouter;

    modifier whitelist(address route) {
        require(useNativeRouter[route], "route not allowed");
        _;
    }

    // Snake address here
    constructor(address _NATIVE) Ownable() {
        NATIVE = _NATIVE;
    }

    /* ========== External Functions ========== */

    receive() external payable {}

    function NativeToken() public view returns (address) {
        return NATIVE;
    }

    // @_in - Token we want to throw in
    // @amount - amount of our _in
    // @out - address of LP we are going to get
    // @minAmountOfLp - will be calculated on UI including slippage set by user

    function zapInToken(address _in, uint256 amount, address out, address routerAddr, address recipient, uint256 minAmountOfLp) external whitelist(routerAddr) {
        // From an ERC20 to an LP token, through specified router, going through base asset if necessary
        IERC20(_in).safeTransferFrom(msg.sender, address(this), amount);
        // we'll need this approval to add liquidity
        _approveTokenIfNeeded(_in, routerAddr);
       uint256 amountOfLp =  _swapTokenToLP(_in, amount, out, recipient, routerAddr);
        // add require after actual actioin of all functions - will revert lp creation if doesnt meet requirement
        require(amountOfLp >= minAmountOfLp, "lp amount too small");
    }
    // @_in - Token we want to throw in
    // @amount - amount of our _in
    // @out - address of LP we are going to get

    function estimateZapInToken(address _in, address out, address router, uint256 amount) public view whitelist(router) returns (uint256, uint256) {
        // get pairs for desired lp
        // check if we already have one of the assets
        if (_in == IUniswapV2Pair(out).token0() || _in == IUniswapV2Pair(out).token1()) {
            // if so, we're going to sell half of in for the other token we need
            // figure out which token we need, and approve
            address other = _in == IUniswapV2Pair(out).token0() ? IUniswapV2Pair(out).token1() : IUniswapV2Pair(out).token0();
            // calculate amount of in to sell
            uint256 sellAmount = amount.div(2);
            // calculate amount of other token for potential lp
            uint256 otherAmount = _estimateSwap(_in, sellAmount, other, router);
            if (_in == IUniswapV2Pair(out).token0()) {
                return (sellAmount, otherAmount);
            } else {
                return (otherAmount, sellAmount);
            }
        } else {
            // go through native token, that's not in our LP, for highest liquidity
            uint256 nativeAmount = _in == NATIVE ? amount : _estimateSwap(_in, amount, NATIVE, router);
            return estimateZapIn(out, router, nativeAmount);
        }
    }

    function estimateZapIn(address LP, address router, uint256 amount) public view whitelist(router) returns (uint256, uint256) {
        uint256 zapAmount = amount.div(2);

        IUniswapV2Pair pair = IUniswapV2Pair(LP);
        address token0 = pair.token0();
        address token1 = pair.token1();

        if (token0 == NATIVE || token1 == NATIVE) {
            address token = token0 == NATIVE ? token1 : token0;
            uint256 tokenAmount = _estimateSwap(NATIVE, zapAmount, token, router);
            if (token0 == NATIVE) {
                return (zapAmount, tokenAmount);
            } else {
                return (tokenAmount, zapAmount);
            }
        } else {
            uint256 amountToken0 = _estimateSwap(NATIVE, zapAmount, token0, router);
            uint256 amountToken1 = _estimateSwap(NATIVE, zapAmount, token1, router);

            return (amountToken0, amountToken1);
        }
    }

    // from Native to an LP token through the specified router
    // @ out - LP we want to get out of this
    // @ minAmountOfLp will be calculated on UI using estimate function and passed into this function
    function nativeZapIn(uint256 amount, address out, address routerAddr, address recipient, uint256 minAmountOfLp) external whitelist (routerAddr) {
         IERC20(NATIVE).safeTransferFrom(msg.sender, address(this), amount);
         _approveTokenIfNeeded(NATIVE, routerAddr);
        uint256 amountOfLp = _swapNativeToLP(out, amount, recipient, routerAddr);
        require(amountOfLp >= minAmountOfLp);
    }

     // @ _fromLP - LP we want to throw in
    // @ _to - token we want to get out of our LP
    // @ minAmountToken0, minAmountToken1 - coming from UI (min amount of tokens coming from breaking our LP)
    function estimateZapOutToken(address _fromLp, address _to, address _router, uint256 minAmountToken0, uint256 minAmountToken1 ) public view whitelist(_router) returns (uint256) {
        address token0 = IUniswapV2Pair(_fromLp).token0();
        address token1 = IUniswapV2Pair(_fromLp).token1();
        if(_to == NATIVE) {
            if(token0 == NATIVE) {
                return _estimateSwap(token1, minAmountToken1, _to, _router).add(minAmountToken0);
            } else {
                return _estimateSwap(token0, minAmountToken0, _to, _router).add(minAmountToken1);
            }
        }

        if(token0 == NATIVE) {

            if(_to == token1) {
               
                return _estimateSwap(token0, minAmountToken0, _to, _router).add(minAmountToken1);

            } else {
               
                uint256 halfAmountof_to = _estimateSwap(token0, minAmountToken0, _to, _router);
                uint256 otherhalfAmountof_to = _estimateSwap(token1, minAmountToken1, _to, _router);
                return (halfAmountof_to.add(otherhalfAmountof_to));
            }
        } else {
            if (_to == token0) {
              
                return _estimateSwap(token1, minAmountToken1, _to, _router).add(minAmountToken0);

            } else {
              
                uint256 halfAmountof_to = _estimateSwap(token0, minAmountToken0, _to, _router);
                uint256 otherhalfAmountof_to = _estimateSwap(token1, minAmountToken1, _to, _router);
                return halfAmountof_to.add(otherhalfAmountof_to);
            }
        }
    }

    // from an LP token to Native through specified router
    // @in - LP we want to throw in
    // @amount - amount of our LP
    function zapOutToNative(address _in, uint256 amount, address routerAddr, address recipient, uint256 minAmountNative) external whitelist(routerAddr) {
        // take the LP token
        IERC20(_in).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_in, routerAddr);

        LiquidityPair memory pair;

        // get pairs for LP
        pair._token0 = IUniswapV2Pair(_in).token0();
        pair._token1 = IUniswapV2Pair(_in).token1();
        _approveTokenIfNeeded(pair._token0, routerAddr);
        _approveTokenIfNeeded(pair._token1, routerAddr);


        (pair._amountToken0, pair._amountToken1) = IUniswapV2Router(routerAddr).removeLiquidity(pair._token0, pair._token1, amount, 0, 0, address(this), block.timestamp);
        if (pair._token0 != NATIVE) {
            pair._amountToken0 = _swapTokenForNative(pair._token0, pair._amountToken0, address(this), routerAddr);
        }
        if (pair._token1 != NATIVE) {
            pair._amountToken1 = _swapTokenForNative(pair._token1, pair._amountToken1, address(this), routerAddr);
        }
        require (pair._amountToken0.add(pair._amountToken1) >= minAmountNative, "token amt < minAmountNative");
        IERC20(NATIVE).safeTransfer(recipient, pair._amountToken0.add(pair._amountToken1));

    }
    // from an LP token to an ERC20 through specified router

    // from an LP token to Native through specified router
    // @in - LP we want to throw in
    // @amount - amount of our LP
    // @out - token we want to get
    function zapOutToToken(address _in, uint256 amount, address out, address routerAddr, address recipient, uint256 minAmountToken) whitelist(routerAddr) external {

        FunctionArgs memory args;
        LiquidityPair memory pair;

        args._amount = amount;
        args._out = out;
        args._recipient = recipient;
        args._routerAddr = routerAddr;
        
        args._in = _in;

        IERC20(args._in).safeTransferFrom(msg.sender, address(this), args._amount);
        _approveTokenIfNeeded(args._in, args._routerAddr);

        pair._token0 = IUniswapV2Pair(args._in).token0();
        pair._token1 = IUniswapV2Pair(args._in).token1();

        _approveTokenIfNeeded(pair._token0, args._routerAddr);
        _approveTokenIfNeeded(pair._token1, args._routerAddr);

        (pair._amountToken0, pair._amountToken1) = IUniswapV2Router(args._routerAddr).removeLiquidity(pair._token0, pair._token1, args._amount, 0, 0, address(this), block.timestamp);
        if (pair._token0 != args._out) {
            pair._amountToken0 = _swap(pair._token0, pair._amountToken0, args._out, address(this), args._routerAddr);
        }
        if (pair._token1 != args._out) {
            pair._amountToken1 = _swap(pair._token1, pair._amountToken1, args._out, address(this), args._routerAddr);
        }
        require (pair._amountToken0.add(pair._amountToken1) >= minAmountToken, "amt < minAmountToken");
        IERC20(args._out).safeTransfer(args._recipient, pair._amountToken0.add(pair._amountToken1));
    }
   
    
    // @_in - token we want to throw in
    // @amount - amount of our _in
    // @out - token we want to get out
    function _swap(address _in, uint256 amount, address out, address recipient, address routerAddr) public whitelist(routerAddr) returns (uint256) {
        IUniswapV2Router router = IUniswapV2Router(routerAddr);

        address fromBridge = tokenBridgeForRouter[_in][routerAddr];
        address toBridge = tokenBridgeForRouter[out][routerAddr];

        address[] memory path;

        if (fromBridge != address(0) && toBridge != address(0)) {
            if (fromBridge != toBridge) {
                path = new address[](5);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = NATIVE;
                path[3] = toBridge;
                path[4] = out;
            } else {
                path = new address[](3);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = out;
            }
        } else if (fromBridge != address(0)) {
            if (out == NATIVE) {
                path = new address[](3);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = NATIVE;
            } else {
                path = new address[](4);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = NATIVE;
                path[3] = out;
            }
        } else if (toBridge != address(0)) {
            path = new address[](4);
            path[0] = _in;
            path[1] = NATIVE;
            path[2] = toBridge;
            path[3] = out;
        } else if (_in == NATIVE || out == NATIVE) {
            path = new address[](2);
            path[0] = _in;
            path[1] = out;
        } else {
            // Go through Native
            path = new address[](3);
            path[0] = _in;
            path[1] = NATIVE;
            path[2] = out;
        }
        uint256 tokenAmountEst = _estimateSwap(_in, amount, out, routerAddr);

        uint256[] memory amounts = router.swapExactTokensForTokens(amount, tokenAmountEst, path, recipient, block.timestamp);
        require(amounts[amounts.length-1] >= tokenAmountEst, "amount smaller than estimate");
        return amounts[amounts.length - 1];
    }
    // @_in - token we want to throw in
    // @amount - amount of our _in
    // @out - token we want to get out
    function _estimateSwap(address _in, uint256 amount, address out, address routerAddr) public view whitelist(routerAddr) returns (uint256) {
        IUniswapV2Router router = IUniswapV2Router(routerAddr);

        address fromBridge = tokenBridgeForRouter[_in][routerAddr];
        address toBridge = tokenBridgeForRouter[out][routerAddr];

        address[] memory path;

        if (fromBridge != address(0) && toBridge != address(0)) {
            if (fromBridge != toBridge) {
                path = new address[](5);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = NATIVE;
                path[3] = toBridge;
                path[4] = out;
            } else {
                path = new address[](3);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = out;
            }
        } else if (fromBridge != address(0)) {
            if (out == NATIVE) {
                path = new address[](3);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = NATIVE;
            } else {
                path = new address[](4);
                path[0] = _in;
                path[1] = fromBridge;
                path[2] = NATIVE;
                path[3] = out;
            }
        } else if (toBridge != address(0)) {
            path = new address[](4);
            path[0] = _in;
            path[1] = NATIVE;
            path[2] = toBridge;
            path[3] = out;
        } else if (_in == NATIVE || out == NATIVE) {
            path = new address[](2);
            path[0] = _in;
            path[1] = out;
        } else {
            // Go through Native
            path = new address[](3);
            path[0] = _in;
            path[1] = NATIVE;
            path[2] = out;
        }

        uint256[] memory amounts = router.getAmountsOut(amount, path);
        return amounts[amounts.length - 1];
    }
    /* ========== Private Functions ========== */

    function _approveTokenIfNeeded(address token, address router) private {
        if (IERC20(token).allowance(address(this), router) == 0) {
            IERC20(token).safeApprove(router, type(uint256).max);
        }
    }
    
    function _swapTokenToLP(address _in, uint256 amount, address out, address recipient, address routerAddr) private returns (uint256) {
       
        FunctionArgs memory args;
            args._in = _in;
            args._amount = amount;
            args._out = out;
            args._recipient = recipient;
            args._routerAddr = routerAddr;
            
        LiquidityPair memory pair;

        if (args._in == IUniswapV2Pair(args._out).token0() || args._in == IUniswapV2Pair(args._out).token1()) { 

            args._token = args._in == IUniswapV2Pair(args._out).token0() ? IUniswapV2Pair(args._out).token1() : IUniswapV2Pair(args._out).token0();
            // calculate args._amount of _in to sell
            args._swapAmt = args._amount.div(2);
            args._otherAmt = _swap(args._in, args._swapAmt, args._token, address(this), args._routerAddr);
            _approveTokenIfNeeded(args._token, args._routerAddr);
            // execute swap
           
            (pair._amountToken0 , pair._amountToken1 , pair._liqTokenAmt) = 
            IUniswapV2Router(args._routerAddr).addLiquidity(
                args._in, 
                args._token, 
                args._amount.sub(args._swapAmt), 
                args._otherAmt, 
                args._swapAmt , 
                args._otherAmt, 
                args._recipient, 
                block.timestamp);
            
            if (args._in == IUniswapV2Pair(args._out).token0()) {
                _dustDistribution(  args._swapAmt, 
                                    args._otherAmt, 
                                    pair._amountToken0, 
                                    pair._amountToken1, 
                                    args._in, 
                                    args._token, 
                                    args._recipient);

            } else {
                 _dustDistribution( args._otherAmt, 
                                    args._swapAmt, 
                                    pair._amountToken1, 
                                    pair._amountToken0, 
                                    args._in, 
                                    args._token, 
                                    args._recipient);
            }
            return pair._liqTokenAmt;
        } else {
            // go through native token for highest liquidity
            uint256 nativeAmount = _swapTokenForNative(args._in, args._amount, address(this), args._routerAddr);
            return _swapNativeToLP(args._out, nativeAmount, args._recipient, args._routerAddr);
        }
    }
    
    // @amount - amount of our native token
    // @out - LP we want to get
    function _swapNativeToLP(address out, uint256 amount, address recipient, address routerAddress) private returns (uint256) {
        
        IUniswapV2Pair pair = IUniswapV2Pair(out);
        address token0 = pair.token0();  
        address token1 = pair.token1();  
        uint256 liquidity;

        liquidity = _swapNativeToEqualTokensAndProvide(token0, token1, amount, routerAddress, recipient);
        return liquidity;
    }

    function _dustDistribution(uint256 token0, uint256 token1, uint256 amountToken0, uint256 amountToken1, address native, address token, address recipient) private {
        uint256 nativeDust = token0.sub(amountToken0);
        uint256 tokenDust = token1.sub(amountToken1);
        if (nativeDust > 0) {
            IERC20(native).safeTransfer(recipient, nativeDust);
        }
        if (tokenDust > 0) {
            IERC20(token).safeTransfer(recipient, tokenDust);
        }

    }
    // @token0 - swap Native to this , and provide this to create LP
    // @token1 - swap Native to this , and provide this to create LP
    // @amount - amount of native token
    function _swapNativeToEqualTokensAndProvide(address token0, address token1, uint256 amount, address routerAddress, address recipient) private returns (uint256) {
        FunctionArgs memory args;
        args._amount = amount;
        args._recipient = recipient;
        args._routerAddr = routerAddress;
       
        args._swapAmt = args._amount.div(2);

        LiquidityPair memory pair;
        pair._token0 = token0;
        pair._token1 = token1;

        IUniswapV2Router router = IUniswapV2Router(args._routerAddr);

        if (pair._token0 == NATIVE) {
            args._otherAmt= _swapNativeForToken(pair._token1, args._swapAmt, address(this), args._routerAddr);
            _approveTokenIfNeeded(pair._token0, args._routerAddr);
            _approveTokenIfNeeded(pair._token1, args._routerAddr);

            (pair._amountToken0, pair._amountToken1, pair._liqTokenAmt) = 
            router.addLiquidity(    pair._token0, 
                                    pair._token1, 
                                    args._swapAmt, 
                                    args._otherAmt, 
                                    args._swapAmt, 
                                    args._otherAmt, 
                                    args._recipient, 
                                    block.timestamp);
            _dustDistribution(  args._swapAmt, 
                                args._otherAmt, 
                                pair._amountToken0, 
                                pair._amountToken1, 
                                pair._token0, 
                                pair._token1, 
                                args._recipient);
            return pair._liqTokenAmt;
        } else {
            args._otherAmt = _swapNativeForToken(pair._token0,  args._swapAmt, address(this), args._routerAddr);
            _approveTokenIfNeeded( pair._token0, args._routerAddr);
            _approveTokenIfNeeded( pair._token1, args._routerAddr);

            (pair._amountToken0, pair._amountToken1, pair._liqTokenAmt) = 
            router.addLiquidity(pair._token0, 
                                pair._token1, 
                                args._otherAmt, 
                                args._swapAmt, 
                                args._otherAmt, 
                                args._swapAmt, 
                                args._recipient, 
                                block.timestamp);
            _dustDistribution(  args._otherAmt, 
                                args._swapAmt, 
                                pair._amountToken1, 
                                pair._amountToken0,  
                                pair._token1, 
                                pair._token0, 
                                args._recipient);
            return pair._liqTokenAmt;
        }
    }
    // @token - swap Native to this token
    // @amount - amount of native token
    function _swapNativeForToken(address token, uint256 amount, address recipient, address routerAddr) private returns (uint256) {
        address[] memory path;
        IUniswapV2Router router = IUniswapV2Router(routerAddr);

        if (tokenBridgeForRouter[token][routerAddr] != address(0)) {
            path = new address[](3);
            path[0] = NATIVE;
            path[1] = tokenBridgeForRouter[token][routerAddr];
            path[2] = token;
        } else {
            path = new address[](2);
            path[0] = NATIVE;
            path[1] = token;
        }
        uint256 tokenAmt = _estimateSwap(NATIVE, amount, token, routerAddr);
        uint256[] memory amounts = router.swapExactTokensForTokens(amount, tokenAmt, path, recipient, block.timestamp);
        return amounts[amounts.length - 1];
    }
     // @token - swap this token to Native
    // @amount - amount of native token
    function _swapTokenForNative(address token, uint256 amount, address recipient, address routerAddr) private returns (uint256) {
        address[] memory path;
        IUniswapV2Router router = IUniswapV2Router(routerAddr);

        if (tokenBridgeForRouter[token][routerAddr] != address(0)) {
            path = new address[](3);
            path[0] = token;
            path[1] = tokenBridgeForRouter[token][routerAddr];
            path[2] = NATIVE;
        } else {
            path = new address[](2);
            path[0] = token;
            path[1] = NATIVE;
        }

        uint256 tokenAmt = _estimateSwap(token, amount, NATIVE, routerAddr);
        uint256[] memory amounts = router.swapExactTokensForTokens(amount, tokenAmt, path, recipient, block.timestamp);
        return amounts[amounts.length - 1];
    }

      // @in - token we want to throw in
    // @amount - amount of our token
    // @out - token we want to get
    function swapToken(address _in, uint256 amount, address out, address routerAddr, address _recipient, uint256 minAmountOut) private {
        IERC20(_in).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_in, routerAddr);
       uint256 tokensOut =  _swap(_in, amount, out, _recipient, routerAddr);
       require (tokensOut >= minAmountOut);
    }
    
     // @in - token we want to throw in
    // @amount - amount of our token
    
    function swapToNative(address _in, uint256 amount, address routerAddr, address _recipient, uint256 minAmountOut) private {
        IERC20(_in).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_in, routerAddr);
        uint256 amountNative = _swapTokenForNative(_in, amount, _recipient, routerAddr);
        require (amountNative >= minAmountOut);
    }
    
   


    /* ========== RESTRICTED FUNCTIONS ========== */

    function setNativeToken(address _NATIVE) external onlyOwner {
        NATIVE = _NATIVE;
    }

    function setTokenBridgeForRouter(address token, address router, address bridgeToken) external onlyOwner {
        tokenBridgeForRouter[token][router] = bridgeToken;
    }

    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(address(this).balance);
            return;
        }

        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    function setUseNativeRouter(address router) external onlyOwner {
        useNativeRouter[router] = true;
    }

    function removeNativeRouter(address router) external onlyOwner {
        useNativeRouter[router] = false;
    }
}