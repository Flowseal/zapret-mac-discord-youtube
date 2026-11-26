import AppKit
import QuartzCore
import SwiftUI

// Nimbus design system: colors, the offset-N mark, motion and small controls.
// Dark first, 1 px hairlines, 8 pt grid, one accent. Icon sources are in docs/brand.

// MARK: - Tokens

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Resolves to `dark` under Dark Aqua and to `light` otherwise.
    static func nimbus(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

enum NB {
    private static func c(_ light: UInt32, _ dark: UInt32, la: CGFloat = 1, da: CGFloat = 1) -> Color {
        Color(nsColor: .nimbus(light: NSColor(hex: light, alpha: la), dark: NSColor(hex: dark, alpha: da)))
    }

    static let panel = c(0xFBFBFC, 0x0F1012, la: 0.95, da: 0.82)
    static let solid = c(0xFCFCFD, 0x0F1012)
    static let raised = c(0x000000, 0xFFFFFF, la: 0.018, da: 0.025)
    static let line = c(0x000000, 0xFFFFFF, la: 0.075, da: 0.075)
    static let line2 = c(0x000000, 0xFFFFFF, la: 0.12, da: 0.12)
    static let hover = c(0x000000, 0xFFFFFF, la: 0.035, da: 0.045)
    static let sel = c(0x000000, 0xFFFFFF, la: 0.055, da: 0.07)
    static let kbd = c(0x000000, 0xFFFFFF, la: 0.045, da: 0.07)
    static let t1 = c(0x17181B, 0xEDEEF0)
    static let t2 = c(0x686C74, 0x8A8F98)
    static let t3 = c(0x9A9DA4, 0x5B5F67)
    static let accent = c(0x5E6AD2, 0x7C84FF)
    static let accentSoft = c(0x5E6AD2, 0x7C84FF, la: 0.11, da: 0.14)
    static let warn = c(0xC9801A, 0xE2A33E)
    static let err = c(0xD64545, 0xEB5C5C)
    static let scrim = c(0xFAFAFB, 0x08090A, la: 0.55, da: 0.55)
    static let shadow = Color.black.opacity(0.35)

    static let width: CGFloat = 360
    static let radius: CGFloat = 12
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 40

    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let label = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 12)
    static let hero = Font.system(size: 18, weight: .semibold)
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Motion

enum Motion {
    static var reduce: Bool { MotionSettings.reduceMotion }
    // Critically damped springs: fluid, no overshoot.
    static var snappy: Animation { reduce ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 1) }
    static var smooth: Animation { reduce ? .easeOut(duration: 0.14) : .spring(response: 0.34, dampingFraction: 1) }
    static var panel: Animation { reduce ? .easeOut(duration: 0.14) : .spring(response: 0.42, dampingFraction: 1) }
    static let staggerStep: Double = 0.022
}

/// Fades + lifts a row in when its page appears; rows reveal one after another.
struct StaggerReveal: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduce ? 0 : 6)
            .onAppear {
                let delay = Motion.reduce ? 0 : Double(min(index, 14)) * Motion.staggerStep
                withAnimation(Motion.smooth.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func reveal(_ index: Int) -> some View { modifier(StaggerReveal(index: index)) }
}

/// Offset + blur + opacity; used for page morphs and swapped text.
struct BlurShift: ViewModifier {
    let x: CGFloat
    let y: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: x, y: y).blur(radius: blur).opacity(opacity)
    }
}

