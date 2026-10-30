// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "../src/ABIEncoderDemo.sol";

/**
 * @title YieldFarmingPlus
 */
contract YieldFarmingPlus is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Structure to store pool information
    struct Pool {
        address token;
        uint256 totalStaked;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        bool isActive;
    }

    // Structure to store user information
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastClaimTime;
    }

    //Reward token
    IERC20 public immutable rewardToken;

    // External contract that builds the packed identifiers (ABIEncoderDemo)
    ABIEncoderDemo public immutable encoder;

    // Mapping of pools by their unique identifier
    mapping(bytes32 => Pool) public pools;

    // Mapping of user information by pool and address
    mapping(bytes32 => mapping(address => UserInfo)) public userInfo;

    // Position of each active pool inside activePools, used to remove a pool without looping
    mapping(bytes32 => uint256) private activePoolIndex;

    // Total amount staked per token, summed across all pools that use that token
    mapping(address => uint256) public totalStakedByToken;

    // Rewards a user earned but could not be paid because the reserve was short
    mapping(address => uint256) public owedRewards;

    // List of pools that are currently active
    bytes32[] public activePools;

    // Events
    event PoolCreated(bytes32 indexed poolId, address indexed token, uint256 rewardRate);
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate);
    event PoolClosed(bytes32 indexed poolId);
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    event RewardClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);
    event RewardShortfall(address indexed user, uint256 amount);
    event OwedRewardsClaimed(address indexed user, uint256 amount);
    event SurplusRecovered(address indexed token, uint256 amount);

    /**
     * @dev Contract constructor
     * @param _rewardToken Address of the reward token
     */
    constructor(address _rewardToken) Ownable(msg.sender) {
        require(_rewardToken != address(0), "Invalid reward token");
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @dev Puses deposits, Withdrawals and claims keep working
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Resumes deposits
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Creates a new yield farming pool
     * @param token Address of the token to stake
     * @param rewardRate Reward rate per second
     * @return poolId Unique pool identifier, built by the encoder contract
     */
    function createPool(address token, uint256 rewardRate) external onlyOwner returns (bytes32 poolId) {
        require(token != address(0), "Invalid token address");
        require(rewardRate > 0, "Reward rate must be positive");

        poolId = encoder.createFarmingPoolId(token, rewardRate);

        require(pools[poolId].token == address(0), "Pool already exists");

        pools[poolId] = Pool({
            token: token,
            totalStaked: 0,
            rewardRate: rewardRate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            isActive: true
        });

        activePoolIndex[poolId] = activePools.length;
        activePools.push(poolId);

        emit PoolCreated(poolId, token, rewardRate);
    }

    /**
     * @dev Update the pool state
     * @param poolId Pool Identifier
     */
    function _updatePool(bytes32 poolId) internal {
        Pool storage pool = pools[poolId];

        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 rewards = timeElapsed * pool.rewardRate;
            pool.rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
        }

        pool.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Calculate the pending rewards of a user
     * @param poolId Pool Identifier
     * @param user User address
     * @return Amount of pending rewards
     */
    function _calculatePendingRewards(bytes32 poolId, address user) internal view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage userInfoData = userInfo[poolId][user];

        uint256 rewardPerTokenStored = pool.rewardPerTokenStored;

        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 rewards = timeElapsed * pool.rewardRate;
            rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
        }

        return userInfoData.amount * rewardPerTokenStored / 1e18 - userInfoData.rewardDebt;
    }

    /**
     * @dev Pays rewards from the reserve, If the reserve cannot cover the full amount,pays what it has
     * and record the difference as owed to the user
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeRewardTransfer(address to, uint256 amount) internal {
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        uint256 paid = amount > rewardBalance ? rewardBalance : amount;

        if (amount > paid) {
            owedRewards[to] += amount - paid;
            emit RewardShortfall(to, amount - paid);
        }
        if (paid > 0) {
            rewardToken.safeTransfer(to, paid);
        }
    }

    /**
     * @dev Closes a pool: stops deposits and removes it from the active list.
     * Users can still withdraw and claim
     * @param poolId Pool Identifier
     */
    function closePool(bytes32 poolId) external onlyOwner {
        Pool storage pool = pools[poolId];

        require(pool.isActive, "Pool is not active");

        _updatePool(poolId);

        pool.rewardRate = 0;
        pool.isActive = false;

        uint256 index = activePoolIndex[poolId];
        uint256 lastIndex = activePools.length - 1;

        if (index != lastIndex) {
            bytes32 lastPoolId = activePools[lastIndex];
            activePools[index] = lastPoolId;
            activePoolIndex[lastPoolId] = index;
        }

        activePools.pop();
        delete activePoolIndex[poolId];

        emit PoolClosed(poolId);
    }

    /**
     * @dev Stake tokens in a specific pool
     * @param poolId Pool Identifier
     * @param amount Amount of token to stake
     */
    function stake(bytes32 poolId, uint256 amount) external nonReentrant whenNotPaused {
        Pool storage pool = pools[poolId];

        require(pool.isActive, "Pool is not active");
        require(amount > 0, "Amount must be positive");

        _updatePool(poolId);

        UserInfo storage user = userInfo[poolId][msg.sender];

        if (user.amount > 0) {
            uint256 pending = _calculatePendingRewards(poolId, msg.sender);
            if (pending > 0) {
                _safeRewardTransfer(msg.sender, pending);
                emit RewardClaimed(poolId, msg.sender, pending);
            }
        }

        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);

        user.amount += amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;

        pool.totalStaked += amount;
        totalStakedByToken[pool.token] += amount;

        emit Staked(poolId, msg.sender, amount);
    }

    /**
     * @dev Withdraw staked tokens from a pool
     * @param poolId Pool Identifier
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][msg.sender];

        require(user.amount >= amount, "Insufficient staked amount");

        _updatePool(poolId);

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        if (pending > 0) {
            _safeRewardTransfer(msg.sender, pending);
            emit RewardClaimed(poolId, msg.sender, pending);
        }

        user.amount -= amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;

        pool.totalStaked -= amount;

        totalStakedByToken[pool.token] -= amount;

        IERC20(pool.token).safeTransfer(msg.sender, amount);

        emit Withdrawn(poolId, msg.sender, amount);
    }

    /**
     * @dev Claim pending rewards
     * @param poolId Pool Identifier
     */
    function claimRewards(bytes32 poolId) external nonReentrant {
        _updatePool(poolId);

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        require(pending > 0, "No rewards to claim");

        UserInfo storage user = userInfo[poolId][msg.sender];
        user.rewardDebt = user.amount * pools[poolId].rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;

        _safeRewardTransfer(msg.sender, pending);

        emit RewardClaimed(poolId, msg.sender, pending);
    }

    /**
     * @dev Claims the rewards that were owed to the caller because the contract
     * lacked reward tokens at the time
     */
    function claimOwedRewards() external nonReentrant {
        uint256 owed = owedRewards[msg.sender];
        require(owed > 0, "No owed rewards");

        owedRewards[msg.sender] = 0;

        _safeRewardTransfer(msg.sender, owed);

        emit OwedRewardsClaimed(msg.sender, owed);
    }

    /**
     * @dev Updates the reward rate of an active pool
     * @param poolId Pool Identifier
     * @param newRewardRate New reward rate per second
     */
    function updatePoolRewardRate(bytes32 poolId, uint256 newRewardRate) external onlyOwner {
        Pool storage pool = pools[poolId];

        require(pool.isActive, "Pool is not active");

        _updatePool(poolId);

        pool.rewardRate = newRewardRate;

        emit PoolUpdated(poolId, newRewardRate);
    }

    /**
     * @dev Calculate the pending rewards of a user
     * @param poolId Pool Identifier
     * @param user User address
     * @return Amount of pending rewards
     */
    function pendingRewards(bytes32 poolId, address user) external view returns (uint256) {
        return _calculatePendingRewards(poolId, user);
    }

    /**
     * @dev Get encoded pool information for external use
     * @param poolId Pool Identifier
     * @return encodedData Encoded pool data
     */
    function getPoolEncodedData(bytes32 poolId) external view returns (bytes memory encodedData) {
        Pool storage pool = pools[poolId];

        encodedData = encoder.encodePoolData(
            pool.token, pool.totalStaked, pool.rewardRate, pool.lastUpdateTime, pool.rewardPerTokenStored, pool.isActive
        );
    }

    /**
     * @dev Returns a unique position identifier for a user in a pool
     * @param poolId Pool Identifier
     * @param user Address user
     * @return positionId Unique identifier of the user's position
     */
    function getUserPositionId(bytes32 poolId, address user) external view returns (bytes32 positionId) {
        UserInfo storage userInfoData = userInfo[poolId][user];

        positionId = encoder.encodeYieldPosition(user, poolId, userInfoData.amount, userInfoData.lastClaimTime);
    }

    /**
     * @dev Returns a single hash that represents a user across several pools
     * @param user Address user
     * @param poolIds Pool Identifiers
     * @return userHash Hash of the user across the given pools
     */
    function getUserMultiPoolHash(address user, bytes32[] calldata poolIds) external view returns (bytes32 userHash) {
        userHash = encoder.createUserMultiPoolHash(user, poolIds);
    }
}
