package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

var prefix = net.ParseIP("fd42:6e64:7000:1::").To16()

type sighting struct {
	addr string
	lan  int
}

func command(args ...string) error {
	out, err := exec.Command("ip", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip %s: %w: %s", strings.Join(args, " "), err, out)
	}
	return nil
}

func watch(lan int, found chan<- sighting) {
	iface, err := net.InterfaceByName(fmt.Sprintf("eth%d", lan))
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
		if n < 54 || buf[12] != 0x86 || buf[13] != 0xdd || buf[14]>>4 != 6 {
			continue
		}
		ip := net.IP(buf[22:38])
		if !strings.HasPrefix(ip.String(), "fd42:6e64:7000:1:") || ip.Equal(prefix) {
			continue
		}
		found <- sighting{ip.String(), lan}
	}
}

func advertise(lan int) {
	iface, err := net.InterfaceByName(fmt.Sprintf("eth%d", lan))
	if err != nil {
		log.Fatal(err)
	}
	fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_RAW, syscall.IPPROTO_ICMPV6)
	if err != nil {
		log.Fatal(err)
	}
	defer syscall.Close(fd)
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_MULTICAST_IF, iface.Index); err != nil {
		log.Fatal(err)
	}
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_MULTICAST_HOPS, 255); err != nil {
		log.Fatal(err)
	}
	packet := make([]byte, 48)
	packet[0] = 134 // Router Advertisement
	packet[4] = 64  // Current hop limit
	binary.BigEndian.PutUint16(packet[6:8], 1800)
	packet[16] = 3 // Prefix Information option
	packet[17] = 4 // 32 bytes
	packet[18] = 64
	packet[19] = 0xc0 // on-link and autonomous
	binary.BigEndian.PutUint32(packet[20:24], 3600)
	binary.BigEndian.PutUint32(packet[24:28], 1800)
	copy(packet[32:], prefix)
	to := &syscall.SockaddrInet6{Addr: [16]byte{0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}, ZoneId: uint32(iface.Index)}
	for {
		if err := syscall.Sendto(fd, packet, 0, to); err != nil {
			log.Printf("RA eth%d: %v", lan, err)
		}
		time.Sleep(3 * time.Second)
	}
}

func main() {
	if err := os.WriteFile("/proc/sys/net/ipv6/conf/all/forwarding", []byte("1"), 0644); err != nil {
		log.Fatal(err)
	}
	if err := command("-6", "route", "replace", "fd42:6e64:7000:1::1/128", "via", "fe80::1", "dev", "eth0"); err != nil {
		log.Fatal(err)
	}
	if err := command("-6", "route", "replace", "unreachable", prefix.String()+"/64"); err != nil {
		log.Fatal(err)
	}
	for i := 0; i <= 8; i++ {
		if err := os.WriteFile(fmt.Sprintf("/proc/sys/net/ipv6/conf/eth%d/proxy_ndp", i), []byte("1"), 0644); err != nil {
			log.Fatal(err)
		}
	}
	found := make(chan sighting, 256)
	for i := 1; i <= 8; i++ {
		if err := command("-6", "neigh", "replace", "proxy", "fd42:6e64:7000:1::1", "dev", fmt.Sprintf("eth%d", i)); err != nil {
			log.Fatal(err)
		}
		go watch(i, found)
		go advertise(i)
	}
	known := make(map[string]int)
	for s := range found {
		if old, ok := known[s.addr]; ok && old == s.lan {
			continue
		}
		if old, ok := known[s.addr]; ok {
			log.Printf("address %s moved from LAN%d to LAN%d", s.addr, old, s.lan)
			_ = command("-6", "route", "del", s.addr+"/128", "dev", fmt.Sprintf("eth%d", old))
			_ = command("-6", "neigh", "del", "proxy", s.addr, "dev", fmt.Sprintf("eth%d", s.lan))
		}
		if err := command("-6", "route", "replace", s.addr+"/128", "dev", fmt.Sprintf("eth%d", s.lan)); err != nil {
			log.Print(err)
			continue
		}
		for i := 0; i <= 8; i++ {
			if i == s.lan {
				continue
			}
			if err := command("-6", "neigh", "replace", "proxy", s.addr, "dev", fmt.Sprintf("eth%d", i)); err != nil {
				log.Print(err)
			}
		}
		known[s.addr] = s.lan
		log.Printf("LAN%d %s", s.lan, s.addr)
	}
}
