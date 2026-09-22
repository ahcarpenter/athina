import Foundation
import AthinaE2E

/// Printing layer over `JournalDatabase`: the queries and their execution live
/// in the library, where CI proves them against a journal the app just made.
enum JournalReader {
    static func run(database path: String, query name: String) {
        if name == "queries" {
            for query in JournalQueries.all {
                say("\(query.name.padding(toLength: 15, withPad: " ", startingAt: 0))\(query.summary)")
            }
            say("capture-race   change moments and whether a focus-change capture followed each")
            return
        }
        let database = JournalDatabase(path: path)
        do {
            if name == "capture-race" {
                let (table, report) = try database.captureRace()
                say(table)
                say("")
                say("moments=\(report.moments.count) kept=\(report.kept) dropped=\(report.dropped) pending=\(report.pending)")
                return
            }
            guard let query = JournalQueries.named(name) else {
                fail("journal: unknown query \"\(name)\"; `athina-drive journal - queries` lists them", code: 64)
            }
            say(try database.table(query))
        } catch {
            fail("journal: \(error)")
        }
    }
}
