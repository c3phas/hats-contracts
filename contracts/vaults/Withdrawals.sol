// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "./Base.sol";

contract Withdrawals is Base {
    using SafeERC20 for IERC20;

    /**
    * @notice Submit a request to withdraw funds from the vault.
    * The request will only be approved if the last action was a deposit or
    * withdrawal, or in case the last action was a withdraw request, that the
    * withdraw request had expired (meaning that the pending period and the
    * withdraw enable period had both ended).
    */
    function withdrawRequest() external nonReentrant {
        HATVaultsRegistry.GeneralParameters memory generalParameters = registry.getGeneralParameters();
        // require withdraw to be at least withdrawRequestEnablePeriod+withdrawRequestPendingPeriod since last withdrawRequest
        // unless there's been a deposit or withdraw since, in which case withdrawRequest is allowed immediately
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp <
            withdrawEnableStartTime[msg.sender] +
                generalParameters.withdrawRequestEnablePeriod)
            revert PendingWithdrawRequestExists();
        // set the withdrawEnableStartTime time to be withdrawRequestPendingPeriod from now
        // solhint-disable-next-line not-rely-on-time
        withdrawEnableStartTime[msg.sender] = block.timestamp + generalParameters.withdrawRequestPendingPeriod;
        emit WithdrawRequest(msg.sender, withdrawEnableStartTime[msg.sender]);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares,
        uint256 fee,
        bool claimReward
    ) internal nonReentrant {
        // TODO: If a user gives allowance to another user, that other user can spam to some extent the allowing user's withdraw request
        // Should consider disallowing withdraw from another user.
        checkWithdrawAndResetWithdrawEnableStartTime(owner);
        if (assets == 0) revert WithdrawMustBeGreaterThanZero();
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        rewardController.updateVaultBalance(owner, shares, false, claimReward);

        _burn(owner, shares);

        safeWithdrawVaultToken(assets, fee, receiver);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /** 
    * @notice Withdraw previously deposited funds from the vault.
    * Can only be performed if a withdraw request has been previously
    * submitted, and the pending period had passed, and while the withdraw
    * enabled timeout had not passed.
    * @param assets Amount of tokens to withdraw
    * @param receiver Address of receiver of the funds 
    * @param owner Address of owner of the funds 
    * @dev See {IERC4626-withdraw}.
    */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override virtual returns (uint256) {
        if (assets > maxWithdraw(owner)) revert WithdrawMoreThanMax();

        uint256 shares = previewWithdraw(assets);
        uint256 fee = _convertToAssets(shares - _convertToShares(assets, MathUpgradeable.Rounding.Up), MathUpgradeable.Rounding.Up);
        _withdraw(_msgSender(), receiver, owner, assets, shares, fee, true);

        return shares;
    }

    /** 
    * @notice Redeem shares in the vault, and receive the respective amount of
    * underlying assets.
    * Can only be performed if a withdraw request has been previously
    * submitted, and the pending period had passed, and while the withdraw
    * enabled timeout had not passed.
    * @param assets Amount of shares to redeem
    * @param receiver Address of receiver of the funds 
    * @param owner Address of owner of the funds 
    * @dev See {IERC4626-redeem}.
    */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override virtual returns (uint256) {
        if (shares > maxRedeem(owner)) revert RedeemMoreThanMax();

        uint256 assets = previewRedeem(shares);
        uint256 fee = _convertToAssets(shares, MathUpgradeable.Rounding.Down) - assets;
        _withdraw(_msgSender(), receiver, owner, assets, shares, fee, true);

        return assets;
    }

    function emergencyWithdraw() external {
        address msgSender = _msgSender();
        uint256 shares = balanceOf(msgSender);
        uint256 assets = previewRedeem(shares);
        uint256 fee = _convertToAssets(shares, MathUpgradeable.Rounding.Down) - assets;
        _withdraw(msgSender, msgSender, msgSender, assets, shares, fee, false);
        emit EmergencyWithdraw(msgSender, assets, shares);
    }

    /**
    * @dev Checks that the sender can perform a withdraw at this time
    * and also sets the withdrawEnableStartTime to 0
    * @param _user Address of the user to check
    */
    function checkWithdrawAndResetWithdrawEnableStartTime(address _user)
        internal
        noActiveClaim
    {
        if (!isWithdrawEnabledForUser(_user))
            revert InvalidWithdrawRequest();
        // if all is ok and withdrawal can be made - reset withdrawRequests[_pid][msg.sender] so that another withdrawRequest
        // will have to be made before next withdrawal
        withdrawEnableStartTime[_user] = 0;
    }

    /**
    * @dev Checks that the given user can perform a withdraw at this time
    * @param _user Address of the user to check
    */
    function isWithdrawEnabledForUser(address _user)
        internal view
        returns(bool)
    {
        HATVaultsRegistry.GeneralParameters memory generalParameters = registry.getGeneralParameters();
        // disable withdraw for safetyPeriod (e.g 1 hour) after each withdrawPeriod (e.g 11 hours)
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp %
        (generalParameters.withdrawPeriod + generalParameters.safetyPeriod) >=
            generalParameters.withdrawPeriod) return false;
        // check that withdrawRequestPendingPeriod had passed
        // solhint-disable-next-line not-rely-on-time
        return (block.timestamp >= withdrawEnableStartTime[_user] &&
        // check that withdrawRequestEnablePeriod had not passed and that the
        // last action was withdrawRequest (and not deposit or withdraw, which
        // reset withdrawRequests[_user] to 0)
        // solhint-disable-next-line not-rely-on-time
            block.timestamp <=
                withdrawEnableStartTime[_user] +
                generalParameters.withdrawRequestEnablePeriod);
    }

    /**
    * @dev Safely transfer vault's token to reciever, and fee to governance
    * @param _totalAmount Amount of vault's token to transfer to _receiver
    * @param _fee Amount of vault's token to transfer to vault's owner
    * @param _receiver Address of receiver of funds
    */
    function safeWithdrawVaultToken(uint256 _totalAmount, uint256 _fee, address _receiver)
        internal
    {
        IERC20 asset = IERC20(asset());
        if (_fee > 0) {
            asset.safeTransfer(owner(), _fee);
        }
        asset.safeTransfer(_receiver, _totalAmount);
    }
}