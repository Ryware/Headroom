import Foundation
import AppKit
import Darwin
import os

enum DeleteMode: String, CaseIterable, Identifiable {
    case trash, permanent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trash: return "Move to Trash"
        case .permanent: return "Delete permanently (fast)"
        }
    }
    /// Verb for buttons: "Move to Trash…" / "Delete Permanently…"
    var actionLabel: String { self == .trash ? "Move to Trash…" : "Delete Permanently…" }
    var symbol: String { self == .trash ? "trash" : "flame" }
    var shortNote: String { self == .trash ? "Deleted items go to the Trash (recoverable)" : "Deleted items are removed immediately (no undo)" }
}

struct DeleteResult {
    var removedFiles = 0
    var removedDirectories = 0
    var freedBytes: Int64 = 0
    var errors: [(path: String, message: String)] = []
    /// Paths of the selected roots, for "Reveal in Finder" after a refusal.
    var roots: [String] = []
    /// True when the delete stopped because every removal was held and refused.
    var stalled = false
    /// The security products most likely responsible for a refusal; empty when none is installed.
    var blockedBy: [SecuritySuite] = []
}

final class DeleteCounters: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (done: 0, total: 0, bytes: Int64(0), current: ""))
    func setTotal(_ n: Int) { lock.withLock { $0.total = n } }
    func tick(bytes: Int64, count: Int = 1, current: String? = nil) {
        lock.withLock { $0.done += count; $0.bytes += bytes; if let current { $0.current = current } }
    }
    var snapshot: (done: Int, total: Int, bytes: Int64, current: String) { lock.withLock { $0 } }
}

/// Fast recursive remover.
///
/// 1. Each selected root is atomically renamed to a hidden sibling (`.disktree-rm-<id>`),
///    so from the user's point of view it vanishes instantly (rimraf's "move-remove" idea).
/// 2. Every directory in the subtree opens its own dirfd and unlinks its files with
///    `unlinkat(dirfd, name)` — no path walk per file. Directories are processed in
///    parallel across all cores (like rimraf's async posix strategy).
/// 3. Empty directories are removed deepest-first, each level in parallel.
struct Deleter {
    let mode: DeleteMode
    let counters: DeleteCounters
    /// Cancel from the UI, and stop on our own when every unlink is being held and refused.
    var control = DeleteControl()

    func delete(_ nodes: [FileNode]) async -> DeleteResult {
        switch mode {
        case .trash: return await trash(nodes)
        case .permanent: return await remove(nodes)
        }
    }

    // MARK: Trash

