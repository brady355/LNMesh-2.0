package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"math/big"
	stdnet "net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/accounts"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	ethchannel "github.com/perun-network/perun-eth-backend/channel"
	ethwallet "github.com/perun-network/perun-eth-backend/wallet"
	swallet "github.com/perun-network/perun-eth-backend/wallet/simple"
	"github.com/pkg/errors"
	"perun.network/go-perun/channel"
	"perun.network/go-perun/channel/persistence/keyvalue"
	"perun.network/go-perun/client"
	"perun.network/go-perun/wallet"
	"perun.network/go-perun/watcher"
	"perun.network/go-perun/watcher/local"
	"perun.network/go-perun/wire"
	wirenet "perun.network/go-perun/wire/net"
	"perun.network/go-perun/wire/net/simple"
	perunio "perun.network/go-perun/wire/perunio/serializer"
	"polycry.pt/poly-go/sortedkv/leveldb"
)

type nodeCfg struct {
	rpc, key, adj, ah, wireKey, peerPub, peerHost, listen, db, ctl, tower string
	chainID                                                               uint64
}

type node struct {
	cfg     nodeCfg
	client  *client.Client
	ethc    *ethclient.Client
	myAddr  common.Address
	account map[wallet.BackendID]wallet.Address
	waddr   map[wallet.BackendID]wire.Address
	peer    map[wallet.BackendID]wire.Address
	asset   channel.Asset

	mu  sync.Mutex
	chs []*client.Channel // all known channels, newest last
}

func runNode(cfg nodeCfg) error {
	k, err := crypto.HexToECDSA(strings.TrimPrefix(cfg.key, "0x"))
	if err != nil {
		return errors.WithMessage(err, "parsing eth key")
	}
	w := swallet.NewWallet(k)
	myAddr := crypto.PubkeyToAddress(k.PublicKey)

	cb, ethc, err := createContractBackend(cfg.rpc, cfg.chainID, w)
	if err != nil {
		return errors.WithMessage(err, "contract backend")
	}
	adjAddr := common.HexToAddress(cfg.adj)
	ahAddr := common.HexToAddress(cfg.ah)
	ctx := context.Background()
	if err := ethchannel.ValidateAdjudicator(ctx, cb, adjAddr); err != nil {
		return errors.WithMessage(err, "validating adjudicator")
	}
	if err := ethchannel.ValidateAssetHolderETH(ctx, cb, ahAddr, adjAddr); err != nil {
		return errors.WithMessage(err, "validating asset holder")
	}

	funder := ethchannel.NewFunder(cb)
	ethAcc := accounts.Account{Address: myAddr}
	asset := ethchannel.NewAsset(new(big.Int).SetUint64(cfg.chainID), ahAddr)
	funder.RegisterAsset(*asset, ethchannel.NewETHDepositor(50000), ethAcc)
	adjud := ethchannel.NewAdjudicator(cb, adjAddr, myAddr, ethAcc, 1000000)
	lw, err := local.NewWatcher(adjud)
	if err != nil {
		return errors.WithMessage(err, "watcher")
	}
	var wt watcher.Watcher = lw
	if cfg.tower != "" { // the leaf keeps its local watcher and also feeds the gateway tower
		wt = newTeeWatcher(lw, cfg.tower)
	}

	// The wire carries the off-chain messages over TCP on the mesh.
	wacc, err := loadWireAccount(cfg.wireKey)
	if err != nil {
		return errors.WithMessage(err, "loading wire key")
	}
	peerAddr, err := loadWireAddress(cfg.peerPub)
	if err != nil {
		return errors.WithMessage(err, "loading peer pub")
	}
	srvTLS, cliTLS, err := selfSignedTLS()
	if err != nil {
		return err
	}
	listener, err := simple.NewTCPListener(cfg.listen, srvTLS)
	if err != nil {
		return errors.WithMessage(err, "listener")
	}
	dialer := simple.NewTCPDialer(15*time.Second, cliTLS)
	id := map[wallet.BackendID]wire.Account{ethwallet.BackendID: wacc}
	bus := wirenet.NewBus(id, dialer, perunio.Serializer())
	go bus.Listen(listener)
	waddr := map[wallet.BackendID]wire.Address{ethwallet.BackendID: wacc.Address()}
	peer := map[wallet.BackendID]wire.Address{ethwallet.BackendID: peerAddr}
	dialer.Register(peer, cfg.peerHost)

	n := &node{
		cfg:     cfg,
		ethc:    ethc,
		myAddr:  myAddr,
		account: map[wallet.BackendID]wallet.Address{ethwallet.BackendID: ethwallet.AsWalletAddr(myAddr)},
		waddr:   waddr,
		peer:    peer,
		asset:   asset,
	}

	c, err := client.New(waddr, bus, funder, adjud, map[wallet.BackendID]wallet.Wallet{ethwallet.BackendID: w}, wt)
	if err != nil {
		return errors.WithMessage(err, "creating client")
	}
	n.client = c

	db, err := leveldb.LoadDatabase(cfg.db)
	if err != nil {
		return errors.WithMessage(err, "opening leveldb")
	}
	c.EnablePersistence(keyvalue.NewPersistRestorer(db))
	c.OnNewChannel(n.onNewChannel)
	go c.Handle(n, n)

	if err := c.Restore(ctx); err != nil {
		log.Printf("restore: %v", err)
	}
	log.Printf("node ready: eth=%s wire=%s listen=%s peer=%s@%s rpc=%s ctl=%s tower=%q",
		myAddr.Hex(), peerAddrName(wacc.Address()), cfg.listen, peerAddrName(peerAddr), cfg.peerHost, cfg.rpc, cfg.ctl, cfg.tower)
	return n.serveCtl()
}