extension AnyTransition {
    static func page(forward: Bool) -> AnyTransition {
        if Motion.reduce { return .opacity }
        let dx: CGFloat = 20
        return .asymmetric(
            insertion: .modifier(
                active: BlurShift(x: forward ? dx : -dx, y: 0, blur: 4, opacity: 0),
                identity: BlurShift(x: 0, y: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: BlurShift(x: forward ? -dx : dx, y: 0, blur: 4, opacity: 0),
                identity: BlurShift(x: 0, y: 0, blur: 0, opacity: 1)
            )
        )
    }

    /// Old text lifts and blurs out, new text rises in.
    static var textSwap: AnyTransition {
        if Motion.reduce { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: BlurShift(x: 0, y: 5, blur: 2, opacity: 0),
                identity: BlurShift(x: 0, y: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: BlurShift(x: 0, y: -5, blur: 2, opacity: 0),
                identity: BlurShift(x: 0, y: 0, blur: 0, opacity: 1)
            )
        )
    }
}

/// Text that cross-fades with a small vertical shift whenever its value changes.
struct SwapText: View {
    let text: String
    var font: Font = NB.body
    var color: Color = NB.t1

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .id(text)
                .transition(.textSwap)
        }
        .animation(Motion.snappy, value: text)
    }
}

/// Digits roll individually (SwiftUI numeric text transition).
struct RollingText: View {
    let text: String
    var font: Font = NB.mono(12.5)
    var color: Color = NB.t1

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(Motion.reduce ? .opacity : .numericText())
            .animation(Motion.smooth, value: text)
    }
}

// MARK: - The mark

enum MarkState: Equatable {
    case off, checking, on, problem
}

/// Morph parameters of the mark on its 16-unit grid.
struct MarkParams: Equatable {
    var fill: CGFloat      // 0…16, width of the solid fill wiped in from the left
    var outline: CGFloat   // 0…1, outline opacity
    var gap: CGFloat       // 0…1, break across the diagonal
    var band: CGFloat?     // left edge of the 6-unit sweep band while checking

    static func target(_ state: MarkState) -> MarkParams {
        switch state {
        case .off: return MarkParams(fill: 0, outline: 1, gap: 0, band: nil)
        case .checking: return MarkParams(fill: 0, outline: 1, gap: 0, band: nil)
        case .on: return MarkParams(fill: 16, outline: 0, gap: 0, band: nil)
        case .problem: return MarkParams(fill: 16, outline: 0, gap: 1, band: nil)
        }
    }
}

enum MarkGeometry {
    /// M2 4H5L11 9.333V2H14V12H11L5 6.667V14H2Z (y down)
    static let points: [CGPoint] = [
        CGPoint(x: 2, y: 4), CGPoint(x: 5, y: 4), CGPoint(x: 11, y: 9.333), CGPoint(x: 11, y: 2),
        CGPoint(x: 14, y: 2), CGPoint(x: 14, y: 12), CGPoint(x: 11, y: 12), CGPoint(x: 5, y: 6.667),
        CGPoint(x: 5, y: 14), CGPoint(x: 2, y: 14),
    ]
    static let diagonalAngle: CGFloat = 41.63 * .pi / 180
    static let sweepPeriod: Double = 1.15

    static func path() -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }

    /// Band position for a sweep that started at `start`; eased left → right, repeating.
    static func band(at time: TimeInterval, start: TimeInterval) -> CGFloat {
        let u = ((time - start).truncatingRemainder(dividingBy: sweepPeriod)) / sweepPeriod
        let e = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        return CGFloat(-6 + 22 * e)
    }

    /// Draws the mark into a y-down context whose 16×16 grid maps to `rect`.
    static func draw(in ctx: CGContext, rect: CGRect, color: CGColor, params: MarkParams) {
        let s = rect.width / 16
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: s, y: s)
        let shape = path()
        if params.outline > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(min(1, params.outline))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(1.2)
            ctx.setLineJoin(.miter)
            ctx.addPath(shape)
            ctx.strokePath()
            ctx.restoreGState()
        }
        var regions: [CGRect] = []
        if params.fill > 0.001 { regions.append(CGRect(x: 0, y: 0, width: min(16, params.fill), height: 16)) }
        if let band = params.band { regions.append(CGRect(x: band, y: 0, width: 6, height: 16)) }
        if !regions.isEmpty {
            ctx.saveGState()
            if params.gap > 0.001 {
                // even-odd clip: everything except a rotated slot across the diagonal
                let clip = CGMutablePath()
                clip.addRect(CGRect(x: -2, y: -2, width: 20, height: 20))
                let w = 2.2 * params.gap
                let slot = CGRect(x: -w / 2, y: -1.75, width: w, height: 3.5)
                let t = CGAffineTransform(translationX: 8, y: 8).rotated(by: diagonalAngle)
                clip.addRect(slot, transform: t)
                ctx.addPath(clip)
                ctx.clip(using: .evenOdd)
            }
            ctx.clip(to: regions)
            ctx.setFillColor(color)
            ctx.addPath(shape)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Template image for the menu bar (macOS tints it for light/dark/highlighted bars).
    static func templateImage(_ params: MarkParams, pointSize: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset: CGFloat = pointSize * 0.03
            draw(in: ctx, rect: rect.insetBy(dx: inset, dy: inset), color: NSColor.black.cgColor, params: params)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Nimbus"
        return image
    }
}

