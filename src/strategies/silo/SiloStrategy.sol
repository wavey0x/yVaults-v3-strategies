// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";

import {AuctionSwapper, Auction} from "@periphery/swappers/AuctionSwapper.sol";

import {IAaveIncentivesController} from "@silo/external/aave/interfaces/IAaveIncentivesController.sol";
import {ISilo} from "@silo/interfaces/ISilo.sol";
import {IShareToken} from "@silo/interfaces/IShareToken.sol";
import {EasyMathV2} from "@silo/lib/EasyMathV2.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

/**
 * @title SiloStrategy
 * @author johnnyonline
 * @notice A strategy that deposits funds into a Silo and harvests incentives.
 */
contract SiloStrategy is AuctionSwapper, BaseStrategy {

    using SafeERC20 for ERC20;
    using EasyMathV2 for uint256;

    /**
     * @dev The reward token paid by the incentives controller.
     */
    ERC20 public immutable rewardToken;

    /**
     * @dev The incentives controller that pays the reward token.
     */
    IAaveIncentivesController public immutable incentivesController;

    /**
     * @dev The Silo that the strategy is using.
     */
    ISilo public immutable silo;

    /**
     * @dev The share token that represents the strategy's share of the Silo.
     */
    IShareToken public immutable share;

    /**
     * @notice Used to initialize the strategy on deployment.
     * @param _silo Address of the Silo that the strategy is using.
     * @param _share Address of the share token that represents the strategy's share of the Silo.
     * @param _asset Address of the underlying asset.
     * @param _rewardToken Address of the reward token paid by the incentives controller.
     * @param _incentivesController Address of the incentives controller that pays the reward token.
     * @param _name Name the strategy will use.
     */
    constructor(
        address _silo,
        address _share,
        address _asset,
        address _rewardToken,
        address _incentivesController,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        silo = ISilo(_silo);
        share = IShareToken(_share);
        rewardToken = ERC20(_rewardToken);
        incentivesController = IAaveIncentivesController(_incentivesController);

        ERC20(_asset).forceApprove(address(silo), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can enable a `postTake` hook to be triggered, so that harvested funds can be redeployed.
     */
    function setPostTakeHookFlag(bool _flag) external onlyManagement {
        Auction(auction).setHookFlags(
            false, // _kickable
            false, // _kick,
            false, // _preTake,
            _flag // _postTake
        );
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        if(!TokenizedStrategy.isShutdown()) {
            silo.deposit(
                address(asset),
                _amount,
                false
            );
        }
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        silo.withdraw(
            address(asset),
            _amount,
            false
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // Only harvest and redeploy if the strategy is not shutdown.
        if(!TokenizedStrategy.isShutdown()) {
            // Claim all rewards and sell to asset.
            _claimAndSellRewards();
            
            // Check how much we can re-deploy into the yield source.
            uint256 toDeploy = asset.balanceOf(address(this));
            
            // If greater than 0.
            if (toDeploy > 0) {
                // Deposit the sold amount back into the yield source.
                _deployFunds(toDeploy);
            }
        }
        
        // Return full balance no matter what.
        uint256 _redeemableForShares = share.balanceOf(address(this)).toAmount(
            silo.assetStorage(address(asset)).totalDeposits,
            share.totalSupply()
        );
        _totalAssets = _redeemableForShares + asset.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Checks if there are any rewards to claim, and enables the auction if so.
     */
    function _claimAndSellRewards() internal {
        if (address(incentivesController) != address(0)) {
            address[] memory assets = new address[](1);
            assets[0] = address(share);
            if (incentivesController.getRewardsBalance(assets, address(this)) > 0) {
                incentivesController.claimRewards(
                    assets,
                    type(uint256).max,
                    address(this)
                );

                uint256 rewardBalance = rewardToken.balanceOf(address(this));
                if (rewardBalance > 0) _enableAuction(address(rewardToken), address(asset));
            }
        }
    }

    /// @inheritdoc AuctionSwapper
    function _postTake(
        address, // _token
        uint256, // _amountTaken
        uint256 // _amountPayed
    ) internal override {
        uint256 toDeploy = asset.balanceOf(address(this));
        if (toDeploy > 0) _deployFunds(toDeploy);
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    function _tend(uint256 _totalIdle) internal override {}
    */

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function _tendTrigger() internal view override returns (bool) {}
    */

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement deposit limit logic and any needed state variables .
        
        EX:    
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            return totalAssets >= depositLimit ? 0 : depositLimit - totalAssets;
    }
    */

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(address(this));;
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     *
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement withdraw limit logic and any needed state variables.
        
        EX:    
            return asset.balanceOf(address(this));
    }
    */

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    */
}
