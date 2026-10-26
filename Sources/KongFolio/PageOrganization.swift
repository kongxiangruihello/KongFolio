import Foundation

enum PageSelectionKind: String, CaseIterable, Identifiable {
    case all = "全选", odd = "奇数页", even = "偶数页", inverted = "反选"
    var id: String { rawValue }
}

enum PageOrganization {
    /// Fronts are scanned first, followed by backs in reverse order.
    static func duplexOrder(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let fronts = (count + 1) / 2
        var order: [Int] = []
        for index in 0..<fronts {
            order.append(index)
            let back = count - 1 - index
            if back >= fronts { order.append(back) }
        }
        return order
    }
}

extension Workspace {
    func selectSidebarPages(_ pages:Set<Int>) {
        let valid=pages.filter { (0..<count).contains($0) }
        guard !busy,!valid.isEmpty,valid != selectedPages else { return }
        let added=valid.subtracting(selectedPages)
        selection=added.min() ?? (valid.contains(selection) ? selection : valid.min()!)
        selectedPages=valid;readingPoint=nil;navigationToken=UUID();scheduleRecovery()
    }
    func selectPages(_ kind: PageSelectionKind) {
        guard !busy, count > 0 else { return }
        let pages = Set(0..<count)
        let chosen: Set<Int>
        switch kind {
        case .all: chosen = pages
        case .odd: chosen = Set((0..<count).filter { $0 % 2 == 0 })
        case .even: chosen = Set((0..<count).filter { $0 % 2 == 1 })
        case .inverted: chosen = pages.subtracting(effectivePages)
        }
        // Workspace requires a current page; do not silently turn an empty choice into a different page.
        guard let first = chosen.min() else { status = "没有符合条件的页面，保留当前选择"; return }
        selectedPages = chosen
        selection = first
        readingPoint = nil
        navigationToken = UUID()
        scheduleRecovery()
        status = "已选择 \(chosen.count) 页"
    }

    func reverseSelectedPages() {
        guard !busy, effectivePages.count > 1 else { return }
        let chosen = effectivePages
        var order = Array(0..<count)
        for (position, source) in zip(chosen, chosen.reversed()) { order[position] = source }
        checkpoint()
        rebuild(order: order, selected: Set(chosen))
        status = "已反转 \(chosen.count) 个选中页的顺序，可撤销"
    }

    func restoreDuplexOrder() {
        guard !busy, count > 1 else { return }
        guard confirm("还原双面扫描页序？", "适用于先扫描全部正面，再倒序扫描背面的文件。例如：1、3、5、6、4、2 → 1、2、3、4、5、6。将处理整个文档，操作可撤销。", action: "还原页序") else { return }
        let order = PageOrganization.duplexOrder(count: count)
        guard order != Array(0..<count) else { return }
        let chosen = Set(effectivePages)
        checkpoint()
        rebuild(order: order, selected: Set(order.indices.filter { chosen.contains(order[$0]) }))
        status = "已还原双面扫描页序，可撤销"
    }
}
