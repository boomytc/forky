import SwiftUI
import Charts
import ForkyCore

struct StatisticsSheet: View {
    let request: QueryRequest
    let store: RepositoryStore
    @State private var statistics: RepositoryStatistics?
    @State private var failure: String?
    @State private var limitDates = false
    @State private var since = Date.now.addingTimeInterval(-365 * 86400)
    @State private var until = Date.now
    @State private var token = UUID()
    var body: some View {
        AdvancedFrame(title: "Commit Statistics", subtitle: "Local branch/tag/tracking roots + HEAD, captured per query · UTC date buckets · no network") {
            VStack(spacing: 12) {
                HStack {
                    Toggle("Date range", isOn: $limitDates)
                    if limitDates {
                        DatePicker("From", selection: $since, displayedComponents: .date)
                        DatePicker("Through", selection: $until, displayedComponents: .date)
                    }
                    Button("Recompute") { token = UUID() }
                }
                if let failure { FeatureError(text: failure) }
                else if let statistics {
                    Text("\(statistics.total) unique reachable commits in examined scope").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading) {
                            Text("By month (UTC)").font(.caption)
                            Chart(statistics.months) { bucket in BarMark(x: .value("Month", bucket.key), y: .value("Commits", bucket.count)) }.frame(height: 150)
                            Text("By weekday (UTC)").font(.caption)
                            Chart(statistics.weekdays) { bucket in BarMark(x: .value("Day", bucket.key), y: .value("Commits", bucket.count)) }.frame(height: 110)
                            Text("Authors (source name + email, not inferred accounts)").font(.caption)
                            ForEach(statistics.authors) { person in
                                HStack { Text(person.key).textSelection(.enabled); Spacer(); Text(person.count, format: .number).monospacedDigit() }.font(.caption)
                            }
                        }.padding(4)
                    }
                } else { ProgressView("Reading complete bounded scope…") }
            }.padding(14)
        } actions: {
            Button("Close") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer(); Text("Output limit errors mean unavailable, never partial counts.").font(.caption)
        }
        .task(id: token) {
            statistics = nil; failure = nil
            do {
                guard !limitDates || since <= until else { throw GitError.invalidInput("Date range is reversed.") }
                let result = try await request.repository.statistics(after: limitDates ? since : nil, before: limitDates ? until : nil)
                try Task.checkCancellation(); statistics = result
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}
