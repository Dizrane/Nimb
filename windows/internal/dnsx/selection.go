package dnsx

// includeAdapter decides whether a physical Wi-Fi or Ethernet adapter participates in a DNS operation. Enabling Smart DNS
// needs a live IPv4 connection; restoring static settings must include hardware whose connection or IPv4 binding is down.
func includeAdapter(up, hardware, ipv4Enabled, restoring bool) bool {
	return hardware && (restoring || (up && ipv4Enabled))
}
