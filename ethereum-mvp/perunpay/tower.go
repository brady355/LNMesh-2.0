package main

// This file holds the watchtower of the Ethereum arm and the leaf side that
// feeds it.
//
// A leaf hands the tower every channel state with both signatures. The tower
// gives those states to the local watcher of go-perun. The local watcher
// subscribes to the Adjudicator contract, so it registers the newest state as
// soon as it sees a registration with an older version. The tower signs its
// own transactions with its own account, because the Adjudicator accepts a
// register call from any account. Thus the tower holds no key of any leaf,
// and it can only help a leaf, never spend for it.
//
// A leaf and the tower exchange one message per TCP connection. A message
// starts with a kind byte and the 32 byte channel id. A start message then
// carries the channel parameters and the signed state, and an update message
// carries the signed state. The tower answers with one line, OK or ERR with a
// reason.

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	stdnet "net"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/accounts"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	ethchannel "github.com/perun-network/perun-eth-backend/channel"
	swallet "github.com/perun-network/perun-eth-backend/wallet/simple"
	"github.com/pkg/errors"
	"perun.network/go-perun/channel"
	"perun.network/go-perun/watcher"
	"perun.network/go-perun/watcher/local"
	"perun.network/go-perun/wire/perunio"
)

const (
	towerStart  uint8 = 1
	towerUpdate uint8 = 2
	towerStop   uint8 = 3
)

func encodeTowerMsg(kind uint8, id channel.ID, params *channel.Params, tx channel.Transaction) ([]byte, error) {
	var buf bytes.Buffer
	if err := perunio.Encode(&buf, kind, perunio.ByteSlice(id[:])); err != nil {
		return nil, err
	}
	switch kind {
	case towerStart:
		if err := perunio.Encode(&buf, params, tx); err != nil {
			return nil, err
		}
	case towerUpdate:
		if err := perunio.Encode(&buf, tx); err != nil {
			return nil, err
		}
	}
	return buf.Bytes(), nil
}

func decodeTowerMsg(r io.Reader) (kind uint8, id channel.ID, params *channel.Params, tx channel.Transaction, err error) {
	raw := make(perunio.ByteSlice, channel.IDLen) // a ByteSlice decodes into its own length
	if err = perunio.Decode(r, &kind, &raw); err != nil {
		return
	}
	copy(id[:], raw)
	switch kind {
	case towerStart:
		params = new(channel.Params)
		err = perunio.Decode(r, params, &tx)
	case towerUpdate:
		err = perunio.Decode(r, &tx)
	}
	return
}

// ---- leaf side ----

// teeWatcher wraps the local watcher of a leaf. It keeps the local behaviour
// and forwards every registration and every published state to the tower.
// The forwarding runs in the background and in order, so a payment never
// waits for the tower, and an unreachable tower costs nothing but a log line.
type teeWatcher struct {
	local *local.Watcher
	tower string
	mu    sync.Mutex
	queue map[channel.ID]chan towerItem
}

type towerItem struct {
	label string
	data  []byte
}

func newTeeWatcher(lw *local.Watcher, tower string) *teeWatcher {
	return &teeWatcher{local: lw, tower: tower, queue: map[channel.ID]chan towerItem{}}
}

func (t *teeWatcher) enqueue(id channel.ID, label string, data []byte, err error) {
	if err != nil {
		log.Printf("TOWER encode %s: %v", label, err)
		return
	}
	t.mu.Lock()
	q, ok := t.queue[id]
	if !ok {
		q = make(chan towerItem, 1024)
		t.queue[id] = q
		go t.sender(q)
	}
	t.mu.Unlock()
	select {
	case q <- towerItem{label, data}:
	default:
		log.Printf("TOWER queue full, dropped %s", label)
	}
}

