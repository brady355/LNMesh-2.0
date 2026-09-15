package main

import (
	"context"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	ethchannel "github.com/perun-network/perun-eth-backend/channel"
	swallet "github.com/perun-network/perun-eth-backend/wallet/simple"
)

const txFinalityDepth = 1

type contractsFile struct {
	Adjudicator string `json:"adjudicator"`
	AssetHolder string `json:"asset_holder"`
	ChainID     uint64 `json:"chain_id"`
	RPC         string `json:"rpc"`
}

func createContractBackend(nodeURL string, chainID uint64, w *swallet.Wallet) (ethchannel.ContractBackend, *ethclient.Client, error) {
	signer := types.LatestSignerForChainID(new(big.Int).SetUint64(chainID))
	transactor := swallet.NewTransactor(w, signer)
	ethClient, err := ethclient.Dial(nodeURL)
	if err != nil {
		return ethchannel.ContractBackend{}, nil, err
	}
	cb := ethchannel.NewContractBackend(ethClient, ethchannel.MakeChainID(new(big.Int).SetUint64(chainID)), transactor, txFinalityDepth)
	return cb, ethClient, nil
}

// deployContracts deploys the Perun Adjudicator and the ETH asset holder.
func deployContracts(nodeURL string, chainID uint64, privateKey string) (adj, ah common.Address, err error) {
	k, err := crypto.HexToECDSA(privateKey)
	if err != nil {
		return
	}
	w := swallet.NewWallet(k)
	cb, _, err := createContractBackend(nodeURL, chainID, w)
	if err != nil {
		return
	}
	acc := accounts.Account{Address: crypto.PubkeyToAddress(k.PublicKey)}
	adj, err = ethchannel.DeployAdjudicator(context.Background(), cb, acc)
	if err != nil {
		return
	}
	ah, err = ethchannel.DeployETHAssetholder(context.Background(), cb, adj, acc)
	return
}
