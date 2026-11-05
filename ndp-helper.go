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

type sighting struct {
	addr string
	lan  int
	mac  string
}

func command(args ...string) error {
	out, err := exec.Command("ip", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip %s: %w: %s", strings.Join(args, " "), err, out)
	}
	return nil
}

func watch(lan int, found chan<- sighting, nsTarget net.IP) {
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
		if !subnet.Contains(ip) || ip.Equal(prefix) {
			continue
		}
		mac := ""
		if nsTarget != nil {
			mac = solicitationMAC(buf[:n], nsTarget)
			if mac == "" {
				continue
			}
		}
		found <- sighting{addr: ip.String(), lan: lan, mac: mac}
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
	isp := len(os.Args) > 1 && os.Args[1] == "isp"
	args := os.Args[1:]
	if isp {
		args = args[1:]
	}
	if len(args) != 3 {
		log.Fatal("usage: lab-ndp PREFIX/64 ISP_ADDRESS ISP_LINK_LOCAL | lab-ndp isp PREFIX/64 ISP_ADDRESS ethN")
	}
	var err error
	prefix, subnet, err = net.ParseCIDR(args[0])
	if err != nil {
		log.Fatal(err)
	}
	ones, bits := subnet.Mask.Size()
	upstream := net.ParseIP(args[1])
	if ones != 64 || bits != 128 || !prefix.Equal(subnet.IP) || upstream == nil || !subnet.Contains(upstream) || upstream.Equal(prefix) {
		log.Fatal("expected an IPv6 /64 network and an ISP address within it")
	}
	prefix = prefix.To16()
	if isp {
		port, err := strconv.Atoi(strings.TrimPrefix(args[2], "eth"))
		if err != nil || args[2] != fmt.Sprintf("eth%d", port) || port < 0 {
			log.Fatal("expected an ethN interface")
		}
		learnISPRoutes(upstream, port)
		return
	}
	gateway := net.ParseIP(args[2])
	if gateway == nil || gateway.To4() != nil || !gateway.IsLinkLocalUnicast() {
		log.Fatal("expected an IPv6 link-local ISP gateway")
	}

	if err := os.WriteFile("/proc/sys/net/ipv6/conf/all/forwarding", []byte("1"), 0644); err != nil {
		log.Fatal(err)
	}
	if err := command("-6", "route", "replace", upstream.String()+"/128", "via", gateway.String(), "dev", "eth0"); err != nil {
		log.Fatal(err)
	}
	if err := command("-6", "route", "replace", "unreachable", prefix.String()+"/64"); err != nil {
		log.Fatal(err)
	}
	wan, err := net.InterfaceByName("eth0")
	if err != nil {
		log.Fatal(err)
	}
	wanAddresses, err := wan.Addrs()
	if err != nil {
		log.Fatal(err)
	}
	for _, address := range wanAddresses {
		ip, _, err := net.ParseCIDR(address.String())
		if err == nil && subnet.Contains(ip) {
			if err := registerUpstream(ip, upstream); err != nil {
				log.Fatal(err)
			}
		}
	}
	for i := 0; i <= 8; i++ {
		if err := os.WriteFile(fmt.Sprintf("/proc/sys/net/ipv6/conf/eth%d/proxy_ndp", i), []byte("1"), 0644); err != nil {
			log.Fatal(err)
		}
	}
	found := make(chan sighting, 256)
	for i := 1; i <= 8; i++ {
		if err := command("-6", "neigh", "replace", "proxy", upstream.String(), "dev", fmt.Sprintf("eth%d", i)); err != nil {
			log.Fatal(err)
		}
		go watch(i, found, nil)
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
		if err := registerUpstream(net.ParseIP(s.addr), upstream); err != nil {
			log.Print(err)
			delete(known, s.addr) // Retry on the next sighting.
		}
		log.Printf("LAN%d %s", s.lan, s.addr)
	}
}

// Model the bad ISP: learn a host route and neighbor only from an NS for ::1.
func learnISPRoutes(own net.IP, port int) {
	found := make(chan sighting, 256)
	go watch(port, found, own)
	iface := fmt.Sprintf("eth%d", port)
	for s := range found {
		if s.addr == own.String() {
			continue
		}
		if err := command("-6", "neigh", "replace", s.addr, "lladdr", s.mac, "nud", "stale", "dev", iface); err != nil {
			log.Print(err)
			continue
		}
		if err := command("-6", "route", "replace", s.addr+"/128", "dev", iface); err != nil {
			log.Print(err)
			continue
		}
		log.Printf("NS %s %s on %s", s.addr, s.mac, iface)
	}
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

// Forwarded client traffic does not make Linux send NS using that client's
// source address. Register it explicitly with the ISP using the WAN MAC.
func registerUpstream(source, target net.IP) error {
	iface, err := net.InterfaceByName("eth0")
	if err != nil {
		return err
	}
	frame := solicitationFrame(source, target, iface.HardwareAddr)
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, 0xdd86)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	return syscall.Sendto(fd, frame, 0, &syscall.SockaddrLinklayer{Ifindex: iface.Index, Halen: 6, Addr: [8]byte{frame[0], frame[1], frame[2], frame[3], frame[4], frame[5]}})
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
