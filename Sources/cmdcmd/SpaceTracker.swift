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

    func activeSpace() -> CGSSpaceID {
        CGSGetActiveSpace(cid)
    }

    private func spacesForWindows(_ ids: [CGWindowID]) -> [CGWindowID: CGSSpaceID] {
        guard !ids.isEmpty else { return [:] }
        let arr = ids.map { NSNumber(value: $0) } as CFArray
        let result = CGSCopySpacesForWindows(cid, 0x7, arr)
        guard let nums = result as? [NSNumber], !nums.isEmpty else { return [:] }
        var map: [CGWindowID: CGSSpaceID] = [:]
        for (i, id) in ids.enumerated() where i < nums.count {
            map[id] = nums[i].uint64Value
        }
        return map
    }
}
