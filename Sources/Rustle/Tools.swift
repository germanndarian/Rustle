import AppKit
import QuartzCore

enum EquippedTool: Equatable {
    case none, rake, blower

    var kind: ToolKind? {
        switch self {
        case .none: return nil
        case .rake: return .rake
        case .blower: return .blower
        }
    }
}

/// What the leaf scenes need to know about the tool each frame.
struct ToolInput {
    var tool = EquippedTool.none
    /// Mouse button held: raking, or the blower's trigger pulled.
    var pressed = false
    /// +1 facing right, -1 facing left. Follows the direction the mouse last moved.
    var facing: CGFloat = 1
    /// How far the blower's nozzle points down, in radians.
    var blowerAngle: CGFloat = 0.55
}

/// Equipping a tool puts a nearly invisible window over every display that catches the mouse,
/// hides the cursor and draws the tool in its place. Esc, the menu, or switching apps puts it away.
@MainActor
final class ToolController {
    private(set) var input = ToolInput()
    var onChange: (() -> Void)?

    private var windows: [ToolWindow] = []
    private var facingDrift: CGFloat = 0
    private var resignObserver: NSObjectProtocol?

    var equipped: EquippedTool { input.tool }

    func toggle(_ tool: EquippedTool) {
        equip(input.tool == tool ? .none : tool)
    }

    func equip(_ tool: EquippedTool) {
        guard tool != input.tool else { return }
        tearDown()
        input.tool = tool
        input.pressed = false
        if let kind = tool.kind { setUp(kind) }
        onChange?()
    }

    private func setUp(_ kind: ToolKind) {
        windows = NSScreen.screens.map { screen in
            let window = ToolWindow(screen: screen, sprite: ToolArt.sprite(kind, scale: screen.backingScaleFactor), controller: self)
            window.orderFrontRegardless()
            return window
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let home = windows.first { $0.frame.contains(mouse) } ?? windows.first
        home?.makeKey()
        moved(to: mouse, dx: 0)
        home?.toolView.showHint(kind == .rake
            ? "Rake: hold the mouse button and drag through the leaves. Esc puts it away."
            : "Leaf blower: hold the mouse button to blow, scroll to aim. Esc puts it away.")
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.equip(.none) }
        }
    }

    private func tearDown() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
    }

    // MARK: Events from the tool windows

    fileprivate func moved(to global: CGPoint, dx: CGFloat) {
        // Turn around only after a deliberate move the other way.
        facingDrift = facingDrift * 0.85 + dx
        if facingDrift * input.facing < -14 {
            input.facing = -input.facing
            facingDrift = 0
        }
        for window in windows { window.toolView.place(at: global, input: input) }
    }

    fileprivate func setPressed(_ pressed: Bool) {
        input.pressed = pressed
        for window in windows { window.toolView.place(at: NSEvent.mouseLocation, input: input) }
    }

    fileprivate func scrolled(by delta: CGFloat) {
        guard input.tool == .blower else { return }
        input.blowerAngle = min(max(input.blowerAngle - delta * 0.012, 0), 1.2)
        for window in windows { window.toolView.place(at: NSEvent.mouseLocation, input: input) }
    }
}

// MARK: - Window and view

private final class ToolWindow: NSWindow {
    let toolView: ToolView

    init(screen: NSScreen, sprite: ToolSprite, controller: ToolController) {
        toolView = ToolView(frame: CGRect(origin: .zero, size: screen.frame.size), sprite: sprite, controller: controller)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Above the Dock so the pile behind it can be raked too; the menu bar stays usable.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        sharingType = .none
        contentView = toolView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ToolView: NSView {
    private let sprite: ToolSprite
    private weak var controller: ToolController?
    private let toolLayer = CALayer()
    private let hintLayer = CALayer()
    private let hintText = CATextLayer()
    private static let hintFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private var lastX: CGFloat?

    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    init(frame: CGRect, sprite: ToolSprite, controller: ToolController) {
        self.sprite = sprite
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        // Not quite transparent, so the window server sends clicks here instead of to the app below.
        layer?.backgroundColor = CGColor(gray: 0, alpha: 0.005)

        toolLayer.contents = sprite.image
        toolLayer.contentsScale = CGFloat(sprite.image.width) / max(1, sprite.pointSize.width)
        toolLayer.bounds = CGRect(origin: .zero, size: sprite.pointSize)
        toolLayer.anchorPoint = CGPoint(x: sprite.hotspot.x / sprite.pointSize.width, y: sprite.hotspot.y / sprite.pointSize.height)
        toolLayer.isHidden = true
        layer?.addSublayer(toolLayer)

        hintLayer.backgroundColor = CGColor(red: 0.12, green: 0.08, blue: 0.06, alpha: 0.82)
        hintLayer.cornerRadius = 10
        hintLayer.opacity = 0
        hintText.font = Self.hintFont
        hintText.fontSize = Self.hintFont.pointSize
        hintText.foregroundColor = CGColor(gray: 1, alpha: 0.95)
        hintText.alignmentMode = .center
        hintText.contentsScale = 2
        hintLayer.addSublayer(hintText)
        layer?.addSublayer(hintLayer)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.blankCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.blankCursor.set()
    }

    func showHint(_ text: String) {
        let textWidth = NSAttributedString(string: text, attributes: [.font: Self.hintFont]).size().width
        let width = min(bounds.width - 40, ceil(textWidth) + 36)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hintLayer.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 96, width: width, height: 34)
        hintText.frame = CGRect(x: 0, y: 8, width: width, height: 18)
        hintText.string = text
        hintLayer.opacity = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.8)
            self?.hintLayer.opacity = 0
            CATransaction.commit()
        }
    }

    /// Draws the tool with its working point on the cursor.
    func place(at global: CGPoint, input: ToolInput) {
        guard let window else { return }
        let local = CGPoint(x: global.x - window.frame.minX, y: global.y - window.frame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toolLayer.isHidden = !bounds.insetBy(dx: -200, dy: -200).contains(local)
        toolLayer.position = local
        var transform = CATransform3DMakeScale(input.facing, 1, 1)
        switch input.tool {
        case .blower:
            // The art points right; aim the nozzle down toward the leaves.
            transform = CATransform3DConcat(transform, CATransform3DMakeRotation(-input.facing * input.blowerAngle, 0, 0, 1))
            if input.pressed {
                let shake = CATransform3DMakeTranslation(CGFloat.random(in: -0.6...0.6), CGFloat.random(in: -0.6...0.6), 0)
                transform = CATransform3DConcat(transform, shake)
            }
        case .rake:
            // The art's handle leans right, trailing a rake pulled to the left; mirror it when pulling right,
            // and tip it a little further over while it's dragging.
            transform = CATransform3DMakeScale(-input.facing, 1, 1)
            if input.pressed {
                transform = CATransform3DConcat(transform, CATransform3DMakeRotation(input.facing * 0.12, 0, 0, 1))
            }
        case .none:
            break
        }
        toolLayer.transform = transform
        CATransaction.commit()
    }

    private func handleMove(_ event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        let global = CGPoint(x: local.x + window.frame.minX, y: local.y + window.frame.minY)
        controller?.moved(to: global, dx: event.deltaX)
        Self.blankCursor.set()
    }

    override func mouseMoved(with event: NSEvent) { handleMove(event) }
    override func mouseDragged(with event: NSEvent) { handleMove(event) }
    override func rightMouseDragged(with event: NSEvent) { handleMove(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        controller?.setPressed(true)
        handleMove(event)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.setPressed(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.equip(.none)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.scrolled(by: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            controller?.equip(.none)
        } else {
            super.keyDown(with: event)
        }
    }
}