/// Animatable SwiftUI mark; `checking` sweeps continuously, other morphs spring.
struct MarkView: View {
    let state: MarkState
    var size: CGFloat = 16
    var color: Color = NB.t1

    @State private var sweepStart = Date().timeIntervalSinceReferenceDate

    var body: some View {
        let target = MarkParams.target(state)
        TimelineView(.animation(minimumInterval: nil, paused: state != .checking || Motion.reduce)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let band: CGFloat? = state == .checking ? (Motion.reduce ? 5 : MarkGeometry.band(at: now, start: sweepStart)) : nil
            MarkShapeView(fill: target.fill, outline: target.outline, gap: target.gap, band: band, color: color)
                .frame(width: size, height: size)
        }
        .animation(Motion.smooth, value: state)
        .onChange(of: state) { _, newValue in
            if newValue == .checking { sweepStart = Date().timeIntervalSinceReferenceDate }
        }
        .accessibilityLabel("Nimbus")
    }
}

private struct MarkShapeView: View, Animatable {
    var fill: CGFloat
    var outline: CGFloat
    var gap: CGFloat
    var band: CGFloat?
    let color: Color

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(fill, AnimatablePair(outline, gap)) }
        set {
            fill = newValue.first
            outline = newValue.second.first
            gap = newValue.second.second
        }
    }

    var body: some View {
        Canvas { context, size in
            var ctx = context
            ctx.scaleBy(x: size.width / 16, y: size.height / 16)
            let shape = Path(MarkGeometry.path())
            if outline > 0.001 {
                var stroke = ctx
                stroke.opacity = Double(min(1, outline))
                stroke.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .miter))
            }
            var regions = Path()
            if fill > 0.001 { regions.addRect(CGRect(x: 0, y: 0, width: min(16, fill), height: 16)) }
            if let band { regions.addRect(CGRect(x: band, y: 0, width: 6, height: 16)) }
            guard !regions.isEmpty else { return }
            var solid = ctx
            if gap > 0.001 {
                var clip = Path(CGRect(x: -2, y: -2, width: 20, height: 20))
                let w = 2.2 * min(1, gap)
                let slot = Path(CGRect(x: -w / 2, y: -1.75, width: w, height: 3.5))
                    .applying(CGAffineTransform(translationX: 8, y: 8).rotated(by: MarkGeometry.diagonalAngle))
                clip.addPath(slot)
                solid.clip(to: clip, style: FillStyle(eoFill: true))
            }
            solid.clip(to: regions)
            solid.fill(shape, with: .color(color))
        }
    }
}