// sender delivers the items of one channel in order. It retries a failed
// delivery every two seconds, so the tower ends up with the newest state
// once it is reachable again.
func (t *teeWatcher) sender(q chan towerItem) {
	for it := range q {
		for attempt := 1; ; attempt++ {
			t0 := time.Now()
			reply, err := towerRoundTrip(t.tower, it.data)
			if err == nil && strings.HasPrefix(reply, "OK") {
				log.Printf("TOWER ack %s in %dms", it.label, time.Since(t0).Milliseconds())
				break
			}
			if err == nil {
				log.Printf("TOWER rejected %s: %s", it.label, reply)
				break
			}
			if attempt == 1 {
				log.Printf("TOWER unreachable for %s: %v (retrying)", it.label, err)
			}
			time.Sleep(2 * time.Second)
		}
	}
}

func towerRoundTrip(addr string, data []byte) (string, error) {
	conn, err := stdnet.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	if _, err := conn.Write(data); err != nil {
		return "", err
	}
	if cw, ok := conn.(*stdnet.TCPConn); ok {
		_ = cw.CloseWrite()
	}
	reply, err := bufio.NewReader(conn).ReadString('\n')
	return strings.TrimSpace(reply), err
}

func (t *teeWatcher) StartWatchingLedgerChannel(ctx context.Context, ss channel.SignedState) (watcher.StatesPub, watcher.AdjudicatorSub, error) {
	pub, sub, err := t.local.StartWatchingLedgerChannel(ctx, ss)
	if err != nil {
		return nil, nil, err
	}
	id := ss.State.ID
	tx := channel.Transaction{State: ss.State, Sigs: ss.Sigs}.Clone()
	data, encErr := encodeTowerMsg(towerStart, id, ss.Params, tx)
	t.enqueue(id, fmt.Sprintf("start version=%d", tx.State.Version), data, encErr)
	return &teePub{pub: pub, t: t, id: id}, sub, nil
}

func (t *teeWatcher) StartWatchingSubChannel(ctx context.Context, parent channel.ID, ss channel.SignedState) (watcher.StatesPub, watcher.AdjudicatorSub, error) {
	return t.local.StartWatchingSubChannel(ctx, parent, ss)
}

func (t *teeWatcher) StopWatching(ctx context.Context, id channel.ID) error {
	err := t.local.StopWatching(ctx, id)
	data, encErr := encodeTowerMsg(towerStop, id, nil, channel.Transaction{})
	t.enqueue(id, "stop", data, encErr)
	return err
}

type teePub struct {
	pub watcher.StatesPub
	t   *teeWatcher
	id  channel.ID
}

func (p *teePub) Publish(ctx context.Context, tx channel.Transaction) error {
	err := p.pub.Publish(ctx, tx)
	c := tx.Clone()
	data, encErr := encodeTowerMsg(towerUpdate, p.id, nil, c)
	p.t.enqueue(p.id, fmt.Sprintf("update version=%d", c.State.Version), data, encErr)
	return err
}

// ---- tower side ----

type towerCfg struct {
	rpc, key, adj, listen string
	chainID               uint64
}

type tower struct {
	w    *local.Watcher
	mu   sync.Mutex
	pubs map[channel.ID]watcher.StatesPub
	seen map[channel.ID]uint64
}

func runTower(cfg towerCfg) error {
	k, err := crypto.HexToECDSA(strings.TrimPrefix(cfg.key, "0x"))
	if err != nil {
		return errors.WithMessage(err, "parsing tower key")
	}
	w := swallet.NewWallet(k)
	addr := crypto.PubkeyToAddress(k.PublicKey)
	cb, ethc, err := createContractBackend(cfg.rpc, cfg.chainID, w)
	if err != nil {
		return errors.WithMessage(err, "contract backend")
	}
	ctx := context.Background()
	adjAddr := common.HexToAddress(cfg.adj)
	if err := ethchannel.ValidateAdjudicator(ctx, cb, adjAddr); err != nil {
		return errors.WithMessage(err, "validating adjudicator")
	}
	adjud := ethchannel.NewAdjudicator(cb, adjAddr, addr, accounts.Account{Address: addr}, 1000000)
	lw, err := local.NewWatcher(adjud)
	if err != nil {
		return err
	}
	t := &tower{w: lw, pubs: map[channel.ID]watcher.StatesPub{}, seen: map[channel.ID]uint64{}}
	bal, err := ethc.BalanceAt(ctx, addr, nil)
	if err != nil {
		return err
	}
	ln, err := stdnet.Listen("tcp", cfg.listen)
	if err != nil {
		return err
	}
	log.Printf("tower ready: account=%s balance=%s ETH adjudicator=%s listen=%s rpc=%s",
		addr.Hex(), weiToEthStr(bal), adjAddr.Hex(), cfg.listen, cfg.rpc)
	for {
		conn, err := ln.Accept()
		if err != nil {
			return err
		}
		go t.handle(conn)
	}
}