    private func trash(_ nodes: [FileNode]) async -> DeleteResult {
        var result = DeleteResult()
        result.roots = nodes.map(\.path)
        counters.setTotal(nodes.count)
        // NSWorkspace.recycle is the async, Finder-backed API; FileManager.trashItem can
        // block indefinitely when called off the main thread.
        let urls = nodes.map(\.url)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (moved, error): ([URL: URL], Error?) = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle(urls) { newURLs, err in
                    cont.resume(returning: (newURLs, err))
                }
            }
        }
        // A rename into the Trash takes microseconds. Seconds mean something outside the
        // kernel held the call before refusing it, which is what a ransomware shield does.
        let held = DispatchTime.now().uptimeNanoseconds - t0 >= control.slowThreshold
        for node in nodes {
            if moved[node.url] != nil {
                result.removedFiles += node.fileCount
                result.removedDirectories += node.directoryCount + (node.isDirectory ? 1 : 0)
                result.freedBytes += node.allocatedSize
            } else {
                result.errors.append((node.path, Self.explainTrashFailure(error, path: node.path, held: held)))
            }
            counters.tick(bytes: node.allocatedSize)
        }
        // A held refusal with a security product installed: name it and say where to allow Headroom.
        let suspects = SecuritySuites.suspects
        if held, !suspects.isEmpty, result.errors.contains(where: { $0.message == Self.trashBlockedMessage }) {
            result.blockedBy = suspects
            result.errors = result.errors.map { e in
                e.message == Self.trashBlockedMessage ? (e.path, SecuritySuites.trashBlockedMessage(for: suspects)) : e
            }
        }
        return result
    }

    /// Where the landing page explains how to allow Headroom in an antivirus or ransomware shield.
    static let trashHelpURL = URL(string: "https://headroom-app.org/#faq-trash-blocked")!

    static let trashBlockedMessage = "A security product (antivirus or ransomware shield such as AVG, Avast, Bitdefender or Norton) " +
        "held the request for seconds and then refused to let Headroom move this item to the Trash. " +
        "Allow Headroom in its settings, or use Reveal in Finder and delete the item there: Finder is allowed through."
    static let trashOwnerMessage = "This item, or the folder it is in, belongs to another user. " +
        "Delete it in Finder, which can ask for an administrator password."
    static let trashPrivacyMessage = "macOS refused to move this item to the Trash. If it is in Documents, Desktop or Downloads, " +
        "allow Headroom under System Settings › Privacy & Security › Files and Folders; otherwise delete it in Finder."

    /// Turns the Cocoa error from a refused trash move into a message that names the real cause.
    /// macOS reports an antivirus refusal, a privacy-folder denial and a root-owned item with
    /// the same words ("You don't have permission…"), and only the first can be fixed in Headroom's
    /// settings, so the user is sent to the right place. `held` says the call took seconds, the
    /// signature of an Endpoint Security client deciding before the kernel refused.
    static func explainTrashFailure(_ error: Error?, path: String, held: Bool) -> String {
        guard let error else { return "Could not move to Trash" }
        switch posixCode(of: error as NSError) {
        case EPERM where held: return trashBlockedMessage
        case EPERM: return trashPrivacyMessage
        case EACCES: return trashOwnerMessage
        default: return error.localizedDescription
        }
    }

    /// The errno behind a Cocoa file error, following the underlying-error chain.
    static func posixCode(of error: NSError) -> Int32? {
        var e: NSError? = error
        while let current = e {
            if current.domain == NSPOSIXErrorDomain { return Int32(current.code) }
            e = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    // MARK: Permanent, parallel

    /// A directory to empty: its (possibly renamed) path, file children, and depth.
    private struct DirJob {
        let path: String
        let files: [(name: String, bytes: Int64)]
        let depth: Int
    }

    private func remove(_ nodes: [FileNode]) async -> DeleteResult {
        var result = DeleteResult()
        result.roots = nodes.map(\.path)
        var dirJobs: [DirJob] = []
        var looseFiles: [(path: String, bytes: Int64)] = []   // selected roots that are files
        var totalFiles = 0
        var stashed: [(work: String, original: String)] = []

        for root in nodes {
            // Step 1: hide the root immediately.
            let workPath = Self.stash(root.path) ?? root.path
            if workPath != root.path { stashed.append((workPath, root.path)) }

            if !root.isDirectory {
                looseFiles.append((workPath, root.allocatedSize))
                totalFiles += 1
                continue
            }
            // Collect directory jobs with paths rebased onto the stashed root.
            root.walk { n in
                guard n.isDirectory else { return }
                let rel = String(n.path.dropFirst(root.path.count))
                let path = workPath + rel
                let files = n.children.filter { !$0.isDirectory }.map { ($0.name, $0.allocatedSize) }
                totalFiles += files.count
                dirJobs.append(DirJob(path: path, files: files, depth: n.url.pathComponents.count))
            }
        }
        counters.setTotal(totalFiles + dirJobs.count)

        let errorLock = OSAllocatedUnfairLock(initialState: [(path: String, message: String)]())
        let counters = self.counters
        let stall = control

        // Pre-flight: one unlink on its own before fanning out. A refusal that was held for
        // seconds (EPERM after a wait) means something outside the kernel is deciding; stop now
        // rather than queue thousands of files behind it.
        if !stall.aborted, let probe = Self.probeTarget(dirJobs: &dirJobs, looseFiles: &looseFiles) {
            let removed = await Task.detached(priority: .userInitiated) { () -> Bool in
                if let dir = probe.dir {
                    let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { return false }
                    defer { close(fd) }
                    return stall.timed(decisive: true) { Self.unlinkAt(fd, probe.name, dirPath: dir) }
                }
                return stall.timed(decisive: true) { Self.unlinkPath(probe.path) }
            }.value
            if removed { result.removedFiles += 1; result.freedBytes += probe.bytes }
            else { errorLock.withLock { $0.append((probe.path, String(cString: strerror(errno)))) } }
            counters.tick(bytes: removed ? probe.bytes : 0, current: probe.path)
        }
        let jobs = dirJobs
        let loose = looseFiles

        // Step 2: unlink files. One dirfd per directory, directories in parallel.
        let (files, bytes) = await Task.detached(priority: .userInitiated) { () -> (Int, Int64) in
            let ok = OSAllocatedUnfairLock(initialState: (0, Int64(0)))
            DispatchQueue.concurrentPerform(iterations: jobs.count + 1) { i in
                if i == jobs.count {
                    for f in loose {
                        if stall.aborted { counters.tick(bytes: 0); continue }
                        let removed = stall.timed { Self.unlinkPath(f.path) }
                        if removed { ok.withLock { $0.0 += 1; $0.1 += f.bytes } }
                        else { errorLock.withLock { $0.append((f.path, String(cString: strerror(errno)))) } }
                        counters.tick(bytes: removed ? f.bytes : 0, current: f.path)
                    }
                    return
                }
                let job = jobs[i]
                guard !job.files.isEmpty else { return }
                if stall.aborted { counters.tick(bytes: 0, count: job.files.count); return }
                let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else {
                    errorLock.withLock { $0.append((job.path, String(cString: strerror(errno)))) }
                    counters.tick(bytes: 0, count: job.files.count)
                    return
                }
                defer { close(fd) }
                var n = 0, b: Int64 = 0
                // Progress ticks per file, not per directory: when something outside the kernel
                // holds each unlink for seconds, a per-directory tick looks like a frozen app.
                for (index, f) in job.files.enumerated() {
                    if stall.aborted { counters.tick(bytes: 0, count: job.files.count - index); break }
                    let removed = stall.timed { Self.unlinkAt(fd, f.name, dirPath: job.path) }
                    if removed { n += 1; b += f.bytes }
                    else { errorLock.withLock { $0.append((job.path + "/" + f.name, String(cString: strerror(errno)))) } }
                    counters.tick(bytes: removed ? f.bytes : 0, current: job.path + "/" + f.name)
                }
                let removedCount = n
                let removedBytes = b
                ok.withLock { $0.0 += removedCount; $0.1 += removedBytes }
            }
            return ok.withLock { $0 }
        }.value
        result.removedFiles += files
        result.freedBytes += bytes

        // Step 3: directories, deepest first; each level in parallel.
        // Skipped after a stall: the directories are not empty, and the Foundation fallback
        // would walk them and wait on every refused unlink all over again.
        if !stall.aborted {
            let byDepth = Dictionary(grouping: jobs, by: \.depth)
            for depth in byDepth.keys.sorted(by: >) {
                let level = byDepth[depth]!
                let n = await Task.detached(priority: .userInitiated) { () -> Int in
                    let ok = OSAllocatedUnfairLock(initialState: 0)
                    DispatchQueue.concurrentPerform(iterations: level.count) { i in
                        let path = level[i].path
                        if rmdir(path) == 0 {
                            ok.withLock { $0 += 1 }
                        } else {
                            // Anything odd (leftover entries, flags) → Foundation fallback.
                            do {
                                try FileManager.default.removeItem(atPath: path)
                                ok.withLock { $0 += 1 }
                            } catch {
                                errorLock.withLock { $0.append((path, error.localizedDescription)) }
                            }
                        }
                    }
                    counters.tick(bytes: 0, count: level.count)
                    return ok.withLock { $0 }
                }.value
                result.removedDirectories += n
            }
        } else {
            counters.tick(bytes: 0, count: jobs.count)
        }

        // Whatever survived under a hidden stash name goes back to its real name, so a
        // partly failed delete never leaves the user's folder "missing".
        for s in stashed where access(s.work, F_OK) == 0 && access(s.original, F_OK) != 0 {
            _ = rename(s.work, s.original)
        }

        // Report errors under the original names, not the hidden stash names.
        result.errors = errorLock.withLock { $0 }.map { e in
            if let m = stashed.first(where: { e.path.hasPrefix($0.work) }) {
                return (m.original + e.path.dropFirst(m.work.count), e.message)
            }
            return e
        }
        if stall.cancelled {
            result.errors.insert((nodes.first?.path ?? "", Self.cancelMessage), at: 0)
        } else if stall.stalled {
            result.stalled = true
            result.blockedBy = SecuritySuites.suspects
            result.errors.insert((nodes.first?.path ?? "", SecuritySuites.stallMessage(for: result.blockedBy)), at: 0)
        }
        return result
    }

    /// The first file to try alone. It is taken out of its job so it is not unlinked twice.
    private struct ProbeTarget { let path: String; let name: String; let dir: String?; let bytes: Int64 }
    private static func probeTarget(dirJobs: inout [DirJob], looseFiles: inout [(path: String, bytes: Int64)]) -> ProbeTarget? {
        if let i = dirJobs.firstIndex(where: { !$0.files.isEmpty }) {
            let job = dirJobs[i], f = job.files[0]
            dirJobs[i] = DirJob(path: job.path, files: Array(job.files.dropFirst()), depth: job.depth)
            return ProbeTarget(path: job.path + "/" + f.name, name: f.name, dir: job.path, bytes: f.bytes)
        }
        if let f = looseFiles.first {
            looseFiles.removeFirst()
            return ProbeTarget(path: f.path, name: (f.path as NSString).lastPathComponent, dir: nil, bytes: f.bytes)
        }
        return nil
    }

    /// Generic wording; the real message names the installed product (see SecuritySuites).
    static var stallMessage: String { SecuritySuites.stallMessage(for: []) }
    static let cancelMessage = "Deleting was cancelled. Files already removed are gone; the rest are untouched."

    /// Lets the UI cancel a running delete, and notices when unlinks are being held for seconds
    /// and refused, which is what an Endpoint Security client (antivirus, ransomware shield)
    /// does when it blocks a process: each call waits out the kernel deadline (~10 s) and
    /// fails. Grinding through tens of thousands of files like that takes days, so after a
    /// run of consecutive slow refusals we stop and tell the user.
    final class DeleteControl: @unchecked Sendable {
        static let refusalsBeforeAbort = 6
        /// Nanoseconds a refused unlink must have taken to count as "held". A normal unlink
        /// takes microseconds; 1 s only happens when something outside the kernel is deciding.
        let slowThreshold: UInt64
        private let lock = OSAllocatedUnfairLock(initialState: (streak: 0, stalled: false, cancelled: false))

        init(slowThreshold: UInt64 = 1_000_000_000) { self.slowThreshold = slowThreshold }

        var aborted: Bool { lock.withLock { $0.stalled || $0.cancelled } }
        var stalled: Bool { lock.withLock { $0.stalled } }
        var cancelled: Bool { lock.withLock { $0.cancelled } }
        func cancel() { lock.withLock { $0.cancelled = true } }

        /// Runs one unlink, timing it, and returns its result. A success resets the streak, so a
        /// security product that scans slowly but allows the deletes never trips the abort.
        /// A `decisive` call (the pre-flight probe) stalls on a single held refusal, but only a
        /// permission-style one: an I/O timeout on a flaky volume is a different problem.
        func timed(decisive: Bool = false, _ unlink: () -> Bool) -> Bool {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let ok = unlink()
            let refused = errno
            let elapsed = DispatchTime.now().uptimeNanoseconds - t0
            lock.withLock {
                if ok { $0.streak = 0 }
                else if elapsed >= self.slowThreshold {
                    $0.streak += 1
                    if $0.streak >= Self.refusalsBeforeAbort { $0.stalled = true }
                    if decisive && (refused == EPERM || refused == EACCES) { $0.stalled = true }
                }
            }
            errno = refused
            return ok
        }
    }

    /// Atomically rename `path` to a hidden sibling so it disappears at once.
    /// Returns the new path, or nil if the rename was refused (then we delete in place).
    private static func stash(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let hidden = parent + "/.disktree-rm-" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
        return rename(path, hidden) == 0 ? hidden : nil
    }

    /// unlinkat(2) relative to an open directory. Retries once only if the file carried an
    /// immutable/append flag that we could clear; any other refusal (a security product's
    /// Endpoint Security client, say) is reported straight away rather than waited out twice.
    private static func unlinkAt(_ fd: Int32, _ name: String, dirPath: String) -> Bool {
        if unlinkat(fd, name, 0) == 0 { return true }
        let refused = errno
        guard refused == EPERM || refused == EACCES else { return false }
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, clearLockFlags(dirPath + "/" + name, st) else {
            errno = refused   // report the unlink's error, not the probe's
            return false
        }
        return unlinkat(fd, name, 0) == 0
    }

    private static func unlinkPath(_ path: String) -> Bool {
        if unlink(path) == 0 { return true }
        let refused = errno
        guard refused == EPERM || refused == EACCES else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, clearLockFlags(path, st) else {
            errno = refused
            return false
        }
        return unlink(path) == 0
    }

    /// Clears uchg/uappnd/schg/sappnd on `path`. Returns true only when there was a flag to clear.
    private static func clearLockFlags(_ path: String, _ st: stat) -> Bool {
        let locked = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        guard st.st_flags & locked != 0 else { return false }
        return lchflags(path, st.st_flags & ~locked) == 0
    }
}
