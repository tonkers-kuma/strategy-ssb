// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/MasterChef.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 internal constant weth = IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IBalancerVault public balancerVault;
    IBalancerPool public bpt;
    IERC20 public rewardToken;
    IAsset[] internal assets;
    SwapSteps internal swapSteps;
    uint256[] internal minAmountsOut;
    bytes32 public balancerPoolId;
    uint8 public numTokens;
    uint8 public tokenIndex;

    // masterchef
    IBeethovenxMasterChef internal masterChef;
    IAsset[] internal stakeAssets;
    IBalancerPool internal stakeBpt;
    uint internal stakeTokenIndex;
    uint internal stakePercentage;

    struct SwapSteps {
        bytes32[] poolIds;
        IAsset[] assets;
    }

    uint256 internal constant max = type(uint256).max;

    //1	    0.01%
    //5	    0.05%
    //10	0.1%
    //50	0.5%
    //100	1%
    //1000	10%
    //10000	100%
    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips
    uint256 public maxSingleDeposit;
    uint256 public minDepositPeriod; // seconds
    uint256 public lastDepositTime;
    uint256 internal masterChefPoolId;
    uint256 internal masterChefStakePoolId;
    uint256 internal constant basisOne = 10000;

    constructor(
        address _vault,
        address _balancerVault,
        address _balancerPool,
        address _masterChef,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod,
        uint256 _masterChefPoolId)
    public BaseStrategy(_vault){
        //        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);
        bpt = IBalancerPool(_balancerPool);
        balancerPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(balancerPoolId);
        numTokens = uint8(tokens.length);
        assets = new IAsset[](numTokens);
        tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < numTokens; i++) {
            if (tokens[i] == want) {
                tokenIndex = i;
            }
            assets[i] = IAsset(address(tokens[i]));
        }
        require(tokenIndex != type(uint8).max, "token not supported in pool!");

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleDeposit = _maxSingleDeposit.mul(10 ** uint256(ERC20(address(want)).decimals()));
        minAmountsOut = new uint256[](numTokens);
        minDepositPeriod = _minDepositPeriod;
        masterChefPoolId = _masterChefPoolId;
        masterChef = IBeethovenxMasterChef(_masterChef);
        require(masterChef.lpTokens(masterChefPoolId) == address(bpt), "Wrong MasterChef Pool!");

        want.safeApprove(address(balancerVault), max);
        bpt.approve(address(masterChef), max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return string(abi.encodePacked("SingleSidedBalancer ", bpt.symbol(), "Pool ", ERC20(address(want)).symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPooled());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        collectTradingFees();
        // claim beets
        claimRewards();

        // calc amount beets to stake
        uint256 toStake = balanceOfReward().mul(stakePercentage).div(basisOne);
        // unstake all staked beets
        unstake();
        // stake pre-calc amount of beets for higher apy
        stake(toStake);
        // sell the % not staking
        sellRewards();

        uint256 afterWant = balanceOfWant();

        _profit = afterWant.sub(beforeWant);
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now - lastDepositTime < minDepositPeriod) {
            return;
        }

        // put want into lp then put want-lp into masterchef
        uint256 pooledBefore = balanceOfPooled();
        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());
        if (joinPool(amountIn, assets, numTokens, tokenIndex, balancerPoolId)) {
            // put all want-lp into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));

            uint256 pooledDelta = balanceOfPooled().sub(pooledBefore);
            uint256 joinSlipped = amountIn > pooledDelta ? amountIn.sub(pooledDelta) : 0;
            uint256 maxLoss = amountIn.mul(maxSlippageIn).div(basisOne);
            require(joinSlipped <= maxLoss, "Exceeded maxSlippageIn!");
            lastDepositTime = now;
        }


        // claim all beets
        claimRewards();
        // and stake all
        stakeAllRewards();
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        if (estimatedTotalAssets() < _amountNeeded) {
            _liquidatedAmount = liquidateAllPositions();
            return (_liquidatedAmount, _amountNeeded.sub(_liquidatedAmount));
        }

        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            uint256 toExitAmount = _amountNeeded.sub(looseAmount);

            // withdraw all bpt out of masterchef
            masterChef.withdrawAndHarvest(masterChefPoolId, balanceOfBptInMasterChef(), address(this));
            // sell some bpt
            exitPoolExactToken(toExitAmount);
            // put remaining bpt back into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);

            _enforceSlippageOut(toExitAmount, _liquidatedAmount.sub(looseAmount));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 liquidated) {
        uint eta = estimatedTotalAssets();
        // withdraw all bpt out of masterchef
        masterChef.withdrawAndHarvest(masterChefPoolId, balanceOfBptInMasterChef(), address(this));
        // sell all bpt
        uint256 bpts = balanceOfBpt();
        if (bpts > 0) {
            // exit entire position for single token. Could revert due to single exit limit enforced by balancer
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, bpts, tokenIndex);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
            balancerVault.exitPool(balancerPoolId, address(this), address(this), request);
        }

        liquidated = balanceOfWant();
        _enforceSlippageOut(eta, liquidated);

        return liquidated;
    }

    function prepareMigration(address _newStrategy) internal override {
        masterChef.withdrawAndHarvest(masterChefPoolId, balanceOfBptInMasterChef(), address(_newStrategy));
        masterChef.withdrawAndHarvest(masterChefStakePoolId, balanceOfStakeBptInMasterChef(), address(_newStrategy));
        uint256 rewards = balanceOfReward();
        if (rewards > 0) {
            rewardToken.transfer(_newStrategy, rewards);
        }
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view override returns (uint256){}

    function tendTrigger(uint256 callCostInWei) public view override returns (bool) {
        return now.sub(lastDepositTime) > minDepositPeriod && balanceOfWant() > 0;
    }

    // HELPERS //

    // claim all beets rewards from masterchef
    function claimRewards() internal {
        masterChef.harvest(masterChefPoolId, address(this));
        masterChef.harvest(masterChefStakePoolId, address(this));
    }

    function sellRewards() internal {
        uint256 amount = balanceOfReward();
        uint decReward = ERC20(address(rewardToken)).decimals();
        uint decWant = ERC20(address(want)).decimals();

        if (amount > 10 ** (decReward > decWant ? decReward.sub(decWant) : 0)) {
            uint length = swapSteps.poolIds.length;
            IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](length);
            int[] memory limits = new int[](length + 1);
            limits[0] = int(amount);
            for (uint j = 0; j < length; j++) {
                steps[j] = IBalancerVault.BatchSwapStep(swapSteps.poolIds[j],
                    j,
                    j + 1,
                    j == 0 ? amount : 0,
                    abi.encode(0)
                );
            }
            balancerVault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN,
                steps,
                swapSteps.assets,
                IBalancerVault.FundManagement(address(this), false, address(this), false),
                limits,
                now + 10);
        }
    }

    function collectTradingFees() internal {
        uint256 total = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (total > debt) {
            uint256 profit = total.sub(debt);
            exitPoolExactToken(profit);
        }
    }

    function balanceOfWant() public view returns (uint256 _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfBpt() public view returns (uint256 _amount){
        return bpt.balanceOf(address(this));
    }

    function balanceOfBptInMasterChef() public view returns (uint256 _amount){
        (_amount,) = masterChef.userInfo(masterChefPoolId, address(this));
    }

    function balanceOfStakeBptInMasterChef() public view returns (uint256 _amount){
        (_amount,) = masterChef.userInfo(masterChefStakePoolId, address(this));
    }

    function balanceOfReward() public view returns (uint256 _amount){
        return rewardToken.balanceOf(address(this));
    }

    function balanceOfPendingReward() public view returns (uint256 _amount){
        return masterChef.pendingBeets(masterChefStakePoolId, address(this)).add(masterChef.pendingBeets(masterChefPoolId, address(this)));
    }

    function balanceOfPooled() public view returns (uint256 _amount){
        uint256 totalWantPooled;
        (IERC20[] memory tokens, uint256[] memory totalBalances, uint256 lastChangeBlock) = balancerVault.getPoolTokens(balancerPoolId);
        for (uint8 i = 0; i < numTokens; i++) {
            uint256 tokenPooled = totalBalances[i].mul(balanceOfBpt().add(balanceOfBptInMasterChef())).div(bpt.totalSupply());
            if (tokenPooled > 0) {
                IERC20 token = tokens[i];
                if (token != want) {
                    IBalancerPool.SwapRequest memory request = _getSwapRequest(token, tokenPooled, lastChangeBlock);
                    // now denomated in want
                    tokenPooled = bpt.onSwap(request, totalBalances, i, tokenIndex);
                }
                totalWantPooled += tokenPooled;
            }
        }
        return totalWantPooled;
    }

    function _getSwapRequest(IERC20 token, uint256 amount, uint256 lastChangeBlock) internal view returns (IBalancerPool.SwapRequest memory request){
        return IBalancerPool.SwapRequest(IBalancerPool.SwapKind.GIVEN_IN,
            token,
            want,
            amount,
            balancerPoolId,
            lastChangeBlock,
            address(this),
            address(this),
            abi.encode(0)
        );
    }

    function exitPoolExactToken(uint256 _amountTokenOut) internal {
        uint256[] memory amountsOut = new uint256[](numTokens);
        amountsOut[tokenIndex] = _amountTokenOut;
        bytes memory userData = abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfBpt());
        IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
        balancerVault.exitPool(balancerPoolId, address(this), address(this), request);
    }

    function joinPool(uint256 _amountIn, IAsset[] memory _assets, uint256 _numTokens, uint256 _tokenIndex, bytes32 _poolId) internal returns (bool _joined){
        uint256[] memory maxAmountsIn = new uint256[](_numTokens);
        maxAmountsIn[_tokenIndex] = _amountIn;
        if (_amountIn > 0) {
            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, 0);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(_assets, maxAmountsIn, userData, false);
            balancerVault.joinPool(_poolId, address(this), address(this), request);
            return true;
        }
        return false;
    }

    function whitelistReward(address _rewardToken, SwapSteps memory _steps) public onlyVaultManagers {
        rewardToken = IERC20(_rewardToken);
        rewardToken.approve(address(balancerVault), max);
        swapSteps = _steps;
    }

    function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut, uint256 _maxSingleDeposit, uint256 _minDepositPeriod) public onlyVaultManagers {
        require(_maxSlippageIn <= basisOne, "maxSlippageIn too high");
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne, "maxSlippageOut too high");
        maxSlippageOut = _maxSlippageOut;

        maxSingleDeposit = _maxSingleDeposit;
        minDepositPeriod = _minDepositPeriod;
    }

    function _enforceSlippageOut(uint _intended, uint _actual) internal view {
        // enforce that amount exited didn't slip beyond our tolerance
        // just in case there's positive slippage
        uint256 exitSlipped = _intended > _actual ? _intended.sub(_actual) : 0;
        uint256 maxLoss = _intended.mul(maxSlippageOut).div(basisOne);
        require(exitSlipped <= maxLoss, "Exceeded maxSlippageOut!");
    }

    function getSwapSteps() public view returns (SwapSteps memory){
        return swapSteps;
    }

    function setMasterChef(address _masterChef) public onlyVaultManagers {
        bpt.approve(address(masterChef), 0);
        stakeBpt.approve(address(masterChef), 0);
        masterChef = IBeethovenxMasterChef(_masterChef);
        bpt.approve(address(masterChef), max);
        stakeBpt.approve(address(masterChef), max);
    }

    // stake all beets
    function stakeAllRewards() internal {
        stake(balanceOfReward());
    }

    // stake beets into beets-lp, then beets-lp into masterchef
    function stake(uint256 _amount) internal {
        if (joinPool(_amount, stakeAssets, stakeAssets.length, stakeTokenIndex, stakeBpt.getPoolId())) {
            masterChef.deposit(masterChefStakePoolId, stakeBpt.balanceOf(address(this)), address(this));
        }
    }

    // unstake all beets-lp from masterchef, single sided withdraw all beets from beets-lp
    function unstake() internal {
        uint256 bpts = balanceOfStakeBptInMasterChef();
        masterChef.withdrawAndHarvest(masterChefStakePoolId, bpts, address(this));

        uint256[] memory minAmtsOut = new uint256[](stakeAssets.length);
        if (bpts > 0) {
            // exit all beets from beets pool. Don't care about slippage since it's rewards
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, bpts, stakeTokenIndex);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(stakeAssets, minAmtsOut, userData, false);
            balancerVault.exitPool(stakeBpt.getPoolId(), address(this), address(this), request);
        }
    }

    function setStakeParams(
        uint256 _stakePercentageBips,
        IAsset[] memory _stakeAssets,
        address _stakePool,
        uint256 _stakeTokenIndex,
        uint256 _masterChefStakePoolId
    ) public onlyVaultManagers {
        stakePercentage = _stakePercentageBips;
        stakeAssets = _stakeAssets;
        masterChefStakePoolId = _masterChefStakePoolId;
        stakeBpt = IBalancerPool(_stakePool);
        stakeBpt.approve(address(masterChef), max);
        stakeTokenIndex = _stakeTokenIndex;
    }

    receive() external payable {}
}

