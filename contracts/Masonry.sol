// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";
import "./owner/Operator.sol";

contract ShareWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public share;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        share.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        uint256 masonUserShare = _balances[msg.sender];
        require(masonUserShare >= amount, "Masonry: withdraw request greater than staked amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = masonUserShare.sub(amount);
        share.safeTransfer(msg.sender, amount);
    }
}

/*
__________                             .___   ___________.__
\______   \_____     ______  ____    __| _/   \_   _____/|__|  ____  _____     ____    ____   ____
 |    |  _/\__  \   /  ___/_/ __ \  / __ |     |    __)  |  | /    \ \__  \   /    \ _/ ___\_/ __ \
 |    |   \ / __ \_ \___ \ \  ___/ / /_/ |     |     \   |  ||   |  \ / __ \_|   |  \\  \___\  ___/
 |______  /(____  //____  > \___  >\____ |     \___  /   |__||___|  /(____  /|___|  / \___  >\___  >
        \/      \/      \/      \/      \/         \/             \/      \/      \/      \/     \/
*/
contract Masonry is ShareWrapper, ContractGuard, Operator {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct MasonSeat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct MasonrySnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // flags
    bool public initialized = false;

    IERC20 public snake;
    ITreasury public treasury;

    mapping(address => MasonSeat) public masons;
    MasonrySnapshot[] public masonryHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;
    uint256 public claimRewardsBurnEpochs;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier masonUserExists {
        require(balanceOf(msg.sender) > 0, "Masonry: The masonUser does not exist");
        _;
    }

    modifier updateReward(address masonUser) {
        if (masonUser != address(0)) {
            MasonSeat memory seat = masons[masonUser];
            seat.rewardEarned = earned(masonUser);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            masons[masonUser] = seat;
        }
        _;
    }

    modifier notInitialized {
        require(!initialized, "Masonry: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _snake,
        IERC20 _share,
        ITreasury _treasury
    ) public notInitialized onlyOperator {
        snake = _snake;
        share = _share;
        treasury = _treasury;

        MasonrySnapshot memory genesisSnapshot = MasonrySnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        masonryHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 4; // Lock for 4 epochs (24h) before release withdraw
        rewardLockupEpochs = 2; // Lock for 2 epochs (12h) before release claimReward
        claimRewardsBurnEpochs = 8; // if the masonUser doesn't claim rewards in 2 days, the rewards will be burned

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        transferOperator(_operator);
    }

    function renounceOperator() external onlyOperator {
        _renounceOperator();
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs, uin256 _claimRewardsBurnEpochs) external onlyOperator {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56 && _claimRewardsBurnEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        require(_withdrawLockupEpochs > 0 && _rewardLockupEpochs > 0 && _claimRewardsBurnEpochs > 0, "lockupEpochs must be greater than 0");
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
        claimRewardsBurnEpochs = _claimRewardsBurnEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters =========== //

    function latestSnapshotIndex() public view returns (uint256) {
        return masonryHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (MasonrySnapshot memory) {
        return masonryHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address masonUser) public view returns (uint256) {
        return masons[masonUser].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address masonUser) internal view returns (MasonrySnapshot memory) {
        return masonryHistory[getLastSnapshotIndexOf(masonUser)];
    }

    function canWithdraw(address masonUser) external view returns (bool) {
        return masons[masonUser].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address masonUser) external view returns (bool) {
        return masons[masonUser].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function rewardsWillBeBurned(address masonUser) external view returns (bool) {
        return masons[masonUser].epochTimerStart.add(claimRewardsBurnEpochs) <= treasury.epoch(); // if the masonUser doesn't claim rewards in 2 weeks, the rewards will be burned
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getSnakePrice() external view returns (uint256) {
        return treasury.getSnakePrice();
    }

    // =========== Users getters =========== //

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address masonUser) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(masonUser).rewardPerShare;

        return balanceOf(masonUser).mul(latestRPS.sub(storedRPS)).div(1e18).add(masons[masonUser].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Masonry: Cannot stake 0");
        super.stake(amount);
        masons[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override onlyOneBlock masonUserExists updateReward(msg.sender) {
        require(amount > 0, "Masonry: Cannot withdraw 0");
        require(masons[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Masonry: still in withdraw lockup");
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = masons[msg.sender].rewardEarned;
        if (reward > 0) {
            require(masons[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Masonry: still in reward lockup");
            bool willBurn = rewardsWillBeBurned(msg.sender);
            masons[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            masons[msg.sender].rewardEarned = 0;

            if (willBurn) {
                snake.burn(reward);
                emit RewardPaid(msg.sender, 0);
            } else {
                snake.safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, reward);
            }
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyOperator {
        require(amount > 0, "Masonry: Cannot allocate 0");
        require(totalSupply() > 0, "Masonry: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        MasonrySnapshot memory newSnapshot = MasonrySnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        masonryHistory.push(newSnapshot);

        snake.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(snake), "snake");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }
}
