package main

import (
	"encoding/binary"
	"net"
	"strings"
	"testing"
	"time"
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

func solicitationFrame(source, target net.IP, mac net.HardwareAddr) []byte {
	target = target.To16()
	frame := make([]byte, 14+40+32)
	copy(frame, []byte{0x33, 0x33, 0xff, target[13], target[14], target[15]})
	copy(frame[6:12], mac)
	binary.BigEndian.PutUint16(frame[12:14], 0x86dd)
	packet := frame[14:]
	packet[0], packet[6], packet[7] = 0x60, 58, 255
	binary.BigEndian.PutUint16(packet[4:6], 32)
	copy(packet[8:24], source.To16())
	copy(packet[24:40], []byte{0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, target[13], target[14], target[15]})
	packet[40] = 135
	copy(packet[48:64], target)
	packet[64], packet[65] = 1, 1
	copy(packet[66:72], mac)
	binary.BigEndian.PutUint16(packet[42:44], icmpChecksum(packet))
	return frame
}

// Deadlines are refreshed only by validated NS reception, independently of NUD.
func TestRegistrationDeadline(t *testing.T) {
	var calls []string
	r := registry{map[string]time.Time{}, func(args ...string) error { calls = append(calls, strings.Join(args, " ")); return nil }, "eth0", 15 * time.Second}
	now := time.Now()
	s := sighting{"2001:db8:1::2", "02:42:c0:a8:01:01"}
	if err := r.learn(s, now); err != nil {
		t.Fatal(err)
	}
	r.expire(now.Add(14 * time.Second))
	if len(r.deadlines) != 1 || len(calls) != 2 {
		t.Fatal("registration expired early")
	}
	if err := r.learn(s, now.Add(10*time.Second)); err != nil {
		t.Fatal(err)
	}
	r.expire(now.Add(16 * time.Second))
	if len(r.deadlines) != 1 {
		t.Fatal("NS did not refresh deadline")
	}
	r.expire(now.Add(25 * time.Second))
	if len(r.deadlines) != 0 || len(calls) != 6 {
		t.Fatalf("expiry failed: %v %v", r.deadlines, calls)
	}
	if !strings.Contains(calls[4], "route flush exact "+s.addr+"/128 dev eth0 proto 99") || !strings.Contains(calls[5], "neigh flush to "+s.addr) {
		t.Fatal(calls)
	}
}
func TestRestartCleanup(t *testing.T) {
	var calls []string
	r := registry{run: func(args ...string) error { calls = append(calls, strings.Join(args, " ")); return nil }, iface: "eth0"}
	if err := r.clearRoutes("2001:db8:1::2 dev eth0 proto 99\n2001:db8:1::3 dev eth0 proto 99\n"); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 4 {
		t.Fatal(calls)
	}
	for _, c := range calls {
		if !strings.Contains(c, "flush") {
			t.Fatal(c)
		}
	}
}

func TestOnlySolicitationsExtendDeadline(t *testing.T) {
	_, offered, _ := net.ParseCIDR("2001:db8:1::/64")
	target := net.ParseIP("2001:db8:1::1")
	mac, _ := net.ParseMAC("02:42:c0:a8:01:01")
	for _, source := range []string{"2001:db8:1::2", "2001:db8:1::1234"} {
		frame := solicitationFrame(net.ParseIP(source), target, mac)
		now := time.Now()
		r := registry{map[string]time.Time{}, func(...string) error { return nil }, "eth0", 15 * time.Second}
		s, ok := registration(frame, target, offered)
		if !ok {
			t.Fatal("valid source rejected", source)
		}
		if err := r.learn(s, now); err != nil {
			t.Fatal(err)
		}
		for _, kind := range []string{"data", "NA", "DAD", "outside prefix"} {
			noise := append([]byte(nil), frame...)
			switch kind {
			case "data":
				noise[20] = 17
			case "NA":
				noise[54] = 136
			case "DAD":
				copy(noise[22:38], net.IPv6zero.To16())
			case "outside prefix":
				copy(noise[22:38], net.ParseIP("2001:db8:2::2").To16())
			}
			noise[56], noise[57] = 0, 0
			binary.BigEndian.PutUint16(noise[56:58], icmpChecksum(noise[14:]))
			if s, ok := registration(noise, target, offered); ok {
				r.learn(s, now.Add(14*time.Second))
				t.Fatal("noise accepted", kind)
			}
		}
		r.expire(now.Add(15 * time.Second))
		if len(r.deadlines) != 0 {
			t.Fatal("noise postponed expiry")
		}
	}
}
