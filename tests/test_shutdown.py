from brownie import ZERO_ADDRESS
import pytest


def test_vault_shutdown_can_withdraw(
        chain, token, vault, strategy, user, amount, RELATIVE_APPROX, gov
):
    ## Deposit in Vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    if token.balanceOf(user) > 0:
        token.transfer(ZERO_ADDRESS, token.balanceOf(user), {"from": user})

    # Harvest 1: Send funds through the strategy
    strategy.harvest({"from": gov})

    chain.sleep(3600 * 7)
    chain.mine(1)
    assert pytest.approx(strategy.estimateTotalAssets({'from': user}).return_value, rel=RELATIVE_APPROX) == amount

    ## Set Emergency
    vault.setEmergencyShutdown(True)

    ## Withdraw (does it work, do you get what you expect)
    vault.withdraw(vault.balanceOf(user), user, 10, {"from": user})

    assert pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == amount


def test_basic_shutdown(
        chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
):
    ## Deposit in Vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    strategy.harvest({"from": gov})
    chain.mine(1)
    assert pytest.approx(strategy.estimateTotalAssets({'from': user}).return_value, rel=RELATIVE_APPROX) == amount

    ## Earn interest
    chain.sleep(3600 * 24 * 1)  ## Sleep 1 day
    chain.mine(1)

    # Harvest 2: Realize profit
    strategy.harvest({"from": gov})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    ## Set emergency
    strategy.setEmergencyExit({"from": strategist})

    strategy.harvest({"from": gov})  ## Remove funds from strategy

    assert token.balanceOf(strategy) == 0
    assert pytest.approx(token.balanceOf(vault), rel=RELATIVE_APPROX) == amount
    ## The vault has all funds
    ## NOTE: May want to tweak this based on potential loss during migration
