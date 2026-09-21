/// A count followed by its noun, singular only for exactly one: "0 calls", "1 call", "3 calls".
public enum Plural {
    public static func count(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