func peerAddrName(a wire.Address) string {
	if s, ok := a.(*simple.Address); ok {
		return s.Name
	}
	return fmt.Sprint(a)
}

// go-perun calls onNewChannel for proposed, accepted and restored channels.
func (n *node) onNewChannel(ch *client.Channel) {
	n.mu.Lock()
	n.chs = append(n.chs, ch)
	n.mu.Unlock()
	log.Printf("channel registered: id=%x idx=%d", ch.ID(), ch.Idx())
	go func() {
		time.Sleep(500 * time.Millisecond)
		if err := ch.Watch(n); err != nil {
			log.Printf("watcher for %x returned: %v", ch.ID(), err)
		}
	}()
}

// current returns the newest channel that is still usable, so it skips
// channels that are settling or settled. A restored database may contain old
// settled channels.
func (n *node) current() (*client.Channel, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	// A channel that is still acting comes first, then any channel that is not
	// yet withdrawn.
	for i := len(n.chs) - 1; i >= 0; i-- {
		if n.chs[i].Phase() == channel.Acting {
			return n.chs[i], nil
		}
	}
	for i := len(n.chs) - 1; i >= 0; i-- {
		ph := n.chs[i].Phase()
		if ph != channel.Withdrawing && ph != channel.Withdrawn {
			return n.chs[i], nil
		}
	}
	return nil, errors.New("no active channel")
}

func (n *node) forget(ch *client.Channel) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for i, c := range n.chs {
		if c == ch {
			n.chs = append(n.chs[:i], n.chs[i+1:]...)
			return
		}
	}
}

// ---- go-perun handlers ----

func (n *node) HandleProposal(p client.ChannelProposal, r *client.ProposalResponder) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	lcp, ok := p.(*client.LedgerChannelProposalMsg)
	if !ok || lcp.NumPeers() != 2 {
		_ = r.Reject(ctx, "only two-party ledger channels")
		return
	}
	log.Printf("proposal received, accepting")
	ch, err := r.Accept(ctx, lcp.Accept(n.account, client.WithRandomNonce()))
	if err != nil {
		log.Printf("accept proposal: %v", err)
		return
	}
	log.Printf("channel accepted and funded: id=%x", ch.ID())
}

func (n *node) HandleUpdate(cur *channel.State, next client.ChannelUpdate, r *client.UpdateResponder) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	me := 1 - next.ActorIdx
	if next.State.Allocation.Balance(me, n.asset).Cmp(cur.Allocation.Balance(me, n.asset)) < 0 {
		_ = r.Reject(ctx, "update decreases my balance")
		return
	}
	if err := r.Accept(ctx); err != nil {
		log.Printf("accept update: %v", err)
	}
}

func (n *node) HandleAdjudicatorEvent(e channel.AdjudicatorEvent) {
	log.Printf("ADJUDICATOR EVENT %T id=%x version=%d timeout=%v", e, e.ID(), e.Version(), e.Timeout())
}

// ---- control interface ----

func (n *node) serveCtl() error {
	ln, err := stdnet.Listen("tcp", n.cfg.ctl)
	if err != nil {
		return err
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			return err
		}
		go n.handleCtl(conn)
	}
}

func (n *node) handleCtl(conn stdnet.Conn) {
	defer conn.Close()
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil && line == "" {
		return
	}
	args := strings.Fields(strings.TrimSpace(line))
	if len(args) == 0 {
		return
	}
	log.Printf("ctl: %v", args)
	start := time.Now()
	out, err := n.exec(args)
	el := time.Since(start).Milliseconds()
	if err != nil {
		log.Printf("ctl %s failed after %dms: %v", args[0], el, err)
		fmt.Fprintf(conn, "ERR %dms %v\n", el, err)
		return
	}
	log.Printf("ctl %s ok %dms", args[0], el)
	fmt.Fprintf(conn, "OK %dms %s\n", el, out)
}

