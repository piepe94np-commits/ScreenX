import Foundation

public enum GradientPresets {
    private static func make(_ hexes: [String], locations: [Double]) -> Background {
        let stops = zip(hexes, locations).map { hex, location in
            // Literals below are valid; a typo is a programmer error caught by tests.
            GradientStop(color: ColorValue(hex: hex)!, location: location)
        }
        return .gradient(stops: stops, angle: 135)
    }

    private static func two(_ a: String, _ b: String) -> Background {
        make([a, b], locations: [0, 1])
    }

    public static let all: [Background] = [
        make(["#FF9A6B", "#FF5E8A", "#7B5CFF"], locations: [0, 0.45, 1]),
        two("#43E97B", "#38F9D7"),
        two("#4FACFE", "#00F2FE"),
        two("#FDDB92", "#D1FDFF"),
        two("#232526", "#414345"),
        two("#A18CD1", "#FBC2EB"),
        two("#F093FB", "#F5576C"),
        two("#5EE7DF", "#B490CA"),
        two("#FAD0C4", "#FFD1FF"),
        two("#667EEA", "#764BA2"),
        two("#0BA360", "#3CBA92"),
        two("#FF9A9E", "#FECFEF"),
    ]
}
