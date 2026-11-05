package main

import (
	"encoding/binary"
	"net"
	"testing"
)

func TestSolicitationRegistration(t *testing.T) {
	source := net.ParseIP("2001:db8:1::2")
	target := net.ParseIP("2001:db8:1::1")
	mac, _ := net.ParseMAC("02:42:c0:a8:01:01")
	frame := solicitationFrame(source, target, mac)
	if got := solicitationMAC(frame, target); got != mac.String() {
		t.Fatalf("valid NS MAC = %q, want %s", got, mac)
	}
	// Independently check the ICMPv6 pseudo-header checksum for this vector.
	if got := binary.BigEndian.Uint16(frame[56:58]); got != 0x5a3b {
		t.Fatalf("NS checksum = %04x, want 5a3b", got)
	}
	for _, tc := range []struct {
		name string
		edit func([]byte)
	}{
		{"ordinary UDP", func(f []byte) { f[20] = 17 }},
		{"neighbor advertisement", func(f []byte) { f[54] = 136 }},
		{"wrong hop limit", func(f []byte) { f[21] = 64 }},
		{"invalid code", func(f []byte) { f[55] = 1 }},
		{"wrong target", func(f []byte) { f[77] = 3 }},
		{"missing source MAC option", func(f []byte) { f[78] = 2 }},
		{"zero option length", func(f []byte) { f[79] = 0 }},
		{"oversized option", func(f []byte) { f[79] = 2 }},
		{"MAC differs from Ethernet source", func(f []byte) { f[85]++ }},
		{"multicast source MAC", func(f []byte) { f[6] |= 1; f[80] |= 1 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bad := append([]byte(nil), frame...)
			tc.edit(bad)
			bad[56], bad[57] = 0, 0
			binary.BigEndian.PutUint16(bad[56:58], icmpChecksum(bad[14:]))
			if got := solicitationMAC(bad, target); got != "" {
				t.Fatalf("invalid NS accepted: %s", got)
			}
		})
	}
	for n := 0; n < len(frame); n++ {
		if got := solicitationMAC(frame[:n], target); got != "" {
			t.Fatalf("truncated NS (%d bytes) accepted", n)
		}
	}
	frame[56] ^= 1
	if solicitationMAC(frame, target) != "" {
		t.Fatal("bad checksum accepted")
	}
}
