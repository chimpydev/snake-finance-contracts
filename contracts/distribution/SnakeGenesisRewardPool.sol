// SPDX-License-Identifier: BUSL-1.1

// SnakeGenesisRewardPool --> visit https://snake.finance/ for full experience
// Made by Kell

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IBasisAsset.sol";

import "../shadow/interfaces/IGauge.sol";
import "../shadow/interfaces/IVoter.sol";

contract SnakeGenesisRewardPool is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct GaugeInfo {
        bool isGauge;   // If this is a gauge
        IGauge gauge;  // The gauge
        address[] rewardTokens; // tokens that are used in the gauge
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 depFee; // deposit fee that is applied to created pool.
        uint256 allocPoint; // How many allocation points assigned to this pool. SNAKEs to distribute per block.
        uint256 lastRewardTime; // Last time that SNAKEs distribution occurs.
        uint256 accSnakePerShare; // Accumulated SNAKEs per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
        GaugeInfo gaugeInfo; // Gauge info (does this pool have a gauge and where is it)
        uint256 poolSnakePerSec; // rewards per second for pool (acts as allocPoint)
    }
    
    IERC20 public snake;
    IVoter public voter;
    address public xSHADOW = 0x5050bc082FF4A74Fb6B0B04385dEfdDB114b2424;
    address public bribesSafe;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when SNAKE mining starts.
    uint256 public poolStartTime;

    // The time when SNAKE mining ends.
    uint256 public poolEndTime;
    uint256 public snakePerSecond = 0 ether;
    uint256 public runningTime = 7 days;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _snake,
        address _bribesSafe,
        uint256 _poolStartTime,
        address _voter
    ) {
        require(block.timestamp < _poolStartTime, "pool cant be started in the past");
        if (_snake != address(0)) snake = IERC20(_snake);
        if(_bribesSafe != address(0)) bribesSafe = _bribesSafe;

        poolStartTime = _poolStartTime;
        poolEndTime = _poolStartTime + runningTime;
        operator = msg.sender;
        voter = IVoter(_voter);
        bribesSafe = _bribesSafe;

        // create all the pools
        add(0.231481481481481000 ether, 0, IERC20(0x287c6882dE298665977787e268f3dba052A6e251), false, 0); // Snake-S
        add(0.173611111111111000 ether, 100, IERC20(0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38), false, 0); // S
        add(0.115740740740741000 ether, 100, IERC20(0x29219dd400f2Bf60E5a23d13Be72B486D4038894), false, 0); // USDC.e
        add(0.115740740740741000 ether, 100, IERC20(0x50c42dEAcD8Fc9773493ED674b675bE577f2634b), false, 0); // WETH
        add(0.023148148148148100 ether, 100, IERC20(0x3333b97138D4b086720b5aE8A7844b1345a33333), false, 0); // SHADOW
        add(0.023148148148148100 ether, 100, IERC20(0x79bbF4508B1391af3A0F4B30bb5FC4aa9ab0E07C), false, 0); // ANON
        add(0.092592592592592600 ether, 100, IERC20(0xd3DCe716f3eF535C5Ff8d041c1A41C3bd89b97aE), false, 0); // scUSD
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "SnakeGenesisRewardPool: caller is not the operator");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "SnakeGenesisRewardPool: existing pool?");
        }
    }

    // bulk add pools
    function addBulk(uint256[] calldata _allocPoints, uint256[] calldata _depFees, IERC20[] calldata _tokens, bool _withUpdate, uint256 _lastRewardTime) external onlyOperator {
        require(_allocPoints.length == _depFees.length && _allocPoints.length == _tokens.length, "SnakeGenesisRewardPool: invalid length");
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
        address[] memory rewardTokensGauge = new address[](1);
        rewardTokensGauge[0] = xSHADOW;
        poolInfo.push(PoolInfo({
            token: _token,
            depFee: _depFee,
            allocPoint: _allocPoint,
            poolSnakePerSec: _allocPoint,
            lastRewardTime: _lastRewardTime,
            accSnakePerShare: 0,
            isStarted: _isStarted,
            gaugeInfo: GaugeInfo(false, IGauge(address(0)), rewardTokensGauge)
        }));
        enableGauge(poolInfo.length - 1);
        
        
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
            snakePerSecond = snakePerSecond.add(_allocPoint);
        }
    }

    // Update the given pool's SNAKE allocation point. Can only be called by the operator.
    function set(uint256 _pid, uint256 _allocPoint, uint256 _depFee) public onlyOperator {
        massUpdatePools();

        PoolInfo storage pool = poolInfo[_pid];
        require(_depFee < 200);  // deposit fee cant be more than 2%;
        pool.depFee = _depFee;

        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
            snakePerSecond = snakePerSecond.sub(pool.poolSnakePerSec).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
        pool.poolSnakePerSec = _allocPoint;
    }

    function bulkSet(uint256[] calldata _pids, uint256[] calldata _allocPoints, uint256[] calldata _depFees) external onlyOperator {
        require(_pids.length == _allocPoints.length && _pids.length == _depFees.length, "SnakeGenesisRewardPool: invalid length");
        for (uint256 i = 0; i < _pids.length; i++) {
            set(_pids[i], _allocPoints[i], _depFees[i]);
        }
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(snakePerSecond);
            return poolEndTime.sub(_fromTime).mul(snakePerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(snakePerSecond);
            return _toTime.sub(_fromTime).mul(snakePerSecond);
        }
    }

    // View function to see pending SNAKEs on frontend.
    function pendingSNAKE(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSnakePerShare = pool.accSnakePerShare;
        uint256 tokenSupply = pool.gaugeInfo.isGauge ? pool.gaugeInfo.gauge.balanceOf(address(this)) : pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _snakeReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accSnakePerShare = accSnakePerShare.add(_snakeReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accSnakePerShare).div(1e18).sub(user.rewardDebt);
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
        require(_fromPid <= _toPid, "SnakeGenesisRewardPool: invalid range");
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
            snakePerSecond = snakePerSecond.add(pool.poolSnakePerSec);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _snakeReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accSnakePerShare = pool.accSnakePerShare.add(_snakeReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
        claimLegacyRewards(_pid);
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
                pool.gaugeInfo.gauge.depositFor(address(this), balance);
            }
        }
    }

    // Claim rewards to treasury
    function claimLegacyRewards(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.gaugeInfo.isGauge) {
            if (pool.gaugeInfo.rewardTokens.length > 0) {     

                uint256[] memory beforeBalances = new uint256[](pool.gaugeInfo.rewardTokens.length);

                // Store balances before claim
                for (uint256 i = 0; i < pool.gaugeInfo.rewardTokens.length; i++) {
                    beforeBalances[i] = IERC20(pool.gaugeInfo.rewardTokens[i]).balanceOf(address(this));
                }

                address[] memory gaugesToCheck = new address[](1);
                gaugesToCheck[0] = address(pool.gaugeInfo.gauge);
                
                address[][] memory gaugeRewardTokens = new address[][](1);
                gaugeRewardTokens[0] = pool.gaugeInfo.rewardTokens;
                
                voter.claimRewards(gaugesToCheck, gaugeRewardTokens);

                for (uint256 i = 0; i < pool.gaugeInfo.rewardTokens.length; i++) {
                    IERC20 rewardToken = IERC20(pool.gaugeInfo.rewardTokens[i]);
                    uint256 afterBalance = rewardToken.balanceOf(address(this));
                    uint256 rewardAmount = afterBalance - beforeBalances[i];

                    if (rewardAmount > 0) {
                        rewardToken.safeTransfer(bribesSafe, rewardAmount);
                    }
                }
            }
        }
    }

    // Add a gauge to a pool
    function enableGauge(uint256 _pid) public onlyOperator {
        address gauge = voter.gaugeForPool(address(poolInfo[_pid].token));
        if (gauge != address(0)) {
            address[] memory rewardTokensGauge = new address[](1);
            rewardTokensGauge[0] = xSHADOW;
            poolInfo[_pid].gaugeInfo = GaugeInfo(true, IGauge(gauge), rewardTokensGauge);
        }
    }

    function setGaugeRewardTokens(uint256 _pid, address[] calldata _rewardTokens) public onlyOperator {
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.gaugeInfo.isGauge, "SnakeGenesisRewardPool: not a gauge pool");
        pool.gaugeInfo.rewardTokens = _rewardTokens;
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
            pool.gaugeInfo.gauge.withdraw(_amount);
        }
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accSnakePerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeSnakeTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0 ) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            uint256 depositDebt = _amount.mul(pool.depFee).div(10000);
            user.amount = user.amount.add(_amount.sub(depositDebt));
            pool.token.safeTransfer(bribesSafe, depositDebt);
        }
        updatePoolWithGaugeDeposit(_pid);
        user.rewardDebt = user.amount.mul(pool.accSnakePerShare).div(1e18);
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
        uint256 _pending = user.amount.mul(pool.accSnakePerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeSnakeTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            withdrawFromGauge(_pid, _amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSnakePerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        withdrawFromGauge(_pid, _amount);
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe snake transfer function, just in case if rounding error causes pool to not have enough SNAKEs.
    function safeSnakeTransfer(address _to, uint256 _amount) internal {
        uint256 _snakeBal = snake.balanceOf(address(this));
        if (_snakeBal > 0) {
            if (_amount > _snakeBal) {
                snake.safeTransfer(_to, _snakeBal);
            } else {
                snake.safeTransfer(_to, _amount);
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
