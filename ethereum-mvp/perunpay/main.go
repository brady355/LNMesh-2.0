// perunpay is the minimum viable Perun payment channel node of the mesh
// testbed. It has five subcommands.
//
//	deploy  deploys the Adjudicator and the ETH asset holder and writes contracts.json
//	keygen  creates an RSA wire identity file and its public counterpart
//	node    runs a channel node with a TCP wire on the mesh and chain access through the gateway RPC
//	tower   runs the gateway watchtower, which refutes stale registrations
//	ctl     sends a command to the control port of a running node
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/sirupsen/logrus"
	plogrus "perun.network/go-perun/log/logrus"
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage: perunpay deploy|keygen|node|tower|ctl [flags]")
	os.Exit(2)
}

func main() {
	time.Local = time.UTC // every log on the testbed is in UTC
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "deploy":
		fs := flag.NewFlagSet("deploy", flag.ExitOnError)
		rpc := fs.String("rpc", "ws://127.0.0.1:8545", "chain RPC (websocket)")
		chainID := fs.Uint64("chainid", 1337, "chain id")
		key := fs.String("key", "", "deployer private key (hex)")
		out := fs.String("out", "contracts.json", "output file")
		_ = fs.Parse(os.Args[2:])
		adj, ah, err := deployContracts(*rpc, *chainID, *key)
		if err != nil {
			log.Fatalf("deploy: %v", err)
		}
		cf := contractsFile{Adjudicator: adj.Hex(), AssetHolder: ah.Hex(), ChainID: *chainID, RPC: *rpc}
		if err := writeJSON(*out, cf); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("adjudicator=%s asset_holder=%s\n", adj.Hex(), ah.Hex())

	case "keygen":
		fs := flag.NewFlagSet("keygen", flag.ExitOnError)
		name := fs.String("name", "", "wire name, e.g. pi2")
		out := fs.String("out", "", "private key file (default <name>.wire)")
		pub := fs.String("pub", "", "public key file (default <name>.pub)")
		_ = fs.Parse(os.Args[2:])
		if *name == "" {
			log.Fatal("-name required")
		}
		if *out == "" {
			*out = *name + ".wire"
		}
		if *pub == "" {
			*pub = *name + ".pub"
		}
		if err := keygen(*name, *out, *pub); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("wrote %s and %s\n", *out, *pub)

	case "node":
		fs := flag.NewFlagSet("node", flag.ExitOnError)
		var cfg nodeCfg
		fs.StringVar(&cfg.rpc, "rpc", "ws://10.10.0.1:8545", "chain RPC (websocket) reached through the gateway")
		fs.Uint64Var(&cfg.chainID, "chainid", 1337, "chain id")
		fs.StringVar(&cfg.key, "key", "", "eth private key (hex)")
		fs.StringVar(&cfg.adj, "adj", "", "adjudicator address")
		fs.StringVar(&cfg.ah, "ah", "", "ETH asset holder address")
		fs.StringVar(&cfg.wireKey, "wire", "", "own wire key file (from keygen)")
		fs.StringVar(&cfg.peerPub, "peer", "", "peer wire pub file")
		fs.StringVar(&cfg.peerHost, "peer-host", "", "peer host:port on the mesh")
		fs.StringVar(&cfg.listen, "listen", "0.0.0.0:6000", "wire listen address")
		fs.StringVar(&cfg.db, "db", "perun-db", "leveldb persistence directory")
		fs.StringVar(&cfg.ctl, "ctl", "127.0.0.1:7000", "control port (local)")
		fs.StringVar(&cfg.tower, "tower", "", "gateway tower host:port, or empty to run without a tower")
		verbose := fs.Bool("v", false, "verbose go-perun logging")
		_ = fs.Parse(os.Args[2:])
		lvl := logrus.WarnLevel
		if *verbose {
			lvl = logrus.DebugLevel
		}
		plogrus.Set(lvl, &logrus.TextFormatter{FullTimestamp: true, TimestampFormat: "15:04:05.000"})
		if err := runNode(cfg); err != nil {
			log.Fatalf("node: %v", err)
		}

	case "tower":
		fs := flag.NewFlagSet("tower", flag.ExitOnError)
		var cfg towerCfg
		fs.StringVar(&cfg.rpc, "rpc", "ws://127.0.0.1:8545", "chain RPC (websocket) on the gateway")
		fs.Uint64Var(&cfg.chainID, "chainid", 1337, "chain id")
		fs.StringVar(&cfg.key, "key", "", "the tower's own eth private key in hex, which pays the gas of the refutations")
		fs.StringVar(&cfg.adj, "adj", "", "adjudicator address")
		fs.StringVar(&cfg.listen, "listen", "0.0.0.0:6500", "address the leaves send their states to")
		verbose := fs.Bool("v", false, "verbose go-perun logging")
		_ = fs.Parse(os.Args[2:])
		lvl := logrus.InfoLevel
		if *verbose {
			lvl = logrus.DebugLevel
		}
		plogrus.Set(lvl, &logrus.TextFormatter{FullTimestamp: true, TimestampFormat: "15:04:05.000"})
		if err := runTower(cfg); err != nil {
			log.Fatalf("tower: %v", err)
		}

	case "ctl":
		fs := flag.NewFlagSet("ctl", flag.ExitOnError)
		addr := fs.String("addr", "127.0.0.1:7000", "control address of the node")
		_ = fs.Parse(os.Args[2:])
		if fs.NArg() == 0 {
			log.Fatal("ctl needs a command, e.g. ctl bal")
		}
		if err := ctlCmd(*addr, fs.Args()); err != nil {
			log.Fatal(err)
		}

	default:
		usage()
	}
}
