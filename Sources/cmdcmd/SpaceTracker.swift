import AppKit

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> CFArray

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

enum SpaceType: Int {
    case user = 0
    case fullscreen = 4
    case system = 2
    case tiled = 5

    init(raw: Int) {
        self = SpaceType(rawValue: raw) ?? .user
    }
}

struct Space {
    let id: CGSSpaceID
    let uuid: String
    let type: SpaceType
    let displayUUID: String
    let isActive: Bool
}

struct SpaceWindow {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect
    let spaceID: CGSSpaceID?
}

final class SpaceTracker {
    private let cid = CGSMainConnectionID()

    func spaces() -> [Space] {
        let active = CGSGetActiveSpace(cid)
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }

        var result: [Space] = []
        for display in displays {
            let displayUUID = display["Display Identifier"] as? String ?? ""
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let id = space["id64"] as? UInt64 else { continue }
                let uuid = space["uuid"] as? String ?? ""
                let type = SpaceType(raw: (space["type"] as? Int) ?? 0)
                result.append(Space(
                    id: id,
                    uuid: uuid,
                    type: type,
                    displayUUID: displayUUID,
                    isActive: id == active
                ))
            }
        }
        return result
    }

    func windows() -> [SpaceWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }

        let ids = raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let spaceMap = spacesForWindows(ids)

        return raw.compactMap { dict in
            guard
                let id = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid = dict[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            let title = dict[kCGWindowName as String] as? String ?? ""
            let bounds = (dict[kCGWindowBounds as String] as? [String: CGFloat]).flatMap { b -> CGRect? in
                guard let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            } ?? .zero
            return SpaceWindow(
                windowID: id,
                ownerPID: pid,
                ownerName: owner,
                title: title,
                bounds: bounds,
                spaceID: spaceMap[id]
            )
        }
    }

    func fullscreenWindowSpaces() -> [CGWindowID: CGSSpaceID] {
        let fsIDs = Set(spaces().filter { $0.type == .fullscreen }.map { $0.id })
        guard !fsIDs.isEmpty else { return [:] }

        guard let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        let ids = raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }

        var result: [CGWindowID: CGSSpaceID] = [:]
        for id in ids {
            let arr = [NSNumber(value: id)] as CFArray
            let spacesArr = CGSCopySpacesForWindows(cid, 0x7, arr)
            if let nums = spacesArr as? [NSNumber],
               let match = nums.first(where: { fsIDs.contains($0.uint64Value) }) {
                result[id] = match.uint64Value
            }
        }
        return result
    }

    func activeSpace() -> CGSSpaceID {
        CGSGetActiveSpace(cid)
    }

    func orderedSpaceIDs() -> [CGSSpaceID] {
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        var result: [CGSSpaceID] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                if let id = space["id64"] as? UInt64 { result.append(id) }
            }
        }
        return result
    }

    func addWindows(_ windowIDs: [CGWindowID], toSpace spaceID: CGSSpaceID) {
        guard !windowIDs.isEmpty else { return }
        let wins = windowIDs.map { NSNumber(value: $0) } as CFArray
        let spaces = [NSNumber(value: spaceID)] as CFArray
        CGSAddWindowsToSpaces(cid, wins, spaces)
    }

    func removeWindows(_ windowIDs: [CGWindowID], fromSpace spaceID: CGSSpaceID) {
        guard !windowIDs.isEmpty else { return }
        let wins = windowIDs.map { NSNumber(value: $0) } as CFArray
        let spaces = [NSNumber(value: spaceID)] as CFArray
        CGSRemoveWindowsFromSpaces(cid, wins, spaces)
    }

    func switchTo(spaceID: CGSSpaceID) {
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return }
        for display in displays {
            guard
                let displayUUID = display["Display Identifier"] as? String,
                let spaces = display["Spaces"] as? [[String: Any]]
            else { continue }
            if spaces.contains(where: { ($0["id64"] as? UInt64) == spaceID }) {
                CGSManagedDisplaySetCurrentSpace(cid, displayUUID as CFString, spaceID)
                return
            }
        }
    }

    private func spacesForWindows(_ ids: [CGWindowID]) -> [CGWindowID: CGSSpaceID] {
        var map: [CGWindowID: CGSSpaceID] = [:]
        for id in ids {
            let arr = [NSNumber(value: id)] as CFArray
            let result = CGSCopySpacesForWindows(cid, 0x7, arr)
            if let spaces = result as? [NSNumber], let first = spaces.first {
                map[id] = first.uint64Value
            }
        }
        return map
    }
}