func (t *tower) handle(conn stdnet.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(60 * time.Second))
	kind, id, params, tx, err := decodeTowerMsg(bufio.NewReader(conn))
	if err != nil {
		log.Printf("bad message from %s: %v", conn.RemoteAddr(), err)
		fmt.Fprintf(conn, "ERR decode: %v\n", err)
		return
	}
	if err := t.apply(kind, id, params, tx); err != nil {
		log.Printf("message %d for %x failed: %v", kind, id, err)
		fmt.Fprintf(conn, "ERR %v\n", err)
		return
	}
	fmt.Fprintln(conn, "OK")
}

func (t *tower) apply(kind uint8, id channel.ID, params *channel.Params, tx channel.Transaction) error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	t.mu.Lock()
	defer t.mu.Unlock()
	switch kind {
	case towerStart:
		if pub, ok := t.pubs[id]; ok { // a restarted leaf registers again
			return t.publish(ctx, id, pub, tx)
		}
		if tx.State == nil {
			return errors.New("start without a state")
		}
		ss := channel.SignedState{Params: params, State: tx.State, Sigs: tx.Sigs}
		// The adjudicator subscription lives as long as this context, so it
		// must outlive the request that started the watching.
		pub, sub, err := t.w.StartWatchingLedgerChannel(context.Background(), ss)
		if err != nil {
			return err
		}
		t.pubs[id] = pub
		t.seen[id] = tx.State.Version
		go t.drain(id, sub)
		log.Printf("WATCHING channel=%x version=%d challenge=%ds parties=%d", id, tx.State.Version, params.ChallengeDuration, len(params.Parts))
		return nil
	case towerUpdate:
		pub, ok := t.pubs[id]
		if !ok {
			return errors.New("unknown channel, send a start message first")
		}
		return t.publish(ctx, id, pub, tx)
	case towerStop:
		if _, ok := t.pubs[id]; !ok {
			return nil
		}
		delete(t.pubs, id)
		delete(t.seen, id)
		log.Printf("STOPPED channel=%x", id)
		return t.w.StopWatching(ctx, id)
	}
	return errors.Errorf("unknown message kind %d", kind)
}

func (t *tower) publish(ctx context.Context, id channel.ID, pub watcher.StatesPub, tx channel.Transaction) error {
	if tx.State == nil {
		return errors.New("update without a state")
	}
	if tx.State.Version < t.seen[id] {
		log.Printf("IGNORED channel=%x version=%d, tower already holds %d", id, tx.State.Version, t.seen[id])
		return nil
	}
	if err := pub.Publish(ctx, tx); err != nil {
		return err
	}
	t.seen[id] = tx.State.Version
	log.Printf("STATE channel=%x version=%d final=%v", id, tx.State.Version, tx.State.IsFinal)
	return nil
}

// drain logs the adjudicator events of one channel. A RegisteredEvent with an
// old version followed by a RegisteredEvent with the newest version shows the
// tower's reaction time.
func (t *tower) drain(id channel.ID, sub watcher.AdjudicatorSub) {
	for e := range sub.EventStream() {
		log.Printf("ADJUDICATOR EVENT %T channel=%x version=%d timeout=%v", e, id, e.Version(), e.Timeout())
	}
	if err := sub.Err(); err != nil {
		log.Printf("subscription for %x ended: %v", id, err)
	}
}
