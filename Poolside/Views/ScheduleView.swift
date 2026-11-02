import SwiftUI

/// Every schedule on the controller, in time order. Tap to edit, + to add, swipe to delete.
struct ScheduleView: View {
    @Environment(PoolStore.self) private var store
    @State private var editing: ScheduleDraft?
    @State private var pendingDelete: Schedule?

    var body: some View {
        List {
            if !store.schedulesLoaded {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if store.schedules.isEmpty {
                ContentUnavailableView("No schedules", systemImage: "calendar.badge.clock",
                                       description: Text("Tap + to turn something on and off at set times."))
            } else {
                Section {
                    ForEach(store.schedules) { schedule in
                        Button {
                            editing = ScheduleDraft(schedule, isNew: false)
                        } label: {
                            ScheduleRow(schedule: schedule)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = schedule }
                        }
                    }
                } footer: {
                    Text("Your controller runs these on its own, even with the app closed.")
                }
            }

            if let notice = store.notice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
        }
        .navigationTitle("Schedule")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = ScheduleDraft.new(circuit: store.schedulableCircuits.first)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!store.schedulesLoaded || store.schedulableCircuits.isEmpty)
                .accessibilityLabel("Add schedule")
            }
        }
        .refreshable { await store.loadSchedules() }
        .task { await store.loadSchedules() }
        .sheet(item: $editing) { draft in
            ScheduleEditor(draft: draft)
        }
        .confirmationDialog("Delete this schedule?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { schedule in
            Button("Delete \(store.circuitName(schedule.circuitId)) schedule", role: .destructive) {
                Task { await store.deleteSchedule(schedule) }
            }
        }
    }
}

private struct ScheduleRow: View {
    let schedule: Schedule
    @Environment(PoolStore.self) private var store

    var body: some View {
        let circuit = store.config.circuits.first { $0.id == schedule.circuitId }
        HStack(spacing: 14) {
            Image(systemName: circuit.map(Theme.icon(for:)) ?? "power")
                .font(.body)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.circuitName(schedule.circuitId))
                    .font(.body.weight(.semibold))
                Text(ScheduleFormat.timeRange(schedule))
                    .font(.subheadline)
                    .monospacedDigit()
                Text(schedule.kind == .runOnce ? "Once · \(schedule.days.summary)" : schedule.days.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// What the editor works on. Times are kept as minutes past midnight, like the controller.
struct ScheduleDraft: Identifiable {
    let id = UUID()
    var schedule: Schedule
    let isNew: Bool

    init(_ schedule: Schedule, isNew: Bool) {
        self.schedule = schedule
        self.isNew = isNew
    }

    static func new(circuit: Circuit?) -> ScheduleDraft {
        ScheduleDraft(Schedule(id: 0, kind: .recurring, circuitId: circuit?.id ?? 0,
                               startMinutes: 9 * 60, stopMinutes: 17 * 60, days: .everyDay),
                      isNew: true)
    }
}

struct ScheduleEditor: View {
    @State var draft: ScheduleDraft
    @Environment(PoolStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var allDay: Binding<Bool> {
        Binding(
            get: { draft.schedule.isAllDay },
            set: { on in
                if on {
                    draft.schedule.stopMinutes = (draft.schedule.startMinutes + 1439) % 1440
                } else {
                    draft.schedule.stopMinutes = (draft.schedule.startMinutes + 60) % 1440
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Turn on", selection: $draft.schedule.circuitId) {
                        ForEach(store.schedulableCircuits) { circuit in
                            Label(circuit.name, systemImage: Theme.icon(for: circuit)).tag(circuit.id)
                        }
                    }
                }

                Section {
                    Toggle("All day", isOn: allDay)
                    DatePicker(allDay.wrappedValue ? "Starts at" : "On at",
                               selection: minutes($draft.schedule.startMinutes, keepAllDay: true),
                               displayedComponents: .hourAndMinute)
                    if !allDay.wrappedValue {
                        DatePicker("Off at", selection: minutes($draft.schedule.stopMinutes, keepAllDay: false),
                                   displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    if !allDay.wrappedValue, draft.schedule.stopMinutes < draft.schedule.startMinutes {
                        Text("Runs past midnight and turns off the next morning.")
                    } else if draft.schedule.startMinutes == draft.schedule.stopMinutes {
                        Text("On and off at the same time means it never runs.")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Days") {
                    DayPicker(days: $draft.schedule.days)
                    HStack {
                        quickDays("Every day", .everyDay)
                        quickDays("Weekdays", .weekdays)
                        quickDays("Weekends", .weekend)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if draft.schedule.kind == .runOnce {
                    Section {
                        Label("Runs once, then the controller removes it.", systemImage: "1.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                if !draft.isNew {
                    Section {
                        Button("Delete schedule", role: .destructive) { confirmDelete = true }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(draft.isNew ? "New schedule" : store.circuitName(draft.schedule.circuitId))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(draft.isNew ? "Add" : "Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog("Delete this schedule?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let schedule = draft.schedule
                    dismiss()
                    Task { await store.deleteSchedule(schedule) }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var canSave: Bool {
        !draft.schedule.days.intersection(.everyDay).isEmpty
            && draft.schedule.startMinutes != draft.schedule.stopMinutes
            && store.config.circuits.contains { $0.id == draft.schedule.circuitId }
    }

    private func quickDays(_ title: String, _ days: Weekdays) -> some View {
        Button(title) { draft.schedule.days = days }
            .frame(maxWidth: .infinity)
    }

    private func save() {
        saving = true
        error = nil
        let schedule = draft.schedule
        let isNew = draft.isNew
        Task {
            do {
                try await store.saveSchedule(schedule, isNew: isNew)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    /// Bridges minutes past midnight to a Date for DatePicker. Moving the start of an all-day
    /// schedule drags the stop along so it stays all day.
    private func minutes(_ value: Binding<Int>, keepAllDay: Bool) -> Binding<Date> {
        Binding(
            get: { ScheduleFormat.date(minutes: value.wrappedValue) },
            set: { date in
                let wasAllDay = draft.schedule.isAllDay
                value.wrappedValue = ScheduleFormat.minutes(of: date)
                if keepAllDay, wasAllDay {
                    draft.schedule.stopMinutes = (draft.schedule.startMinutes + 1439) % 1440
                }
            }
        )
    }
}

/// Seven round day toggles, Sunday first.
private struct DayPicker: View {
    @Binding var days: Weekdays

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Weekdays.ordered, id: \.short) { entry in
                let on = days.contains(entry.day)
                Button {
                    if on { days.remove(entry.day) } else { days.insert(entry.day) }
                } label: {
                    Text(entry.letter)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.15)),
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.short)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: days)
    }
}

enum ScheduleFormat {
    static func date(minutes: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .minute, value: minutes, to: start) ?? start
    }

    static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func time(_ minutes: Int) -> String {
        date(minutes: minutes).formatted(date: .omitted, time: .shortened)
    }

    static func timeRange(_ s: Schedule) -> String {
        if s.isAllDay { return "All day" }
        return "\(time(s.startMinutes)) – \(time(s.stopMinutes))"
    }
}
