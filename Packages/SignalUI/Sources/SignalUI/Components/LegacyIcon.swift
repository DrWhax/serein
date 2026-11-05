// Single-colour icons that legacy stylesheets paint with `@include mixins.color-svg(url, color)`
// (a CSS mask: the SVG's shape filled with a colour). Each icon keeps its SVG's own path data
// (parsed by SVGPathData) and fill rule; `Mask` scales it like `-webkit-mask-size` into the
// element's box. The data below is copied verbatim from Signal-Desktop/images.

import SwiftUI

public struct LegacyIcon: Sendable {
    public struct SubPath: Sendable {
        public var evenOdd: Bool
        /// The path in the SVG's viewBox coordinates.
        public var path: Path

        init(evenOdd: Bool, d: String) {
            self.evenOdd = evenOdd
            guard let path = SVGPathData.parse(d) else { preconditionFailure("Invalid icon path data: \(d)") }
            self.path = path
        }
    }

    /// The SVG's intrinsic size (its viewBox).
    public var width: CGFloat
    public var height: CGFloat
    public var paths: [SubPath]

    /// A path mapped from the viewBox onto `rect`.
    func path(_ sub: SubPath, in rect: CGRect) -> Path {
        sub.path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / width, y: rect.height / height))
    }

    /// An element painted with `color-svg(icon, color)`: the icon, `maskSize` (a fraction of
    /// the box width, CSS `-webkit-mask-size`; the height keeps the aspect ratio) centred.
    public struct Mask: View {
        let icon: LegacyIcon
        let color: AxoColor
        let maskSize: CGFloat

        public init(_ icon: LegacyIcon, color: AxoColor, maskSize: CGFloat = 1) {
            self.icon = icon
            self.color = color
            self.maskSize = maskSize
        }

        public var body: some View {
            Canvas { ctx, size in
                let w = size.width * maskSize, h = w * icon.height / icon.width
                let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                let shading = GraphicsContext.Shading.color(color.resolve(in: ctx.environment))
                for sub in icon.paths {
                    ctx.fill(icon.path(sub, in: rect), with: shading, style: FillStyle(eoFill: sub.evenOdd))
                }
            }
            .accessibilityHidden(true)
        }
    }
}

