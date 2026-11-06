'use strict';
import * as sock from 'socket';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { popen, readfile } from 'fs';

// odhcpd exclusively owns routing and NDP proxies. This process only discovers
// candidates, asks the kernel to resolve them, and refreshes ISP registrations.
let uci = cursor(), bus = connect();
let route = uci.get('network', 'registration', 'isp_route');
let target = split(uci.get('network', route, 'target'), '/')[0];
let prefix = slice(iptoarr(target), 0, 8);
let wan = bus.call('network.interface.' + uci.get('network', route, 'interface'), 'status', {}).l3_device;
if (!wan) die('WAN device is not ready\n');
let mac = map(split(trim(readfile('/sys/class/net/' + wan + '/address')), ':'), x => hex(x));
let sockets = [], devices = {}, candidates = {}, next = {}, probes = {}, known = [];
function jsoncmd(cmd) {
 let f = popen(cmd, 'r');
 let data = f.read('all'); f.close();
 return json(data) || [];
}
function shared(address) {
 let bytes = iptoarr(address);
 return bytes && length(bytes) == 16 && sprintf('%J', slice(bytes, 0, 8)) == sprintf('%J', prefix);
}
function bytes(data) { return join('', map(data, x => chr(x))); }
function address(data) { return arrtoip(map(split(data, ''), x => ord(x))); }
uci.foreach('dhcp', 'dhcp', cfg => {
 if (cfg.ndp != 'relay' || cfg.master == '1' || cfg.ra != 'server') return;
 let status = bus.call('network.interface.' + cfg.interface, 'status', {});
 let dev = status?.l3_device;
 if (!dev) return;
 devices[dev] = true;
 let fd = sock.create(sock.AF_PACKET, sock.SOCK_RAW, 0xdd86);
 if (!fd || !fd.bind({ family: sock.AF_PACKET, address: '', interface: dev, protocol: 0x86dd }))
  die('Cannot observe ' + dev + ': ' + sock.error() + '\n');
 push(sockets, [fd, sock.POLLIN, dev]);
});
function probe(addr, dev) {
 let fd = sock.create(sock.AF_INET6, sock.SOCK_RAW, 58);
 if (!fd) return;
 fd.setopt(sock.SOL_SOCKET, sock.SO_BINDTODEVICE, dev);
 fd.setopt(sock.SOL_SOCKET, sock.SO_DONTROUTE, true);
 fd.send(chr(128) + bytes([0,0,0,0,0,0,0]), sock.MSG_DONTROUTE,
  { family: sock.AF_INET6, address: addr, interface: dev });
 fd.close();
}
function register(addr) {
 let fd = sock.create(sock.AF_INET6, sock.SOCK_RAW, 58);
 if (!fd) { warn('Cannot open ICMPv6 socket: ' + sock.error() + '\n'); return false; }
 fd.setopt(sock.SOL_SOCKET, sock.SO_BINDTODEVICE, wan);
 fd.setopt(41, sock.IPV6_FREEBIND, true);
 fd.setopt(41, sock.IPV6_MULTICAST_HOPS, 255);
 fd.setopt(41, sock.IPV6_UNICAST_HOPS, 255);
 let ok = fd.bind({ family: sock.AF_INET6, address: addr });
 let t = iptoarr(target);
 let group = [255,2,0,0,0,0,0,0,0,0,0,1,255,t[13],t[14],t[15]];
 // Raw ICMPv6 sockets always let the kernel fill the checksum.
 let packet = bytes([135,0,0,0,0,0,0,0]) + bytes(t) + bytes([1,1]) + bytes(mac);
 let sent = ok ? fd.send(packet, 0, { family: sock.AF_INET6, address: arrtoip(group), interface: wan }) : null;
 if (sent != length(packet)) warn('Registration ' + addr + ': ' + sock.error() + '\n');
 fd.close();
 return sent == length(packet);
}
let last = -1;
while (true) {
 // poll() writes returned event flags into each supplied tuple.
 for (let spec in sockets) spec[1] = sock.POLLIN;
 for (let event in sock.poll(200, ...sockets) || []) {
  if (!(event[1] & sock.POLLIN)) continue;
  let from = {}, frame = event[0].recv(4096, 0, from);
  if (!frame || from.packet_type == sock.PACKET_OUTGOING || length(frame) < 54 || ord(frame, 14) >> 4 != 6) continue;
  // A previously confirmed MAC appearing on a different LAN is a physical
  // move. Retire its old neighbor immediately, before a stale proxy can
  // answer the returning client's DAD and falsely report a duplicate.
  let source_mac = join(':', map([6,7,8,9,10,11], i => sprintf('%02x', ord(frame, i))));
  for (let old in known) {
   if (old.lladdr != source_mac || old.dev == event[2]) continue;
   system(['ip', '-6', 'neigh', 'del', old.dst, 'dev', old.dev]);
   candidates[old.dst] = { dev: event[2], seen: time(), probe: 0 };
  }
  known = filter(known, old => old.lladdr != source_mac || old.dev == event[2]);
  let src = address(substr(frame, 22, 16));
  if (shared(src)) candidates[src] = { dev: event[2], seen: time(), probe: 0 };
  if (ord(frame, 20) == 58 && length(frame) >= 78 && ord(frame, 54) == 135 && src == '::') {
   let dst = address(substr(frame, 62, 16));
   if (shared(dst)) candidates[dst] = { dev: event[2], seen: time(), probe: 0 };
  }
 }
 let now = time();
 if (now == last) continue;
 last = now;
 let active = {};
 for (let link in jsoncmd('ip -j -6 addr show')) {
  if (link.ifname != wan && !devices[link.ifname]) continue;
  for (let a in link.addr_info || [])
   if (shared(a.local) && !a.tentative && !a.dadfailed) active[a.local] = true;
 }
 let neighbors = jsoncmd('ip -j -6 neigh show'), confirmed = {}, moved = {};
 known = filter(neighbors, n => devices[n.dev] && shared(n.dst) && n.lladdr && !match(join(' ', n.state || []), /FAILED|INCOMPLETE/));
 // A sighting on another LAN is only a candidate. Resolve it there before
 // discarding the previous neighbor; odhcpd reacts to the kernel events and
 // updates its routes/proxies, including removal of the proxy on the new LAN.
 for (let addr, c in candidates) {
  if (active[addr]) continue; // Router-owned addresses do not roam.
  for (let n in neighbors) {
   if (n.dst != addr || n.dev != c.dev || !n.lladdr || match(join(' ', n.state || []), /FAILED|INCOMPLETE/)) continue;
   for (let old in neighbors) {
    // odhcpd probes other LANs during NDP relay. Failed or incomplete probes
    // are not old client locations: deleting them churns valid proxies on
    // every other LAN while odhcpd processes the deletion and neighbor dump.
    if (old.dst == addr && old.dev != c.dev && devices[old.dev] &&
        old.lladdr && !match(join(' ', old.state || []), /FAILED|INCOMPLETE/)) {
     if (system(['ip', '-6', 'neigh', 'del', addr, 'dev', old.dev]) == 0)
      warn('Moved ' + addr + ' from ' + old.dev + ' to ' + c.dev + '\n');
     moved[addr] = c.dev;
    }
   }
  }
 }
 for (let n in neighbors) {
  if (!devices[n.dev] || !shared(n.dst) || (moved[n.dst] && moved[n.dst] != n.dev)) continue;
  let state = join(' ', n.state || []);
  if (n.lladdr && !match(state, /FAILED|INCOMPLETE/)) {
   active[n.dst] = true; confirmed[n.dst] = n.dev;
   // Sending through a STALE entry triggers kernel NUD. Removed addresses
   // eventually become FAILED instead of being registered indefinitely.
   if (!probes[n.dst] || now >= probes[n.dst]) {
    probe(n.dst, n.dev); probes[n.dst] = now + 5;
   }
  }
 }
 for (let addr, c in candidates) {
  if (now - c.seen > 60) { delete candidates[addr]; continue; }
  if ((!active[addr] || (confirmed[addr] && confirmed[addr] != c.dev)) && now - c.probe >= 3) { probe(addr, c.dev); c.probe = now; }
 }
 for (let addr in next) if (!active[addr]) { delete next[addr]; delete probes[addr]; }
 for (let addr in active) if (!next[addr] || now >= next[addr]) next[addr] = now + (register(addr) ? 5 : 3);
}
