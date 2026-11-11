import Foundation

func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ version: String) -> (numbers: [Int], prerelease: [Substring]?) {
        let version = version.hasPrefix("v") ? version.dropFirst() : version[...]
        let withoutBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let components = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = components[0].split(separator: ".").map { Int($0) ?? 0 }
        let prerelease = components.count > 1 ? components[1].split(separator: ".") : nil
        return (numbers, prerelease)
    }

    let lhs = parts(candidate)
    let rhs = parts(current)
    for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
        let l = index < lhs.numbers.count ? lhs.numbers[index] : 0
        let r = index < rhs.numbers.count ? rhs.numbers[index] : 0
        if l != r { return l > r }
    }
    switch (lhs.prerelease, rhs.prerelease) {
    case (nil, nil): return false
    case (nil, _): return true
    case (_, nil): return false
    case let (left?, right?):
        for (l, r) in zip(left, right) where l != r {
            switch (Int(l), Int(r)) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil): return false
            case (nil, _?): return true
            case (nil, nil): return l > r
            }
        }
        return left.count > right.count
    }
}
