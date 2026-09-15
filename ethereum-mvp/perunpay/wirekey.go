package main

// This file holds the wire identities for the simple TCP transport of go-perun.
// The simple transport authenticates peers with RSA signatures over their wire
// address, so each node needs a persistent RSA key and the public key of its
// peer. The gateway generates the keys and distributes the files with scp.

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"os"
	"time"

	"github.com/pkg/errors"
	"perun.network/go-perun/wire"
	"perun.network/go-perun/wire/net/simple"
)

type wireKeyFile struct {
	Name    string `json:"name"`
	PrivPEM string `json:"priv_pem,omitempty"`
	NHex    string `json:"n_hex"`
	E       int    `json:"e"`
}

// wireAccount implements wire.Account so that simple.Address.Verify accepts it.
type wireAccount struct {
	addr *simple.Address
	priv *rsa.PrivateKey
}

func (a *wireAccount) Address() wire.Address { return a.addr }

func (a *wireAccount) Sign(msg []byte) ([]byte, error) {
	h := sha256.Sum256(msg)
	return rsa.SignPKCS1v15(rand.Reader, a.priv, crypto.SHA256, h[:])
}

func writeJSON(path string, v interface{}) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}

func readJSON(path string, v interface{}) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func keygen(name, out, pubout string) error {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return err
	}
	der := x509.MarshalPKCS1PrivateKey(priv)
	f := wireKeyFile{
		Name:    name,
		PrivPEM: string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: der})),
		NHex:    priv.N.Text(16),
		E:       priv.E,
	}
	if err := writeJSON(out, f); err != nil {
		return err
	}
	f.PrivPEM = ""
	return writeJSON(pubout, f)
}

func loadWireAccount(path string) (*wireAccount, error) {
	var f wireKeyFile
	if err := readJSON(path, &f); err != nil {
		return nil, err
	}
	block, _ := pem.Decode([]byte(f.PrivPEM))
	if block == nil {
		return nil, errors.New("no PEM private key in " + path)
	}
	priv, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	return &wireAccount{
		addr: &simple.Address{Name: f.Name, PublicKey: &priv.PublicKey},
		priv: priv,
	}, nil
}

func loadWireAddress(path string) (*simple.Address, error) {
	var f wireKeyFile
	if err := readJSON(path, &f); err != nil {
		return nil, err
	}
	n, ok := new(big.Int).SetString(f.NHex, 16)
	if !ok {
		return nil, errors.New("bad n_hex in " + path)
	}
	return &simple.Address{Name: f.Name, PublicKey: &rsa.PublicKey{N: n, E: f.E}}, nil
}

// selfSignedTLS returns a server config with a throwaway self-signed
// certificate and a client config that skips verification. The Perun wire
// layer authenticates the peers with RSA signed addresses, so TLS only
// encrypts the link.
func selfSignedTLS() (*tls.Config, *tls.Config, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "perunpay"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return nil, nil, err
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
	srv := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	cli := &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12} //nolint:gosec
	return srv, cli, nil
}