/// Drives the menu-bar glyph: springs between states at display rate, idles when settled.
/// Ticks come from a display link on the status button, so frames line up with the screen's refresh
/// (60 or 120 Hz) instead of drifting against it like a 60 Hz Timer did.
final class StatusGlyphAnimator: NSObject {
    private weak var button: NSStatusBarButton?
    private var link: CADisplayLink?
    private var current = MarkParams.target(.off)
    private var velocity = (fill: CGFloat(0), outline: CGFloat(0), gap: CGFloat(0))
    private var state: MarkState = .off
    private var sweepStart: TimeInterval = 0
    private var lastTick: TimeInterval = 0

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        button.image = MarkGeometry.templateImage(current)
        button.imagePosition = .imageOnly
    }

    func set(_ next: MarkState) {
        guard next != state else { return }
        let previous = state
        state = next
        if next == .checking {
            sweepStart = CACurrentMediaTime()
        }
        if previous == .checking, next != .checking, let band = current.band {
            // continue the wipe from where the sweep band currently is
            current.fill = max(current.fill, min(16, band + 6))
        }
        current.band = nil
        if Motion.reduce {
            current = MarkParams.target(next)
            if next == .checking { current.band = 5 }
            render()
            stop()
            return
        }
        start()
    }

    private func start() {
        guard link == nil, let button else { return }
        lastTick = CACurrentMediaTime()
        let l = button.displayLink(target: self, selector: #selector(displayTick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        tick(now: link.targetTimestamp)
    }

    private func tick(now: TimeInterval) {
        let dt = CGFloat(min(1.0 / 30.0, max(1.0 / 240.0, now - lastTick)))
        lastTick = now
        let target = MarkParams.target(state)
        // critically damped spring, response 0.34 s
        let omega = 2 * CGFloat.pi / 0.34
        func step(_ x: inout CGFloat, _ v: inout CGFloat, _ goal: CGFloat) {
            let a = -omega * omega * (x - goal) - 2 * omega * v
            v += a * dt
            x += v * dt
        }
        step(&current.fill, &velocity.fill, target.fill)
        step(&current.outline, &velocity.outline, target.outline)
        step(&current.gap, &velocity.gap, target.gap)
        current.band = state == .checking ? MarkGeometry.band(at: now, start: sweepStart) : nil
        render()
        let settled = abs(current.fill - target.fill) < 0.02 && abs(current.outline - target.outline) < 0.005
            && abs(current.gap - target.gap) < 0.005 && abs(velocity.fill) < 0.05
        if settled && state != .checking {
            current = target
            velocity = (0, 0, 0)
            render()
            stop()
        }
    }

    private func render() {
        var params = current
        params.fill = max(0, min(16, params.fill))
        params.outline = max(0, min(1, params.outline))
        params.gap = max(0, min(1, params.gap))
        button?.image = MarkGeometry.templateImage(params)
    }
}

// MARK: - Controls

struct Keycap: View {
    let keys: [String]

    init(_ keys: String...) { self.keys = keys }
    init(keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NB.t2)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(NB.kbd, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(NB.line, lineWidth: 1))
            }
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(NB.line).frame(height: 1)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(pulsing && dim ? 0.35 : 1)
            .animation(Motion.snappy, value: color)
            .onAppear { restartPulse() }
            .onChange(of: pulsing) { _, _ in restartPulse() }
    }

    private func restartPulse() {
        guard pulsing, !Motion.reduce else {
            dim = false
            return
        }
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// Track + knob switch with a critically damped glide; the knob stretches while pressed.
struct NimbusSwitch: View {
    let isOn: Bool
    var large = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        let w: CGFloat = large ? 38 : 30
        let h: CGFloat = large ? 22 : 18
        let knob: CGFloat = h - 4
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? NB.accent : NB.line2)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .frame(width: knob, height: knob)
                    .padding(2)
            }
            .frame(width: w, height: h)
            .animation(Motion.snappy, value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "включено" : "выключено")
    }
}

/// Dense 32 pt row with hover/selection fill.
struct RowButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        RowChrome(selected: selected, pressed: configuration.isPressed) { configuration.label }
    }
}

struct RowChrome<Content: View>: View {
    var selected = false
    var pressed = false
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) { content() }
            .font(NB.body)
            .foregroundStyle(NB.t1)
            .padding(.horizontal, 10)
            .frame(height: NB.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pressed ? NB.sel : (selected || hovering ? NB.hover : Color.clear))
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.08), value: hovering)
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String = ""

    var body: some View {
        HStack {
            Text(title).font(NB.label).foregroundStyle(NB.t2)
            Spacer(minLength: 8)
            if !trailing.isEmpty {
                Text(trailing).font(NB.mono(11)).foregroundStyle(NB.t3).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 30, alignment: .bottom)
        .padding(.bottom, 4)
    }
}

