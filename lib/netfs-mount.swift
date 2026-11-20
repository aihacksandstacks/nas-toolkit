// netfs-mount - mount an SMB URL with NetFS and never show UI.
//
// Finder (`open smb://...`) and `mount volume` both pop "Connect to Server"
// dialogs when a mount fails. NetFSMountURLSync with kNAUIOptionNoUI fails
// quietly instead, uses the credentials saved in the login Keychain, and
// still mounts under /Volumes/<share> without root.
//
// Build:  swiftc -O -o bin/nas-netfs-mount lib/netfs-mount.swift
// Usage:  nas-netfs-mount smb://user@host/share
// Exit:   0 mounted (prints mount path), 2 bad args, else NetFS error code

import Foundation
import NetFS

let args = CommandLine.arguments
guard args.count == 2, let url = URL(string: args[1]) else {
    FileHandle.standardError.write("usage: nas-netfs-mount smb://user@host/share\n".data(using: .utf8)!)
    exit(2)
}

let openOptions = NSMutableDictionary()
openOptions[kNAUIOptionKey] = kNAUIOptionNoUI

var mountpoints: Unmanaged<CFArray>?
let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil, openOptions, nil, &mountpoints)

if rc == 0 {
    if let mps = mountpoints?.takeRetainedValue() as? [String], let first = mps.first {
        print(first)
    }
    exit(0)
}
FileHandle.standardError.write("NetFS mount failed: \(rc)\n".data(using: .utf8)!)
exit(rc == 0 ? 1 : (rc > 0 && rc < 256 ? rc : 1))
