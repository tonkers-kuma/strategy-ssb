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
import "../interfaces/IStakingLiquidityGauge.sol";
import "../interfaces/ILiquidityGaugeFactory.sol";
import "../interfaces/BalancerMinter.sol";


interface IName {
    function name() external view returns (string memory);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    modifier isVaultManager {
        checkVaultManagers();
        _;
    }

    function checkVaultManagers() internal {
        require(msg.sender == vault.governance() || msg.sender == vault.management());
    }

    IBalancerVault public balancerVault;
    IBalancerPool public bpt;
    ILiquidityGaugeFactory public gaugeFactory;
    IStakingLiquidityGauge public gauge;
    IBalancerMinter public minter;
    IERC20[] public rewardTokens;
    IAsset[] internal assets;
    SwapSteps[] internal swapSteps;
    bytes32 public balancerPoolId;
    uint8 public numTokens;
    uint8 public tokenIndex;
    Toggles public toggles;
    address public keep;
    uint256 public keepBips;

    struct Toggles {
        bool doSellRewards;
        bool doClaimRewards;
        bool doCollectTradingFees;
    }

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
    uint256 internal constant basisOne = 10000;
    IERC20 internal constant BAL = IERC20(0xba100000625a3754423978a60c9317c58a424e3D);

    constructor(
        address _vault,
        address _balancerVault,
        address _balancerPool,
        address _gaugeFactory,
        address _minter,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod)
    public BaseStrategy(_vault){
        _initializeStrat(_vault, _balancerVault, _balancerPool, _gaugeFactory, _minter, _maxSlippageIn, _maxSlippageOut, _maxSingleDeposit, _minDepositPeriod);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _balancerVault,
        address _balancerPool,
        address _gaugeFactory,
        address _minter,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_vault, _balancerVault, _balancerPool, _gaugeFactory, _minter, _maxSlippageIn, _maxSlippageOut, _maxSingleDeposit, _minDepositPeriod);
    }

    function _initializeStrat(
        address _vault,
        address _balancerVault,
        address _balancerPool,
        address _gaugeFactory,
        address _minter,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod)
    internal {
        // health.ychad.eth
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);
        bpt = IBalancerPool(_balancerPool);
        balancerPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(balancerPoolId);
        require(tokens.length > 0, "Empty Pool");
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
        minDepositPeriod = _minDepositPeriod;

        require(_gaugeFactory != address(0));
        gaugeFactory = ILiquidityGaugeFactory(_gaugeFactory);
        gauge = IStakingLiquidityGauge(gaugeFactory.getPoolGauge(address(bpt)));
        minter = IBalancerMinter(_minter);

        require(address(gauge) != address(0));
        require(address(gauge.lp_token()) == address(bpt));
        want.safeApprove(address(balancerVault), max);
        IERC20(bpt).safeApprove(address(gauge), max);

        toggles = Toggles({doSellRewards : true, doClaimRewards : true, doCollectTradingFees : true});

        keepBips = 1000;
        keep = governance();
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("SSBv3 ", ERC20(address(want)).symbol(), " ", bpt.symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPooled());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        // 2 forms of profit. Incentivized rewards (BAL+other) and pool fees (want)
        if (toggles.doCollectTradingFees) {
            _collectTradingFees();
        }
        // this would allow finer control over harvesting to get credits in without selling
        if (toggles.doClaimRewards) {
            _claimRewards();
        }
        if (toggles.doSellRewards) {
            _sellRewards();
        }

        uint256 afterWant = balanceOfWant();

        _profit = afterWant.sub(beforeWant);
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _debtPayment = _debtPayment.add(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _debtPayment = _debtPayment.add(_profit);
            _profit = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now.sub(lastDepositTime) < minDepositPeriod) {
            return;
        }

        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());
        uint256 expectedBptOut = tokensToBpts(amountIn).mul(basisOne.sub(maxSlippageIn)).div(basisOne);
        uint256[] memory maxAmountsIn = new uint256[](numTokens);
        maxAmountsIn[tokenIndex] = amountIn;

        if (amountIn > 0) {
            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, expectedBptOut);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
            balancerVault.joinPool(balancerPoolId, address(this), address(this), request);
            lastDepositTime = now;
        }

        uint256 _unstakedBpt = balanceOfUnstakedBpt();
        if (_unstakedBpt > 0) {
            _stakeBpt(_unstakedBpt);
        }
    }

    // withdraws will realize losses if the pool is in bad conditions. This will heavily rely on _enforceSlippage to revert
    // and make sure we don't have to realize losses when not necessary
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            uint256 toExitAmount = tokensToBpts(_amountNeeded.sub(looseAmount));

            uint256 _unstakedBpt = balanceOfUnstakedBpt();

            if (toExitAmount > _unstakedBpt) {
                _unstakeBpt(toExitAmount.sub(_unstakedBpt));
            }
            _sellBpt(toExitAmount);

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
        require(_amountNeeded == _liquidatedAmount.add(_loss), "!sanitycheck");
    }

    function liquidateAllPositions() internal override returns (uint256 liquidated) {
        _unstakeBpt(balanceOfStakedBpt());
        _sellBpt(balanceOfUnstakedBpt());
        liquidated = balanceOfWant();
        return liquidated;
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstakeBpt(balanceOfStakedBpt());
        bpt.transfer(_newStrategy, balanceOfUnstakedBpt());
        for (uint i = 0; i < rewardTokens.length; i++) {
            IERC20 token = rewardTokens[i];
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) {
                token.safeTransfer(_newStrategy, balance);
            }
        }
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view override returns (uint256){}

    function tendTrigger(uint256 callCostInWei) public view override returns (bool) {
        return now.sub(lastDepositTime) > minDepositPeriod && (balanceOfWant() > 0 || balanceOfUnstakedBpt() > 0);
    }

    // HELPERS //
    function claimAndSellRewards(bool _doSellRewards) external isVaultManager {
        _claimRewards();
        if (_doSellRewards) {
            _sellRewards();
        }
    }

    function _sellRewards() internal {
        for (uint8 i = 0; i < rewardTokens.length; i++) {
            uint256 amount = balanceOfReward(i);
            if (amount > 0) {
                uint length = swapSteps[i].poolIds.length;
                IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](length);
                int[] memory limits = new int[](length + 1);
                limits[0] = int(amount);
                for (uint j = 0; j < length; j++) {
                    steps[j] = IBalancerVault.BatchSwapStep(swapSteps[i].poolIds[j],
                        j,
                        j + 1,
                        j == 0 ? amount : 0,
                        abi.encode(0)
                    );
                }
                balancerVault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN,
                    steps,
                    swapSteps[i].assets,
                    IBalancerVault.FundManagement(address(this), false, address(this), false),
                    limits,
                    now + 10);
            }
        }
    }

    // this assumes that BAL is always index 0. If not, we can delist then whitelist again to make it at 0
    function _claimRewards() internal {
        for (uint i = 0; i < rewardTokens.length; i++) {
            IERC20 token = rewardTokens[i];
            if (token == BAL) {
                uint256 balanceBefore = balanceOfReward(i);
                minter.mint(address(gauge));
                uint256 keepAmount = balanceOfReward(i).sub(balanceBefore).mul(keepBips).div(basisOne);
                if (keepAmount > 0) {
                    token.safeTransfer(keep, keepAmount);
                }
            } else {
                gauge.claim_rewards(address(this));
            }
        }
    }

    function collectTradingFees() external isVaultManager {
        _collectTradingFees();
    }

    function _collectTradingFees() internal {
        uint256 total = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (total > debt) {
            uint256 profit = tokensToBpts(total.sub(debt));
            uint256 _unstakedBpt = balanceOfUnstakedBpt();
            if (profit > _unstakedBpt) {
                _unstakeBpt(profit.sub(_unstakedBpt));
                _sellBpt(balanceOfUnstakedBpt());
            }
            _sellBpt(Math.min(profit, balanceOfUnstakedBpt()));
        }
    }

    function balanceOfWant() public view returns (uint256 _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfUnstakedBpt() public view returns (uint256 _amount){
        return bpt.balanceOf(address(this));
    }

    function balanceOfStakedBpt() public view returns (uint256 _amount){
        return gauge.balanceOf(address(this));
    }

    function balanceOfReward(uint256 index) public view returns (uint256 _amount){
        return rewardTokens[index].balanceOf(address(this));
    }

    // returns an estimate of want tokens based on bpt balance
    function balanceOfPooled() public view returns (uint256 _amount){
        return bptsToTokens(balanceOfStakedBpt().add(balanceOfUnstakedBpt()));
    }

    /// use bpt rate to estimate equivalent amount of want.
    function bptsToTokens(uint _amountBpt) public view returns (uint _amount){
        uint unscaled = _amountBpt.mul(bpt.getRate()).div(1e18);
        return _scaleDecimals(unscaled, ERC20(address(bpt)), ERC20(address(want)));
    }


    function tokensToBpts(uint _amountTokens) public view returns (uint _amount){
        uint unscaled = _amountTokens.mul(1e18).div(bpt.getRate());
        return _scaleDecimals(unscaled, ERC20(address(want)), ERC20(address(bpt)));
    }

    function _scaleDecimals(uint _amount, ERC20 _fromToken, ERC20 _toToken) internal view returns (uint _scaled){
        uint decFrom = _fromToken.decimals();
        uint decTo = _toToken.decimals();
        return decTo > decFrom ? _amount.mul(10 ** (decTo.sub(decFrom))) : _amount.div(10 ** (decFrom.sub(decTo)));
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

    function sellBpt(uint256 _amountBpts) external isVaultManager {
        _sellBpt(_amountBpts);
    }

    // sell bpt for want at current bpt rate
    function _sellBpt(uint256 _amountBpts) internal {
        _amountBpts = Math.min(_amountBpts, balanceOfUnstakedBpt());
        if (_amountBpts > 0) {
            uint256[] memory minAmountsOut = new uint256[](numTokens);
            minAmountsOut[tokenIndex] = bptsToTokens(_amountBpts).mul(basisOne.sub(maxSlippageOut)).div(basisOne);
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, _amountBpts, tokenIndex);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
            balancerVault.exitPool(balancerPoolId, address(this), address(this), request);
        }
    }

    // for partnership rewards like Lido or airdrops
    function whitelistRewards(address _rewardToken, SwapSteps memory _steps) public isVaultManager {
        IERC20 token = IERC20(_rewardToken);
        token.approve(address(balancerVault), max);
        rewardTokens.push(token);
        swapSteps.push(_steps);
    }

    function delistAllRewards() public isVaultManager {
        for (uint i = 0; i < rewardTokens.length; i++) {
            rewardTokens[i].approve(address(balancerVault), 0);
        }
        IERC20[] memory noRewardTokens;
        rewardTokens = noRewardTokens;
        delete swapSteps;
    }

    function numRewards() public view returns (uint256 _num){
        return rewardTokens.length;
    }

    function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut, uint256 _maxSingleDeposit, uint256 _minDepositPeriod) public isVaultManager {
        require(_maxSlippageIn <= basisOne, "maxSlippageIn too high");
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne, "maxSlippageOut too high");
        maxSlippageOut = _maxSlippageOut;

        maxSingleDeposit = _maxSingleDeposit;
        minDepositPeriod = _minDepositPeriod;
    }

    function setToggles(bool _doSellRewards, bool _doClaimRewards, bool _doCollectTradingFees) external isVaultManager {
        toggles.doSellRewards = _doSellRewards;
        toggles.doClaimRewards = _doClaimRewards;
        toggles.doCollectTradingFees = _doCollectTradingFees;
    }

    function getSwapSteps() public view returns (SwapSteps[] memory){
        return swapSteps;
    }

    function stakeBpt(uint256 _amount) external isVaultManager {
        _stakeBpt(_amount);
    }

    function _stakeBpt(uint256 _amount) internal {
        gauge.deposit(Math.min(balanceOfUnstakedBpt(), _amount), address(this));
    }

    function unstakeBpt(uint256 _amount) external isVaultManager {
        _unstakeBpt(_amount);
    }

    function _unstakeBpt(uint256 _amount) internal {
        gauge.withdraw(Math.min(balanceOfStakedBpt(), _amount));
    }

    function setKeepParams(address _keep, uint256 _keepBips) external onlyGovernance {
        require(keepBips <= basisOne);
        keep = _keep;
        keepBips = _keepBips;
    }

    // Balancer requires this contract to be payable, so we add ability to sweep stuck ETH
    function sweepETH() public onlyGovernance {
        (bool success,) = governance().call{value : address(this).balance}("");
        require(success, "!FailedETHSweep");
    }

    receive() external payable {}
}