extension LegacyIcon {
    /// `images/icons/v3/x/x.svg`
    static let x = LegacyIcon(width: 20, height: 20, paths: [
        SubPath(evenOdd: false, d: "M15.516 5.516a.73.73 0 0 0-1.031-1.032L10 8.97 5.516 4.484a.73.73 0 1 0-1.031 1.032L8.969 10l-4.484 4.484a.73.73 0 0 0 1.03 1.032L10 11.03l4.485 4.485a.73.73 0 1 0 1.03-1.032L11.032 10l4.485-4.484Z"),
    ])
    /// `images/icons/v3/x/x-compact-light.svg`
    static let xCompactLight = LegacyIcon(width: 16, height: 16, paths: [
        SubPath(evenOdd: false, d: "M4.39 3.611a.55.55 0 1 0-.779.778L7.222 8l-3.61 3.611a.55.55 0 0 0 .777.778L8 8.778l3.611 3.61a.55.55 0 0 0 .778-.777L8.778 8l3.611-3.611a.55.55 0 1 0-.778-.778l-3.61 3.611-3.612-3.611Z"),
    ])
    /// `images/icons/v3/chevron/chevron-left.svg`
    static let chevronLeft = LegacyIcon(width: 20, height: 20, paths: [
        SubPath(evenOdd: false, d: "M12.599 3.651a.73.73 0 0 0-1.031 0L5.734 9.484a.73.73 0 0 0 0 1.032l5.834 5.833a.73.73 0 1 0 1.03-1.031L7.282 10 12.6 4.682a.73.73 0 0 0 0-1.03Z"),
    ])
    /// `images/icons/v3/check/check-compact-bold.svg`
    static let checkCompactBold = LegacyIcon(width: 16, height: 16, paths: [
        SubPath(evenOdd: false, d: "M13.15 2.866a.75.75 0 0 1 .234 1.034l-6 9.5a.75.75 0 0 1-1.226.06l-3.5-4.5a.75.75 0 0 1 1.184-.92l2.844 3.656 5.43-8.597a.75.75 0 0 1 1.034-.233Z"),
    ])
    /// `images/icons/v3/person/person.svg`
    static let person = LegacyIcon(width: 20, height: 20, paths: [
        SubPath(evenOdd: true, d: "M10 .938c-2.184 0-3.75 2.01-3.75 4.361 0 1.19.387 2.315 1.037 3.156.65.842 1.6 1.44 2.713 1.44 1.112 0 2.063-.598 2.713-1.44.65-.841 1.037-1.967 1.037-3.156 0-2.35-1.567-4.362-3.75-4.362Zm-2.292 4.36c0-1.79 1.139-2.903 2.292-2.903 1.153 0 2.291 1.113 2.291 2.903 0 .883-.289 1.691-.732 2.265-.444.575-1.003.873-1.56.873-.556 0-1.114-.298-1.558-.873-.443-.574-.733-1.382-.733-2.265ZM10 10.938c-3.825 0-7.166 2.34-7.731 5.608-.17.985.66 1.683 1.48 1.683h12.5c.822 0 1.652-.698 1.482-1.683-.566-3.268-3.907-5.608-7.731-5.608Zm-6.288 5.825c.43-2.375 2.987-4.367 6.288-4.367 3.3 0 5.858 1.992 6.288 4.367a.097.097 0 0 1-.038.008H3.75a.096.096 0 0 1-.038-.008Z"),
    ])
    /// `images/icons/v3/group/group.svg`
    static let group = LegacyIcon(width: 20, height: 20, paths: [
        SubPath(evenOdd: true, d: "M10.833 5.957c0-1.778 1.195-3.353 2.917-3.353 1.722 0 2.917 1.575 2.917 3.353 0 .902-.294 1.759-.794 2.404-.499.645-1.242 1.118-2.123 1.118-.88 0-1.624-.473-2.123-1.118-.5-.645-.794-1.502-.794-2.404Zm2.917-1.895c-.694 0-1.458.681-1.458 1.895 0 .594.196 1.134.488 1.511.292.378.643.553.97.553.327 0 .678-.175.97-.553.292-.377.488-.917.488-1.511 0-1.214-.764-1.895-1.458-1.895Z"),
        SubPath(evenOdd: false, d: "M6.25 10.52c.93 0 1.821.202 2.613.564a6.44 6.44 0 0 0-1.03 1.152 4.905 4.905 0 0 0-1.583-.257c-2.23 0-3.934 1.421-4.226 3.125h4.769a6.113 6.113 0 0 0 .05 1.459H1.464a.94.94 0 0 1-.943-.938c0-2.907 2.66-5.104 5.729-5.104Z"),
        SubPath(evenOdd: true, d: "M13.75 10.52c-3.07 0-5.73 2.198-5.73 5.105 0 .545.45.938.944.938h9.572a.94.94 0 0 0 .943-.938c0-2.907-2.66-5.104-5.729-5.104Zm0 1.46c2.23 0 3.934 1.42 4.226 3.124H9.524c.292-1.704 1.997-3.125 4.226-3.125Zm-7.5-9.376c-1.722 0-2.917 1.575-2.917 3.353 0 .902.294 1.759.794 2.404.499.645 1.242 1.118 2.123 1.118.881 0 1.624-.473 2.123-1.118.5-.645.794-1.502.794-2.404 0-1.778-1.195-3.353-2.917-3.353ZM4.792 5.957c0-1.214.764-1.895 1.458-1.895.695 0 1.458.681 1.458 1.895 0 .594-.195 1.134-.488 1.511-.292.378-.643.553-.97.553-.327 0-.678-.175-.97-.553-.292-.377-.488-.917-.488-1.511Z"),
    ])
    /// `images/icons/v3/note/note.svg`
    static let note = LegacyIcon(width: 20, height: 20, paths: [
        SubPath(evenOdd: false, d: "M6.667 8.23a.73.73 0 1 0 0 1.458h6.666a.73.73 0 0 0 0-1.459H6.667Zm-.73 3.645a.73.73 0 0 1 .73-.73h6.666a.73.73 0 1 1 0 1.46H6.667a.73.73 0 0 1-.73-.73Zm.73 2.188a.73.73 0 0 0 0 1.458h4.166a.73.73 0 0 0 0-1.459H6.667Z"),
        SubPath(evenOdd: true, d: "M7.72 1.354h4.56c.675 0 1.225 0 1.671.037.462.037.878.118 1.265.315a3.23 3.23 0 0 1 1.411 1.411c.198.388.278.803.316 1.265.036.447.036.997.036 1.67v7.895c0 .674 0 1.224-.036 1.671-.038.462-.119.877-.316 1.265a3.23 3.23 0 0 1-1.411 1.41c-.387.198-.803.279-1.265.316-.446.037-.996.037-1.67.037H7.719c-.674 0-1.224 0-1.67-.037-.462-.037-.878-.118-1.265-.315a3.23 3.23 0 0 1-1.411-1.411c-.198-.388-.278-.803-.316-1.265-.036-.447-.036-.997-.036-1.67V6.052c0-.674 0-1.224.036-1.671.038-.462.118-.877.316-1.265a3.23 3.23 0 0 1 1.41-1.41c.388-.198.804-.279 1.266-.316.446-.037.996-.037 1.67-.037Zm-1.553 1.49c-.371.03-.574.086-.721.162a1.77 1.77 0 0 0-.774.773c-.075.148-.13.35-.161.722a9.743 9.743 0 0 0-.027.603h11.031a9.696 9.696 0 0 0-.026-.603c-.03-.372-.086-.574-.161-.722a1.77 1.77 0 0 0-.774-.773c-.148-.076-.35-.131-.722-.162-.38-.03-.87-.031-1.582-.031h-4.5c-.712 0-1.202 0-1.583.031ZM4.48 13.917V6.563h11.042v7.354c0 .712 0 1.202-.032 1.582-.03.372-.086.574-.161.722a1.77 1.77 0 0 1-.774.773c-.148.076-.35.131-.722.162-.38.031-.87.032-1.582.032h-4.5c-.712 0-1.202-.001-1.583-.032-.371-.03-.574-.086-.721-.162a1.77 1.77 0 0 1-.774-.773c-.075-.148-.13-.35-.161-.722-.031-.38-.032-.87-.032-1.582Z"),
    ])
    /// `images/icons/v3/search/search.svg`
    static let search = LegacyIcon(width: 20, height: 20, paths: [
        SubPath(evenOdd: true, d: "M8.333 1.77a6.563 6.563 0 1 0 3.93 11.82l4.158 4.156a.937.937 0 0 0 1.325-1.325l-4.157-4.157A6.563 6.563 0 0 0 8.333 1.77ZM3.23 8.334a5.104 5.104 0 1 1 10.209 0 5.104 5.104 0 0 1-10.209 0Z"),
    ])
    /// `images/spinner-56.svg`
    static let spinner56 = LegacyIcon(width: 56, height: 56, paths: [
        SubPath(evenOdd: true, d: "M52.36 14.185A27.9 27.9 0 0 1 56 28c0 15.464-12.536 28-28 28v-2c14.36 0 26-11.64 26-26 0-4.66-1.226-9.033-3.372-12.815z"),
    ])
    /// `images/spinner-track-56.svg`
    static let spinnerTrack56 = LegacyIcon(width: 56, height: 56, paths: [
        SubPath(evenOdd: false, d: "M28 54c14.36 0 26-11.64 26-26S42.36 2 28 2 2 13.64 2 28s11.64 26 26 26m0 2C12.536 56 0 43.464 0 28S12.536 0 28 0s28 12.536 28 28-12.536 28-28 28"),
    ])
    /// `images/spinner-24.svg`
    static let spinner24 = LegacyIcon(width: 24, height: 24, paths: [
        SubPath(evenOdd: false, d: "M22.56 6.295A11.95 11.95 0 0 1 24 12c0 6.627-5.373 12-12 12v-2c5.523 0 10-4.477 10-10 0-1.7-.424-3.302-1.173-4.704z"),
    ])
    /// `images/spinner-track-24.svg`
    static let spinnerTrack24 = LegacyIcon(width: 24, height: 24, paths: [
        SubPath(evenOdd: false, d: "M12 24C5.373 24 0 18.627 0 12S5.373 0 12 0s12 5.373 12 12-5.373 12-12 12m0-2c5.523 0 10-4.477 10-10S17.523 2 12 2 2 6.477 2 12s4.477 10 10 10"),
    ])
}