func (n *node) exec(args []string) (string, error) {
	switch args[0] {
	case "ping":
		return "pong", nil
	case "info":
		return n.info(), nil
	case "onchain":
		bal, err := n.ethc.BalanceAt(context.Background(), n.myAddr, nil)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("addr=%s eth=%s", n.myAddr.Hex(), weiToEthStr(bal)), nil
	case "open":
		if len(args) != 4 {
			return "", errors.New("usage: open <myETH> <peerETH> <challengeSeconds>")
		}
		mine, err := weiFromEth(args[1])
		if err != nil {
			return "", err
		}
		theirs, err := weiFromEth(args[2])
		if err != nil {
			return "", err
		}
		challenge, err := strconv.ParseUint(args[3], 10, 64)
		if err != nil {
			return "", err
		}
		return n.open(mine, theirs, challenge)
	case "pay":
		if len(args) != 2 {
			return "", errors.New("usage: pay <ETH>")
		}
		amt, err := weiFromEth(args[1])
		if err != nil {
			return "", err
		}
		return n.pay(amt)
	case "bal":
		return n.bal()
	case "close":
		return n.settle(true, false)
	case "forceclose":
		return n.settle(false, false)
	case "withdraw":
		return n.settle(false, true)
	}
	return "", errors.Errorf("unknown command %q", args[0])
}

func (n *node) info() string {
	ch, err := n.current()
	s := fmt.Sprintf("eth=%s wire=%s", n.myAddr.Hex(), peerAddrName(n.waddr[ethwallet.BackendID]))
	if err != nil {
		return s + " channel=none"
	}
	return s + fmt.Sprintf(" channel=%x phase=%v", ch.ID(), ch.Phase())
}

func (n *node) open(mine, theirs *big.Int, challenge uint64) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	alloc := channel.NewAllocation(2, []wallet.BackendID{ethwallet.BackendID}, n.asset)
	alloc.SetAssetBalances(n.asset, []channel.Bal{mine, theirs})
	prop, err := client.NewLedgerChannelProposal(challenge, n.account, alloc,
		[]map[wallet.BackendID]wire.Address{n.waddr, n.peer})
	if err != nil {
		return "", err
	}
	ch, err := n.client.ProposeChannel(ctx, prop)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("channel=%x", ch.ID()), nil
}

func (n *node) pay(amt *big.Int) (string, error) {
	ch, err := n.current()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	err = ch.Update(ctx, func(s *channel.State) {
		s.Allocation.TransferBalance(ch.Idx(), 1-ch.Idx(), n.asset, amt)
	})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("version=%d", ch.State().Version), nil
}

func (n *node) bal() (string, error) {
	ch, err := n.current()
	if err != nil {
		return "", err
	}
	st := ch.State()
	return fmt.Sprintf("id=%x idx=%d version=%d final=%v phase=%v bal0=%s bal1=%s",
		ch.ID(), ch.Idx(), st.Version, st.IsFinal, ch.Phase(),
		weiToEthStr(st.Allocation.Balance(0, n.asset)), weiToEthStr(st.Allocation.Balance(1, n.asset))), nil
}

// settle closes the channel. With finalize the node first signs a cooperative
// final update with the peer, so the close skips the challenge wait. With
// secondary the node waits for the peer to conclude and then only withdraws.
func (n *node) settle(finalize, secondary bool) (string, error) {
	ch, err := n.current()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	if finalize && !ch.State().IsFinal {
		if err := ch.Update(ctx, func(s *channel.State) { s.IsFinal = true }); err != nil {
			return "", errors.WithMessage(err, "finalizing")
		}
	}
	if err := ch.Settle(ctx, secondary); err != nil {
		return "", errors.WithMessage(err, "settle")
	}
	st := ch.State()
	out := fmt.Sprintf("settled version=%d bal0=%s bal1=%s", st.Version,
		weiToEthStr(st.Allocation.Balance(0, n.asset)), weiToEthStr(st.Allocation.Balance(1, n.asset)))
	if err := ch.Close(); err != nil {
		log.Printf("close: %v", err)
	}
	n.forget(ch)
	return out, nil
}

// ---- helpers ----

var weiPerEth = new(big.Float).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil))

func weiFromEth(s string) (*big.Int, error) {
	f, ok := new(big.Float).SetString(s)
	if !ok {
		return nil, errors.Errorf("bad amount %q", s)
	}
	wei, _ := new(big.Float).Mul(f, weiPerEth).Int(nil)
	return wei, nil
}

func weiToEthStr(wei *big.Int) string {
	if wei == nil {
		return "nil"
	}
	return new(big.Float).Quo(new(big.Float).SetInt(wei), weiPerEth).Text('f', 6)
}

// ctlCmd sends one command line to the control port of a running node.
func ctlCmd(addr string, args []string) error {
	conn, err := stdnet.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := fmt.Fprintln(conn, strings.Join(args, " ")); err != nil {
		return err
	}
	sc := bufio.NewScanner(conn)
	for sc.Scan() {
		fmt.Println(sc.Text())
	}
	return sc.Err()
}
