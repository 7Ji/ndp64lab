package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var prefix net.IP
var subnet *net.IPNet

type sighting struct{ addr, mac string }

func command(args ...string) error {
	out, err := exec.Command("ip", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip %s: %w: %s", strings.Join(args, " "), err, out)
	}
	return nil
}

func watch(ifaceName string, found chan<- sighting, nsTarget net.IP) {
	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		log.Fatal(err)
	}
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, int((0x86dd<<8)&0xff00|0x86dd>>8))
	if err != nil {
		log.Fatal(err)
	}
	defer syscall.Close(fd)
	if err := syscall.Bind(fd, &syscall.SockaddrLinklayer{Protocol: 0xdd86, Ifindex: iface.Index}); err != nil {
		log.Fatal(err)
	}
	buf := make([]byte, 4096)
	for {
		n, from, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			log.Print(err)
			continue
		}
		if link, ok := from.(*syscall.SockaddrLinklayer); ok && link.Pkttype == syscall.PACKET_OUTGOING {
			continue
		}
		if s, ok := registration(buf[:n], nsTarget, subnet); ok {
			found <- s
		}
	}
}

// All sources, including the router's ::2, use this same acceptance path.
func registration(frame []byte, target net.IP, offered *net.IPNet) (sighting, bool) {
	if len(frame) < 54 || frame[12] != 0x86 || frame[13] != 0xdd || frame[14]>>4 != 6 {
		return sighting{}, false
	}
	source := net.IP(frame[22:38])
	if !offered.Contains(source) || source.Equal(offered.IP) || source.Equal(target) {
		return sighting{}, false
	}
	mac := solicitationMAC(frame, target)
	if mac == "" {
		return sighting{}, false
	}
	return sighting{source.String(), mac}, true
}

func checksum(data []byte) uint16 {
	var sum uint32
	for len(data) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}
	if len(data) == 1 {
		sum += uint32(data[0]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

func icmpChecksum(packet []byte) uint16 {
	pseudo := make([]byte, 40, len(packet))
	copy(pseudo, packet[8:40]) // IPv6 source and destination.
	binary.BigEndian.PutUint32(pseudo[32:36], uint32(len(packet)-40))
	pseudo[39] = 58
	return checksum(append(pseudo, packet[40:]...))
}

// Accept a direct ICMPv6 NS with a source link-layer address option. DAD
// (unspecified source) and sources outside the offered /64 are filtered by watch.
func solicitationMAC(frame []byte, target net.IP) string {
	if len(frame) < 14+40+32 {
		return ""
	}
	packet := frame[14:]
	length := 40 + int(binary.BigEndian.Uint16(packet[4:6]))
	if length > len(packet) || length < 72 || packet[6] != 58 || packet[7] != 255 {
		return ""
	}
	packet = packet[:length]
	if packet[40] != 135 || packet[41] != 0 || !net.IP(packet[48:64]).Equal(target) || icmpChecksum(packet) != 0 {
		return ""
	}
	for option := packet[64:]; len(option) >= 2; {
		size := int(option[1]) * 8
		if size == 0 || size > len(option) {
			return ""
		}
		if option[0] == 1 && size == 8 {
			mac := net.HardwareAddr(option[2:8])
			if mac[0]&1 != 0 || mac.String() != net.HardwareAddr(frame[6:12]).String() {
				return ""
			}
			return mac.String()
		}
		option = option[size:]
	}
	return ""
}

// Protocol 99 identifies only learner-owned routes. Deadlines contain Go's
// monotonic clock component; wall-clock adjustments cannot extend registrations.
const protocol = "99"

type registry struct {
	deadlines map[string]time.Time
	run       func(...string) error
	iface     string
	timeout   time.Duration
}

func (r *registry) remove(addr string) error {
	if err := r.run("-6", "route", "flush", "exact", addr+"/128", "dev", r.iface, "proto", protocol); err != nil {
		return err
	}
	return r.run("-6", "neigh", "flush", "to", addr, "dev", r.iface)
}
func (r *registry) learn(s sighting, now time.Time) error {
	if err := r.run("-6", "neigh", "replace", s.addr, "lladdr", s.mac, "nud", "stale", "dev", r.iface); err != nil {
		return err
	}
	if err := r.run("-6", "route", "replace", s.addr+"/128", "dev", r.iface, "proto", protocol); err != nil {
		return err
	}
	r.deadlines[s.addr] = now.Add(r.timeout)
	return nil
}
func (r *registry) expire(now time.Time) {
	for addr, deadline := range r.deadlines {
		if !now.Before(deadline) {
			if err := r.remove(addr); err != nil {
				log.Print(err)
			} else {
				delete(r.deadlines, addr)
			}
		}
	}
}
func (r *registry) cleanup() error {
	out, err := exec.Command("ip", "-6", "route", "show", "dev", r.iface, "proto", protocol).Output()
	if err != nil {
		return err
	}
	return r.clearRoutes(string(out))
}
func (r *registry) clearRoutes(out string) error {
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 {
			if err := r.remove(strings.TrimSuffix(fields[0], "/128")); err != nil {
				return err
			}
		}
	}
	return nil
}
func main() {
	if len(os.Args) != 5 {
		log.Fatal("usage: isp-ndp-learn PREFIX/64 ISP_ADDRESS INTERFACE TIMEOUT_SECONDS")
	}
	var err error
	prefix, subnet, err = net.ParseCIDR(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	ones, bits := subnet.Mask.Size()
	own := net.ParseIP(os.Args[2])
	seconds, err := strconv.Atoi(os.Args[4])
	if err != nil || seconds <= 0 || ones != 64 || bits != 128 || !prefix.Equal(subnet.IP) || own == nil || !subnet.Contains(own) {
		log.Fatal("invalid subscriber configuration")
	}
	r := registry{map[string]time.Time{}, command, os.Args[3], time.Duration(seconds) * time.Second}
	if err := r.cleanup(); err != nil {
		log.Fatal(err)
	}
	found := make(chan sighting, 256)
	go watch(r.iface, found, own)
	tick := time.NewTicker(time.Second)
	for {
		select {
		case s := <-found:
			if s.addr != own.String() {
				if err := r.learn(s, time.Now()); err != nil {
					log.Print(err)
				}
			}
		case now := <-tick.C:
			r.expire(now)
		}
	}
}