struct RowIcon: View {
    let name: String
    var color: Color = NB.t2

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12.5, weight: .regular))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
    }
}

/// Drop shadow drawn by Core Animation from a fixed rounded-rect path. SwiftUI's `.shadow` blurs the
/// view's own pixels, so it was recomputed on every frame of every animation inside the panel;
/// this one is only redrawn when the size changes.
struct ShapeShadow: NSViewRepresentable {
    struct Layer {
        var opacity: Float
        var radius: CGFloat
        var y: CGFloat
    }

    var cornerRadius: CGFloat
    var layers: [Layer]

    func makeNSView(context: Context) -> ShadowHost { ShadowHost() }

    func updateNSView(_ view: ShadowHost, context: Context) {
        view.configure(cornerRadius: cornerRadius, layers: layers)
    }
}

final class ShadowHost: NSView {
    private var cornerRadius: CGFloat = 0
    private var shadows: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(cornerRadius: CGFloat, layers: [ShapeShadow.Layer]) {
        self.cornerRadius = cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while shadows.count < layers.count {
            let l = CALayer()
            l.shadowColor = NSColor.black.cgColor
            layer?.addSublayer(l)
            shadows.append(l)
        }
        for (l, spec) in zip(shadows, layers) {
            l.shadowOpacity = spec.opacity
            l.shadowRadius = spec.radius
            l.shadowOffset = CGSize(width: 0, height: -spec.y) // AppKit layers are y-up
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = min(cornerRadius, bounds.width / 2, bounds.height / 2)
        let path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        for l in shadows {
            l.frame = bounds
            l.shadowPath = path
        }
        CATransaction.commit()
    }
}

/// Visual effect material behind the panel tint.
struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 40-bar latency history; bars grow in left → right, the newest bar is accented.
struct LatencyBars: View {
    let samples: [Double]
    let alert: Bool
    @State private var grown = false

    var body: some View {
        let count = 40
        let values = Array(samples.suffix(count))
        let padded = Array(repeating: Double.nan, count: max(0, count - values.count)) + values
        let finite = values.filter { $0.isFinite }
        let lo = max(0, (finite.min() ?? 0) - 20)
        let hi = max(lo + 40, finite.max() ?? 100)
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let v = padded[i]
                let last = i == count - 1
                let h: CGFloat = v.isFinite ? 3 + CGFloat((min(v, hi) - lo) / (hi - lo)) * 23 : 2
                BarShape(height: grown ? h : 2)
                    .fill(last && v.isFinite ? (alert ? NB.warn : NB.accent) : NB.line2)
                    .frame(width: 4, height: 26)
                    .animation(Motion.smooth.delay(Motion.reduce ? 0 : Double(i) * 0.014), value: grown)
                    .animation(Motion.smooth, value: h)
                if i < count - 1 { Spacer(minLength: 0) }
            }
        }
        .frame(height: 26, alignment: .bottom)
        .onAppear { grown = true }
    }
}

/// A bottom-aligned bar whose height animates as path data, so growing bars don't re-run layout every frame.
private struct BarShape: Shape {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let h = min(max(height, 0), rect.height)
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h), cornerRadius: min(1, h / 2), style: .continuous)
    }
}

/// Small arc spinner used while a diagnostic check is running.
struct ArcSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: Motion.reduce)) { t in
            let angle = Motion.reduce ? 0 : (t.date.timeIntervalSinceReferenceDate * 480).truncatingRemainder(dividingBy: 360)
            ZStack {
                Circle().stroke(NB.line2, lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.25).stroke(NB.t2, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 12, height: 12)
        }
        .frame(width: 16, height: 16)
    }
}
