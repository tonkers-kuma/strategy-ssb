import urllib.request, json
from brownie import Contract, accounts, web3
import click
import json
import os


def main():
    dev = accounts.load(click.prompt("Account", type=click.Choice(accounts.load())))
    merkleOrchard = Contract("0xdAE7e32ADc5d490a43cCba1f0c736033F2b4eFca")
    bal = "0xba100000625a3754423978a60c9317c58a424e3D"
    ldo = "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32"
    bal_distributor = "0xd2EB7Bd802A7CA68d9AcD209bEc4E664A9abDD7b"
    ldo_distributor = "0x55c8de1ac17c1a937293416c9bce5789cbbf61d1"
    rewards = [("homestead_", bal, bal_distributor, "BAL"), ("homestead-lido_", ldo, ldo_distributor, "LDO")]
    ldo_rewards = ("homestead-lido", ldo, ldo_distributor, "LDO")

    for reward in rewards:
        for root, dirs, files in os.walk(f'./scripts'):
            for name in files:
                if name.startswith(reward[0]):
                    fileName = os.path.join(root, name)
                    f = open(fileName, )
                    data = json.load(f)
                    if not "config" in data:
                        continue
                    config = data["config"]
                    tokens_data = data["tokens_data"]
                    distributionId = config["week"] - config["offset"]

                    print(f'Week: {config["week"]}')
                    for token_data in tokens_data:
                        name = ""
                        try:
                            name = Contract(token_data["address"]).name()
                        except:
                            name = token_data["address"]
                        print(f'claiming {name}')
                        claim = [(distributionId,
                                  int(token_data["claim_amount"]),
                                  reward[2],
                                  0,
                                  token_data["hex_proof"])]
                        claimed = merkleOrchard.isClaimed(reward[1], reward[2], distributionId, token_data["address"])
                        print(f"claimed: {claimed}")
                        if not claimed:
                            # merkleOrchard.claimDistributions(token_data["address"], claim, [reward[1]], {'from': dev, 'gas_price': '50 gwei'})
                            merkleOrchard.claimDistributions(token_data["address"], claim, [reward[1]], {'from': dev})
                            print(f'{name} claimed {int(token_data["claim_amount"]) / 1e18} {reward[3]} ')
