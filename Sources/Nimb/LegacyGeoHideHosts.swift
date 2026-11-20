import Foundation

/// Cleans up the hosts block left by the former GeoHide mode.
enum LegacyGeoHideHosts {
    private static let path = "/private/etc/hosts"
    static let start = "# BEGIN \(AppIdentity.name.uppercased()) GEOHIDE RECOVERY"
    static let end = "# END \(AppIdentity.name.uppercased()) GEOHIDE RECOVERY"

    static var hasEntries: Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .isoLatin1) else { return false }
        return contents.contains(start) || contents.contains(end)
    }

    static func remove() throws {
        guard hasEntries else { return }
        let flush = "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
        try DNSManager.runPrivileged("\(removalCommand(path: path)) && { \(flush); }")
        guard !hasEntries else { throw DNSError.failed("Не удалось удалить старые записи из hosts.") }
    }

    static func removalCommand(path: String) -> String {
        ["/usr/bin/perl", "-e", edit, path, start, end]
            .map(DNSManager.shellQuote).joined(separator: " ")
    }

    // Remove the marked block and preserve all other bytes. Recheck before replacing the file.
    private static let edit = #"""
    use strict;
    use warnings;
    use File::Basename qw(dirname);
    use File::Temp qw(tempfile);
    my ($path, $begin, $end) = @ARGV;
    sub read_hosts {
        die "hosts is not a regular file\n" if -l $path || !-f $path;
        open my $file, '<:raw', $path or die "read hosts: $!\n";
        local $/;
        return <$file> // '';
    }
    my $original = read_hosts();
    die "Unsupported hosts file encoding\n" if index($original, "\0") >= 0;
    my $body = $original;
    my $bom = ($body =~ s/\A(\xEF\xBB\xBF)//) ? $1 : '';
    my $starts = () = ($body =~ /\Q$begin\E/g);
    my $ends = () = ($body =~ /\Q$end\E/g);
    die "Invalid Nimb recovery block in hosts\n" unless $starts == $ends && $starts <= 1;
    my $removed = ($body =~ s/^\Q$begin\E\r?\n.*?^\Q$end\E\r?\n//ms);
    if ($starts && !$removed) {
        die "Invalid Nimb recovery block in hosts\n";
    }
    my $updated = $bom . $body;
    exit 0 if $updated eq $original;
    my ($temp, $name) = tempfile('.nimb-hosts.XXXXXXXX', DIR => dirname($path), UNLINK => 1);
    close $temp or die "close temporary hosts: $!\n";
    system('/bin/cp', '-p', $path, $name) == 0 or die "copy hosts attributes\n";
    open $temp, '>:raw', $name or die "open temporary hosts: $!\n";
    print {$temp} $updated or die "write hosts: $!\n";
    close $temp or die "save hosts: $!\n";
    die "hosts changed concurrently\n" if read_hosts() ne $original;
    rename $name, $path or die "replace hosts: $!\n";
    """#
}
