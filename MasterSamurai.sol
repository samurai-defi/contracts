pragma solidity 0.6.12;

import '@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol';

import "./SMRToken.sol";

// import "@nomiclabs/buidler/console.sol";

// MasterSamurai is the master of SMR.
// He can make Smr and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once SMR is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterSamurai is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SMRs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSmrPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSmrPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SMRs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that SMRs distribution occurs.
        uint256 accSmrPerShare; // Accumulated SMRs per share, times 1e12. See below.
        uint16 depositFeeBP;     // deposit Fee
    }

    struct Multiplier {
        uint256 bonus;
        uint256 startBlock;
    }

    // The SMR TOKEN!
    SmrToken public smr;
    // Dev address.
    address public devaddr;
    // SMR tokens created per block.
    uint256 public smrPerBlock;
    // Deposit Fee address
    address public feeAddress;

    // multiplier by block
    Multiplier[] public multiplierBlockUpdate;
    Multiplier public actualMultiplier;
    uint56 public lastMultiplierUpdateIndex;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when SMR mining starts.
    uint256 public startBlock;

    // Initial emission rate: 1 SMR per block.
    uint256 public immutable INITIAL_EMISSION_RATE;
    // Minimum emission rate: 0.1 SMR per block.
    uint256 public immutable MINIMUM_EMISSION_RATE;
    // Reduce emission every 9,600 blocks ~ 8 hours.
    uint256 public immutable EMISSION_REDUCTION_PERIOD_BLOCKS;
    // Emission reduction rate per period in basis points: 3%.
    uint256 public immutable EMISSION_REDUCTION_RATE_PER_PERIOD;
    // Last reduction period index
    uint256 public lastReductionPeriodIndex = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);

    constructor(
        SmrToken _smr,
        address _devaddr,
        address _feeAddress,
        uint256 _smrPerBlock,
        uint256 _startBlockDate,
        uint256 _multiplier
    ) public {
        smr = _smr;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        smrPerBlock = _smrPerBlock;
        setStartRewardsDate(_startBlockDate);
        multiplierBlockUpdate.push(Multiplier(_multiplier, 0));
        actualMultiplier = multiplierBlockUpdate[0];

        INITIAL_EMISSION_RATE = smrPerBlock;
        MINIMUM_EMISSION_RATE = 200 finney;
        EMISSION_REDUCTION_PERIOD_BLOCKS = 9600;
        EMISSION_REDUCTION_RATE_PER_PERIOD = 500;

        // staking pool
        poolInfo.push(PoolInfo({
            lpToken: _smr,
            allocPoint: 1000,
            lastRewardBlock: startBlock,
            accSmrPerShare: 0,
            depositFeeBP: 0
        }));

        totalAllocPoint = 1000;

    }

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }
    
    function updateMultiplierAtDate(uint256 multiplierNumber, uint256 date) public onlyOwner {
        require(date * 1 seconds > now, "Cannot update multiplier for passed date");
        // nb block before multiplier update (delayBlock) = (updateStartDate - now) / 3 seconds
        // multiplier update start at block = delayBlock + actual block number
        uint256 startUpdateAtBlock = (date * 1 seconds - now) / (3 * 1 seconds) + block.number;
        multiplierBlockUpdate.push(Multiplier(multiplierNumber, startUpdateAtBlock));
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (lastMultiplierUpdateIndex > 0 && _from < actualMultiplier.startBlock){
            uint256 rewards = actualMultiplier.startBlock.sub(_from).mul(multiplierBlockUpdate[lastMultiplierUpdateIndex -1].bonus);
            return rewards.add(_to.sub(actualMultiplier.startBlock).mul(actualMultiplier.bonus));
        }
        else {
            return _to.sub(_from).mul(actualMultiplier.bonus);
        }
    }

    function checkForMultiplierUpdate() internal{
        if (multiplierBlockUpdate.length > lastMultiplierUpdateIndex + 1){
            if (block.number >= multiplierBlockUpdate[lastMultiplierUpdateIndex + 1].startBlock){
                lastMultiplierUpdateIndex = lastMultiplierUpdateIndex +1;
                actualMultiplier = multiplierBlockUpdate[lastMultiplierUpdateIndex];
            }
        }
    }

    // Reduce emission rate by 3% every 9,600 blocks ~ 8hours
    function updateEmissionRate() internal {
        if(startBlock > 0 && block.number <= startBlock){
            return;
        }
        if(smrPerBlock <= MINIMUM_EMISSION_RATE){
            return;
        }

        uint256 currentIndex = block.number.sub(startBlock).div(EMISSION_REDUCTION_PERIOD_BLOCKS);
        if (currentIndex <= lastReductionPeriodIndex) {
            return;
        }

        uint256 newEmissionRate = smrPerBlock;
        for (uint256 index = lastReductionPeriodIndex; index < currentIndex; ++index) {
            newEmissionRate = newEmissionRate.mul(1e4 - EMISSION_REDUCTION_RATE_PER_PERIOD).div(1e4);
        }

        newEmissionRate = newEmissionRate < MINIMUM_EMISSION_RATE ? MINIMUM_EMISSION_RATE : newEmissionRate;
        if (newEmissionRate >= smrPerBlock) {
            return;
        }

        lastReductionPeriodIndex = currentIndex;
        uint256 previousEmissionRate = smrPerBlock;
        smrPerBlock = newEmissionRate;
        emit EmissionRateUpdated(msg.sender, previousEmissionRate, newEmissionRate);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Detects whether the given pool already exists
    function checkPoolDuplicate(IBEP20 _lpToken) public view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: existing pool");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        checkPoolDuplicate(_lpToken);
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accSmrPerShare: 0,
            depositFeeBP : _depositFeeBP
        }));
    }

    // Update the given pool's SMR allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }

    // View function to see pending SMRs on frontend.
    function pendingSmr(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSmrPerShare = pool.accSmrPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 smrReward = multiplier.mul(smrPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accSmrPerShare = accSmrPerShare.add(smrReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accSmrPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }


    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePool(_pid) {
        updateEmissionRate();
        checkForMultiplierUpdate();

        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 smrReward = multiplier.mul(smrPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        smr.mint(devaddr, smrReward.div(10));
        smr.mint(address(this), smrReward);
        pool.accSmrPerShare = pool.accSmrPerShare.add(smrReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterSamurai for SMR allocation.
    function deposit(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accSmrPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeSmrTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(smr)) {
                uint256 transferTax = _amount.mul(2).div(100);
                _amount = _amount.sub(transferTax);
            }
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accSmrPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterSamurai.
    function withdraw(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accSmrPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeSmrTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSmrPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    function getPoolInfo(uint256 _pid) public view
    returns(address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accSmrPerShare, uint16 depositFeeBP) {
        return (address(poolInfo[_pid].lpToken),
            poolInfo[_pid].allocPoint,
            poolInfo[_pid].lastRewardBlock,
            poolInfo[_pid].accSmrPerShare,
            poolInfo[_pid].depositFeeBP);
    }

    // Safe smr transfer function, just in case if rounding error causes pool to not have enough SMRs.
    function safeSmrTransfer(address _to, uint256 _amount) internal {
        uint256 smrBal = smr.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > smrBal) {
            transferSuccess = smr.transfer(_to, smrBal);
        } else {
            transferSuccess = smr.transfer(_to, _amount);
        }
        require(transferSuccess, "safeSailTransfer: Transfer failed");
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
    }

    function setStartRewardsDate(uint256 _startRewardsDate) public onlyOwner{
        require(startBlock == 0 || startBlock < block.number, "rewardsStartDate passed !");
        require(_startRewardsDate * 1 seconds >= now, "");
        startBlock = block.number.add((_startRewardsDate * 1 seconds - now).div(3 * 1 seconds));
    }
}
