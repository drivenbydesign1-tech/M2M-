// Pure IP-classification logic lifted verbatim from m2m-source-fetch/index.ts
function ipv4Blocked(ip) {
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return "unparseable IPv4";
  const [a, b] = p;
  if (a === 0) return "0.0.0.0/8 this-network";
  if (a === 10) return "10.0.0.0/8 private";
  if (a === 127) return "127.0.0.0/8 loopback";
  if (a === 100 && b >= 64 && b <= 127) return "100.64.0.0/10 CGNAT";
  if (a === 169 && b === 254) return "169.254.0.0/16 link-local / cloud metadata";
  if (a === 172 && b >= 16 && b <= 31) return "172.16.0.0/12 private";
  if (a === 192 && b === 168) return "192.168.0.0/16 private";
  if (a === 192 && b === 0) return "192.0.0.0/24 IETF protocol assignments";
  if (a === 198 && (b === 18 || b === 19)) return "198.18.0.0/15 benchmarking";
  if (a >= 224) return ">=224.0.0.0 multicast / reserved";
  return null;
}
function ipv6Blocked(ip) {
  const s = ip.toLowerCase();
  if (s === "::" || s === "::1") return "IPv6 unspecified / loopback";
  const m = s.match(/^::(ffff:)?(\d+\.\d+\.\d+\.\d+)$/);
  if (m) return ipv4Blocked(m[2]) ?? "IPv4-mapped IPv6 address";
  const head = parseInt(s.split(":")[0] || "0", 16);
  if ((head & 0xfe00) === 0xfc00) return "fc00::/7 unique local";
  if ((head & 0xffc0) === 0xfe80) return "fe80::/10 link-local";
  if ((head & 0xff00) === 0xff00) return "ff00::/8 multicast";
  return null;
}

// expectBlocked = true means the address MUST be refused
const v4 = [
  ["169.254.169.254", true, "AWS/GCP/Azure metadata"],
  ["169.254.170.2",   true, "ECS task metadata"],
  ["127.0.0.1",       true, "loopback"],
  ["127.1.2.3",       true, "loopback range"],
  ["0.0.0.0",         true, "this-network"],
  ["10.1.2.3",        true, "RFC1918 /8"],
  ["172.16.0.1",      true, "RFC1918 /12 low"],
  ["172.31.255.254",  true, "RFC1918 /12 high"],
  ["192.168.1.1",     true, "RFC1918 /16"],
  ["100.64.0.1",      true, "CGNAT"],
  ["192.0.0.1",       true, "IETF assignments"],
  ["198.18.0.1",      true, "benchmarking"],
  ["224.0.0.1",       true, "multicast"],
  ["255.255.255.255", true, "broadcast"],
  ["999.1.1.1",       true, "unparseable"],
  ["8.8.8.8",         false, "public DNS"],
  ["104.18.32.7",     false, "public CDN"],
  ["172.32.0.1",      false, "just above RFC1918 /12"],
  ["172.15.255.254",  false, "just below RFC1918 /12"],
  ["100.63.255.255",  false, "just below CGNAT"],
  ["100.128.0.1",     false, "just above CGNAT"],
  ["192.167.1.1",     false, "just below 192.168/16"],
  ["223.255.255.255", false, "just below multicast"],
];
const v6 = [
  ["::1",                true, "loopback"],
  ["::",                 true, "unspecified"],
  ["fd00::1",            true, "unique local"],
  ["fc00::1",            true, "unique local low"],
  ["fe80::1",            true, "link-local"],
  ["ff02::1",            true, "multicast"],
  ["::ffff:169.254.169.254", true, "IPv4-mapped metadata"],
  ["::ffff:127.0.0.1",   true, "IPv4-mapped loopback"],
  ["::ffff:8.8.8.8",     true, "IPv4-mapped public (mapped form itself refused)"],
  ["2606:4700::1111",    false, "public"],
  ["2001:4860:4860::8888", false, "public"],
];
let fail = 0, n = 0;
for (const [ip, expectBlocked, note] of v4) {
  n++; const got = ipv4Blocked(ip) !== null;
  if (got !== expectBlocked) { fail++; console.log(`FAIL v4 ${ip} (${note}) expectedBlocked=${expectBlocked} got=${got}`); }
}
for (const [ip, expectBlocked, note] of v6) {
  n++; const got = ipv6Blocked(ip) !== null;
  if (got !== expectBlocked) { fail++; console.log(`FAIL v6 ${ip} (${note}) expectedBlocked=${expectBlocked} got=${got}`); }
}
console.log(`\nIP guard: ${n - fail}/${n} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
