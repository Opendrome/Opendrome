// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface minimale ERC20
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title StakingOPND - modèle type Liquity
/// @notice Les utilisateurs stakent OPND et reçoivent des rewards en OPND.
/// @dev Pas d'owner, pas d'admin, pas de périodes.
///      Chaque appel à distributeReward() répartit immédiatement les rewards
///      entre tous les stakers proportionnellement à leur stake.
///      Protection simple contre la réentrance.
contract StakingOPND {
    IERC20 public immutable stakingToken;   // OPND
    IERC20 public immutable rewardsToken;   // OPND (même adresse)

    uint256 public totalStaked;
    mapping(address => uint256) public balances; // montant staké par user

    // Reward cumulée par token staké, en 1e18 (style Synthetix / Liquity)
    uint256 public rewardPerTokenStored;

    // Pour chaque user : valeur de rewardPerToken déjà comptée
    mapping(address => uint256) public userRewardPerTokenPaid;

    // Rewards OPND accumulées pour chaque user (pas encore claim)
    mapping(address => uint256) public rewards;

    // --------- Reentrancy guard minimal ---------
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardDistributed(address indexed caller, uint256 reward, uint256 newRewardPerToken);

    constructor(address _stakingToken) {
        require(_stakingToken != address(0), "staking token zero");
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_stakingToken); // même token pour stake + reward
        _status = _NOT_ENTERED;
    }

    // --------- Modifiers ---------

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier updateReward(address account) {
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // --------- Vues ---------

    function earned(address account) public view returns (uint256) {
        uint256 userBalance = balances[account];
        if (userBalance == 0) {
            return rewards[account];
        }

        uint256 accumulatedPerToken = rewardPerTokenStored - userRewardPerTokenPaid[account];
        return rewards[account] + (userBalance * accumulatedPerToken) / 1e18;
    }

    function balanceOfStaked(address account) external view returns (uint256) {
        return balances[account];
    }

    // --------- Fonctions utilisateur ---------

    function stake(uint256 amount)
        external
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "cannot stake 0");

        totalStaked += amount;
        balances[msg.sender] += amount;

        require(
            stakingToken.transferFrom(msg.sender, address(this), amount),
            "stake transferFrom failed"
        );

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount)
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "cannot withdraw 0");
        require(balances[msg.sender] >= amount, "not enough staked");

        totalStaked -= amount;
        balances[msg.sender] -= amount;

        require(
            stakingToken.transfer(msg.sender, amount),
            "withdraw transfer failed"
        );

        emit Withdrawn(msg.sender, amount);
    }

    function exit() external nonReentrant {
        uint256 bal = balances[msg.sender];
        if (bal > 0) {
            withdraw(bal);
        }
        getReward();
    }

    function getReward()
        public
        nonReentrant
        updateReward(msg.sender)
    {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            require(
                rewardsToken.transfer(msg.sender, reward),
                "reward transfer failed"
            );
            emit RewardPaid(msg.sender, reward);
        }
    }

    // --------- Distribution des rewards ---------

    /// @notice Ajoute `reward` OPND au pool et les répartit immédiatement.
    /// @dev L'appelant doit avoir fait approve(stakingAddress, reward) sur OPND.
    function distributeReward(uint256 reward)
        external
        nonReentrant
    {
        require(reward > 0, "reward=0");
        require(totalStaked > 0, "no stakers");

        require(
            rewardsToken.transferFrom(msg.sender, address(this), reward),
            "reward transferFrom failed"
        );

        rewardPerTokenStored += (reward * 1e18) / totalStaked;

        emit RewardDistributed(msg.sender, reward, rewardPerTokenStored);
    }
}

