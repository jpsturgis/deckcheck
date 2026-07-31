import SwiftUI
import AVFoundation

/// Live-preview camera hosting the AVCaptureSession's preview layer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Rapid-fire capture: a stay-open camera with a live preview and a
/// card-framing guide. Each shutter tap fires `onCapture`; the camera stays up so you
/// can snap card after card. **Done** closes it. Because the preview is live, the
/// macro/sharpness settles on screen before you shoot — no post-capture surprise.
struct RapidCameraView: View {
    let onCapture: (UIImage) -> Void
    let onFinish: () -> Void

    @StateObject private var cam = CameraController()
    @State private var captured = 0
    @State private var flash = false
    @State private var previewSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if cam.authorized {
                CameraPreview(session: cam.session).ignoresSafeArea()

                // card-aspect framing guide — the same fractions the crop uses.
                GeometryReader { geo in
                    let w = geo.size.width * CardFrameCrop.guideWidthFraction
                    let h = CardFrameCrop.guideHeight(forWidth: w)
                    let guideRect = CGRect(x: geo.size.width / 2 - w / 2,
                                           y: geo.size.height / 2 - h / 2,
                                           width: w, height: h)

                    // Dim everything outside the guide so the framed card pops. The guide
                    // rounded-rect is punched out of a full-screen scrim via even-odd fill.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addRoundedRect(in: guideRect, cornerSize: CGSize(width: 14, height: 14))
                    }
                    .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.75), lineWidth: 2)
                        .frame(width: w, height: h)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .onAppear { previewSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in previewSize = newSize }

                    // hint box for the collector number (bottom-left of most cards)
                    let bw = w * 0.34, bh = h * 0.07, inset = w * 0.05
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: bw, height: bh)
                        .position(x: geo.size.width / 2 - w / 2 + inset + bw / 2,
                                  y: geo.size.height / 2 + h / 2 - inset - bh / 2)
                }
                .ignoresSafeArea()

                // brief flash overlay on capture, for feedback
                if flash { Color.white.opacity(0.5).ignoresSafeArea() }

                VStack {
                    HStack {
                        Button("Done", action: onFinish)
                            .font(.headline).foregroundStyle(.white)
                        Spacer()
                        if captured > 0 {
                            Text("\(captured) captured")
                                .font(.subheadline).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.black.opacity(0.45), in: Capsule())
                        }
                    }
                    .padding()

                    Spacer()

                    Text("Fill the frame with one card")
                        .font(.footnote).foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 8)

                    Button(action: shoot) {
                        Circle().fill(.white).frame(width: 74, height: 74)
                            .overlay(Circle().stroke(.white, lineWidth: 4).padding(3))
                    }
                    .padding(.bottom, 36)
                }
            } else {
                VStack(spacing: 14) {
                    Text(cam.unavailable
                         ? "Camera unavailable, or permission was denied.\nEnable it in Settings ▸ DeckCheck."
                         : "Starting camera…")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    Button("Done", action: onFinish).foregroundStyle(.white)
                }
                .padding()
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }

    private func shoot() {
        cam.capture { image in
            captured += 1
            onCapture(CardFrameCrop.crop(image, previewSize: previewSize))
        }
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeIn(duration: 0.12)) { flash = false }
        }
    }
}
