import SwiftUI

struct ReadingPageControls: View {
    let pagination: ReadingPagination
    @Binding var page: Int
    @Binding var size: Int
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(pagination.countLabel).font(.caption)
                Spacer()
                Picker("每页", selection: $size) { ForEach([10, 20, 50], id: \.self) { Text("\($0) 条").tag($0) } }.fixedSize().accessibilityLabel("每页记录数")
            }
            HStack {
                Button { page = pagination.index - 1 } label: { Label("上一页", systemImage: "chevron.left") }.disabled(pagination.index == 0)
                Spacer()
                Text(pagination.label).font(.caption).accessibilityLabel("记录页码").accessibilityValue(pagination.label)
                Spacer()
                Button { page = pagination.index + 1 } label: { Label("下一页", systemImage: "chevron.right") }.disabled(pagination.index >= pagination.last)
            }
        }
    }
}
