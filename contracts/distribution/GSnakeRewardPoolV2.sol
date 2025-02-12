// SPDX-License-Identifier: BUSL-1.1

// GSnakeRewardPool --> visit https://snake.finance/ for full experience
// Made by Kell

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IBasisAsset.sol";

import "../shadow/interfaces/IGauge.sol";
import "../shadow/interfaces/IShadowVoter.sol";
import "../shadow/interfaces/ISwapxVoter.sol";

contract GSnakeRewardPool is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    enum GaugeDex {
        SHADOW,
        SWAPX
    }

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct GaugeInfo {
        bool isGauge;   // If this is a gauge
        GaugeDex gaugeDex; // Dex of the gauge
        address gauge;  // The gauge
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 depFee; // deposit fee that is applied to created pool.
        uint256 allocPoint; // How many allocation points assigned to this pool. GSNAKEs to distribute per block.
        uint256 lastRewardTime; // Last time that GSNAKEs distribution occurs.
        uint256 accGsnakePerShare; // Accumulated GSNAKEs per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
        GaugeInfo gaugeInfo; // Gauge info (does this pool have a gauge and where is it)
        uint256 poolGsnakePerSec; // rewards per second for pool (acts as allocPoint)
    }

    IERC20 public gsnake;
    IShadowVoter public shadowVoter;
    ISwapxVoter public swapxVoter;
    address public constant XSHADOW_TOKEN = 0x5050bc082FF4A74Fb6B0B04385dEfdDB114b2424;
    address public constant X33_TOKEN = 0x5050bc082FF4A74Fb6B0B04385dEfdDB114b2424;
    address public constant SWAPX_TOKEN = 0x5050bc082FF4A74Fb6B0B04385dEfdDB114b2424;
    address public bribesSafe;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Pending rewards for each user in each pool (pending rewards accrued since last deposit/withdrawal)
    mapping(uint256 => mapping(address => uint256)) public pendingRewards;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when GSNAKE mining starts.
    uint256 public poolStartTime;

    // The time when GSNAKE mining ends.
    uint256 public poolEndTime;
    uint256 public sharePerSecond = 0 ether;
    uint256 public runningTime = 730 days;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _gsnake,
        address _bribesSafe,
        uint256 _poolStartTime,
        address _shadowVoter,
        address _swapxVoter
    ) {
        require(block.timestamp < _poolStartTime, "pool cant be started in the past");
        if (_gsnake != address(0)) gsnake = IERC20(_gsnake);
        if(_bribesSafe != address(0)) bribesSafe = _bribesSafe;

        poolStartTime = _poolStartTime;
        poolEndTime = _poolStartTime + runningTime;
        operator = msg.sender;
        shadowVoter = IShadowVoter(_shadowVoter);
        swapxVoter = ISwapxVoter(_swapxVoter);
        bribesSafe = _bribesSafe;

        // create all the pools
        add(0.000570776255707763 ether, 0, IERC20(0x287c6882dE298665977787e268f3dba052A6e251), false, 0); // Snake-S
        add(0.000380517503805175 ether, 0, IERC20(0xb901D7316447C84f4417b8a8268E2822095051E6), false, 0); // GSnake-S
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "GSnakeRewardPool: caller is not the operator");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "GSnakeRewardPool: existing pool?");
        }
    }

    // bulk add pools
    function addBulk(uint256[] calldata _allocPoints, uint256[] calldata _depFees, IERC20[] calldata _tokens, bool _withUpdate, uint256 _lastRewardTime) external onlyOperator {
        require(_allocPoints.length == _depFees.length && _allocPoints.length == _tokens.length, "GSnakeRewardPool: invalid length");
        for (uint256 i = 0; i < _allocPoints.length; i++) {
            add(_allocPoints[i], _depFees[i], _tokens[i], _withUpdate, _lastRewardTime);
        }
    }

    // Add new lp to the pool. Can only be called by operator.
    function add(
        uint256 _allocPoint,
        uint256 _depFee,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) public onlyOperator {
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
            token: _token,
            depFee: _depFee,
            allocPoint: _allocPoint,
            poolGsnakePerSec: _allocPoint,
            lastRewardTime: _lastRewardTime,
            accGsnakePerShare: 0,
            isStarted: _isStarted,
            gaugeInfo: GaugeInfo(false, address(0))
        }));
        // enableGauge(poolInfo.length - 1);
        
        
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
            sharePerSecond = sharePerSecond.add(_allocPoint);
        }
    }

    // Update the given pool's GSNAKE allocation point. Can only be called by the operator.
    function set(uint256 _pid, uint256 _allocPoint, uint256 _depFee) public onlyOperator {
        massUpdatePools();

        PoolInfo storage pool = poolInfo[_pid];
        require(_depFee < 200);  // deposit fee cant be more than 2%;
        pool.depFee = _depFee;

        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
            sharePerSecond = sharePerSecond.sub(pool.poolGsnakePerSec).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
        pool.poolGsnakePerSec = _allocPoint;
    }

    function bulkSet(uint256[] calldata _pids, uint256[] calldata _allocPoints, uint256[] calldata _depFees) external onlyOperator {
        require(_pids.length == _allocPoints.length && _pids.length == _depFees.length, "GSnakeRewardPool: invalid length");
        for (uint256 i = 0; i < _pids.length; i++) {
            set(_pids[i], _allocPoints[i], _depFees[i]);
        }
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(sharePerSecond);
            return poolEndTime.sub(_fromTime).mul(sharePerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(sharePerSecond);
            return _toTime.sub(_fromTime).mul(sharePerSecond);
        }
    }

    // View function to see pending GSNAKEs on frontend.
    function pendingShare(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGsnakePerShare = pool.accGsnakePerShare;
        uint256 tokenSupply = pool.gaugeInfo.isGauge ? pool.gaugeInfo.gauge.balanceOf(address(this)) : pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _gsnakeReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accGsnakePerShare = accGsnakePerShare.add(_gsnakeReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accGsnakePerShare).div(1e18).sub(user.rewardDebt);
    }

    // View function to see pending GSNAKEs on frontend and any other pending rewards accumulated.
    function pendingShareAndPendingRewards(uint256 _pid, address _user) external view returns (uint256) {
        uint256 _pendingShare = pendingShare(_pid, _user);
        return _pendingShare.add(pendingRewards[_pid][_user]);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
            updatePoolWithGaugeDeposit(pid);
        }
    }

    // massUpdatePoolsInRange
    function massUpdatePoolsInRange(uint256 _fromPid, uint256 _toPid) public {
        require(_fromPid <= _toPid, "GSnakeRewardPool: invalid range");
        for (uint256 pid = _fromPid; pid <= _toPid; ++pid) {
            updatePool(pid);
            updatePoolWithGaugeDeposit(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) private {
        updatePoolWithGaugeDeposit(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.gaugeInfo.isGauge ? pool.gaugeInfo.gauge.balanceOf(address(this)) : pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
            sharePerSecond = sharePerSecond.add(pool.poolGsnakePerSec);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _gsnakeReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accGsnakePerShare = pool.accGsnakePerShare.add(_gsnakeReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
        claimAllRewards(_pid);
    }
    
    // Deposit LP tokens to earn rewards
    function updatePoolWithGaugeDeposit(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        address gauge = address(pool.gaugeInfo.gauge);
        uint256 balance = pool.token.balanceOf(address(this));
        // Do nothing if this pool doesn't have a gauge
        if (pool.gaugeInfo.isGauge) {
            // Do nothing if the LP token in the MC is empty
            if (balance > 0) {
                // Approve to the gauge
                if (pool.token.allowance(address(this), gauge) < balance ){
                    pool.token.approve(gauge, type(uint256).max);
                }
                // Deposit the LP in the gauge
                pool.gaugeInfo.gauge.deposit(balance); // NOTE: no need to check if gauge is shadow or swapx, because both have the same function
            }
        }
    }

    // Claim rewards to treasury
    function claimAllRewards(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.gaugeInfo.isGauge) {
            if (pool.gaugeInfo.gaugeDex == GaugeDex.SHADOW) {
                _claimShadowRewards(_pid);
            }
            if (pool.gaugeInfo.gaugeDex == GaugeDex.SWAPX) { 
                _claimSwapxRewards(_pid);
            }
        }
    }

    function _claimShadowRewards(uint256 _pid) internal {
        address[] memory gaugeRewardTokens = poolInfo.gaugeInfo.gauge.rewardsList();
        pool.gaugeInfo.gauge.getReward(address(this), gaugeRewardTokens);

        for (uint256 i = 0; i < gaugeRewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(gaugeRewardTokens[i]);
            uint256 rewardAmount = rewardToken.balanceOf(address(this));

            if (rewardAmount > 0) {
                if (address(rewardToken) == XSHADOW_TOKEN) {
                    _convertXShadow(rewardAmount);
                } else {
                    rewardToken.safeTransfer(bribesSafe, rewardAmount);
                }
            }
        }
    }

    function convertXShadow(uint256 _amount) public onlyOperator {
        _convertXShadow(_amount);
    }

    function _convertXShadow(uint256 _amount) internal {
        IERC20(XSHADOW_TOKEN).approve(address(X33_TOKEN), _amount); // approve xshadow to x33
        bool canMint = IX33(X33_TOKEN).isUnlocked();
        if (canMint) {
            IERC4626(X33_TOKEN).deposit(_amount, address(this)); // mint x33
            IERC20(X33_TOKEN).safeTransfer(bribesSafe, _amount); // send x33 to bribesSafe
        }
    }

    function _claimSwapxRewards(uint256 _pid) internal {
        poolInfo.gaugeInfo.gauge.getReward(); // claim the swapx rewards

        IERC20 rewardToken = IERC20(SWAPX_TOKEN);
        uint256 rewardAmount = rewardToken.balanceOf(address(this));
        if (rewardAmount > 0) {
            rewardToken.safeTransfer(bribesSafe, rewardAmount);
        }
    }

    // Add a gauge to a pool
    function enableGauge(uint256 _pid, GaugeDex _gaugeDex) public onlyOperator {
        if (_gaugeDex == GaugeDex.SHADOW) {
            _enableGaugeShadow(_pid);
        }
        if (_gaugeDex == GaugeDex.SWAPX) {
            _enableGaugeSwapX(_pid);
        }
    }

    function _enableGaugeShadow(uint256 _pid) internal {
        address gauge = shadowVoter.gaugeForPool(address(poolInfo[_pid].token));
        if (gauge != address(0)) {
            poolInfo[_pid].gaugeInfo = GaugeInfo(true, gauge);
        }
    }

    function _enableGaugeSwapX(uint256 _pid) internal {
        // Add the logic for swapx
        address gauge = swapxVoter.gauges(address(poolInfo[_pid].token));
        if (gauge != address(0)) {
            poolInfo[_pid].gaugeInfo = GaugeInfo(true, gauge);
        }
    }
    
    function setBribesSafe(address _bribesSafe) public onlyOperator {
        bribesSafe = _bribesSafe;
    }

    // Withdraw LP from the gauge
    function withdrawFromGauge(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        // Do nothing if this pool doesn't have a gauge
        if (pool.gaugeInfo.isGauge) {
            // Withdraw from the gauge
            pool.gaugeInfo.gauge.withdraw(_amount); // NOTE: no need to check if gauge is shadow or swapx, because both have the same function
        }
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accGsnakePerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                // safeGsnakeTransfer(_sender, _pending);
                // emit RewardPaid(_sender, _pending);
                pendingRewards[_pid][_sender] = pendingRewards[_pid][_sender].add(_pending); // TODO: check if this is correct
            }
        }
        if (_amount > 0 ) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            uint256 depositDebt = _amount.mul(pool.depFee).div(10000);
            user.amount = user.amount.add(_amount.sub(depositDebt));
            pool.token.safeTransfer(bribesSafe, depositDebt);
        }
        updatePoolWithGaugeDeposit(_pid);
        user.rewardDebt = user.amount.mul(pool.accGsnakePerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        updatePoolWithGaugeDeposit(_pid);
        uint256 _pending = user.amount.mul(pool.accGsnakePerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            // safeGsnakeTransfer(_sender, _pending);
            // emit RewardPaid(_sender, _pending);
            pendingRewards[_pid][_sender] = pendingRewards[_pid][_sender].add(_pending); // TODO: check if this is correct
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            withdrawFromGauge(_pid, _amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accGsnakePerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // TODO: check if this is correct
    // TODO: check if pendingrewards are not 0 before claiming or _pending > 0 is enough
    // TODO: add payment to claim
    function claimRewards(uint256 _pid) public nonReentrant { 
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];

        // Ensure rewards are updated
        updatePool(_pid);
        updatePoolWithGaugeDeposit(_pid);

        // Calculate the latest pending rewards
        uint256 _pending = user.amount.mul(pool.accGsnakePerShare).div(1e18).sub(user.rewardDebt);

        if (_pending > 0) {
            // Store the new pending rewards
            pendingRewards[_pid][_sender] = pendingRewards[_pid][_sender].add(_pending);
        }

        uint256 rewardsToClaim = pendingRewards[_pid][_sender];

        if (rewardsToClaim > 0) {
            pendingRewards[_pid][_sender] = 0;
            safeGsnakeTransfer(_sender, rewardsToClaim);
            emit RewardPaid(_sender, rewardsToClaim);
        }

        // Update the user’s reward debt
        user.rewardDebt = user.amount.mul(pool.accGsnakePerShare).div(1e18);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        withdrawFromGauge(_pid, _amount);
        pendingRewards[_pid][msg.sender] = 0;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe gsnake transfer function, just in case if rounding error causes pool to not have enough GSNAKEs.
    function safeGsnakeTransfer(address _to, uint256 _amount) internal {
        uint256 _gsnakeBal = gsnake.balanceOf(address(this));
        if (_gsnakeBal > 0) {
            if (_amount > _gsnakeBal) {
                gsnake.safeTransfer(_to, _gsnakeBal);
            } else {
                gsnake.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            require(_token != pool.token, "ShareRewardPool: Token cannot be pool token");
        }
        _token.safeTransfer(to, amount);
    }
}
