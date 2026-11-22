import SwiftUI
import PDFKit

struct SplitPagePreview: View {
    let page: PDFPage
    let firstOutputPage: Int
    let rightFirst: Bool
    @Binding var fraction: Double
    @State private var image: NSImage?

    private let leftTint = Color(red: 0.23, green: 0.64, blue: 0.85)
    private let rightTint = Color(red: 0.88, green: 0.53, blue: 0.18)

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit)
                    .overlay { division }
                    .clipped()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ObjectIdentifier(page)) {
            let bounds = page.bounds(for: .cropBox)
            let rotated = abs(page.rotation % 180) == 90
            let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = 1400 / max(size.width, size.height)
            image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        }
    }

    private var division: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let x = width * CGFloat(fraction)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    region(leftTint, number: firstOutputPage + (rightFirst ? 1 : 0), width: x)
                    region(rightTint, number: firstOutputPage + (rightFirst ? 0 : 1), width: width - x)
                }
                Path { line in
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: height))
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .allowsHitTesting(false)

                Color.clear
                    .frame(width: 30, height: height)
                    .contentShape(Rectangle())
                    .overlay {
                        AppIcon("arrow.left.and.right", tone: .accentColor)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
                            .allowsHitTesting(false)
                    }
                    .position(x: x, y: height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("split-preview"))
                            .onChanged { drag in
                                guard width > 0 else { return }
                                fraction = ScanProcessing.clampedSplitFraction(Double(drag.location.x / width))
                            }
                    )
                    .accessibilityHidden(true)
                    .help("左右拖动以调整分割线")
            }
            .coordinateSpace(name: "split-preview")
        }
    }

    private func region(_ tint: Color, number: Int, width: CGFloat) -> some View {
        Rectangle()
            .fill(tint.opacity(0.16))
            .overlay { Rectangle().strokeBorder(tint.opacity(0.8), lineWidth: 1) }
            .overlay(alignment: .top) {
                Text("第 \(number) 页")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
            .frame(width: width)
            .allowsHitTesting(false)
    }
}
