/*
 * VirtualJoystick.swift
 * Floating-origin analog joystick for movement input
 */

import UIKit

class VirtualJoystick: UIView {

    /* Output: normalized direction vector (-1..1) */
    var xAxis: Float = 0
    var yAxis: Float = 0
    var isActive: Bool { _isActive }

    /* Appearance */
    private let outerRadius: CGFloat = 60
    private let innerRadius: CGFloat = 25
    private let deadZone: CGFloat = 0.15

    /* State */
    private var _isActive = false
    private var origin = CGPoint.zero
    private var stickOffset = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false /* Parent view forwards touches */
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Touch Handling (called by parent)

    func touchBegan(at point: CGPoint) {
        _isActive = true
        origin = point
        stickOffset = .zero
        xAxis = 0
        yAxis = 0
        setNeedsDisplay()
    }

    func touchMoved(to point: CGPoint) {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let dist = sqrt(dx * dx + dy * dy)

        if dist > outerRadius {
            /* Clamp to outer radius */
            stickOffset = CGPoint(x: dx / dist * outerRadius, y: dy / dist * outerRadius)
        } else {
            stickOffset = CGPoint(x: dx, y: dy)
        }

        /* Normalize to -1..1 */
        var nx = Float(stickOffset.x / outerRadius)
        var ny = Float(stickOffset.y / outerRadius)

        /* Apply dead zone */
        let mag = sqrt(nx * nx + ny * ny)
        if mag < Float(deadZone) {
            nx = 0; ny = 0
        } else {
            let adjusted = (mag - Float(deadZone)) / (1.0 - Float(deadZone))
            let scale = adjusted / mag
            nx *= scale
            ny *= scale
        }

        xAxis = nx
        yAxis = -ny /* Invert Y: up = positive forward */
        setNeedsDisplay()
    }

    func touchEnded() {
        _isActive = false
        xAxis = 0
        yAxis = 0
        stickOffset = .zero
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard isActive else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        /* Outer ring */
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(2)
        ctx.addEllipse(in: CGRect(
            x: origin.x - outerRadius,
            y: origin.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        ctx.strokePath()

        /* Inner dot */
        let dotCenter = CGPoint(x: origin.x + stickOffset.x, y: origin.y + stickOffset.y)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.5).cgColor)
        ctx.addEllipse(in: CGRect(
            x: dotCenter.x - innerRadius,
            y: dotCenter.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        ctx.fillPath()
    }
}
