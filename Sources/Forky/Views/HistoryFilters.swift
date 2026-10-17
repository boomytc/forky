import SwiftUI
import ForkyCore

struct HistoryFilters: View {
    @Binding var options: HistoryOptions
    @State private var shown = false
    var body: some View {
        Button("History Filters", systemImage: "line.3.horizontal.decrease.circle") { shown.toggle() }
            .labelStyle(.iconOnly)
            .popover(isPresented: $shown) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("First-parent history", isOn: $options.firstParent)
                    Toggle("After date / time", isOn: Binding(get: { options.after != nil }, set: { options.after = $0 ? Date.now.addingTimeInterval(-30 * 86400) : nil }))
                    if options.after != nil { DatePicker("After", selection: Binding(get: { options.after ?? .now }, set: { options.after = $0 })) }
                    Toggle("Before date / time", isOn: Binding(get: { options.before != nil }, set: { options.before = $0 ? .now : nil }))
                    if options.before != nil { DatePicker("Before", selection: Binding(get: { options.before ?? .now }, set: { options.before = $0 })) }
                    Text("Dates use the displayed local timezone; the query captures exact instants. SHA lookup is not branch-filtered.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear Filters") { options.firstParent = false; options.after = nil; options.before = nil }
                }.padding(16).frame(width: 330)
            }
    }
}
