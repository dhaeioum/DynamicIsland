//
//  CalendarManager.swift
//  DynamicIsland
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    var hasCalendarConnection: Bool {
        calendarAuthorizationStatus.allowsCalendarReadAccess
    }
    var canAttemptCalendarConnection: Bool {
        calendarAuthorizationStatus.canAttemptConnection
    }
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        refreshAuthorizationStatuses()
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        guard hasCalendarConnection else {
            events = []
            allCalendars = []
            eventCalendars = []
            reminderLists = []
            selectedCalendars = []
            return
        }

        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization(requestIfNeeded: Bool = false) async {
        refreshAuthorizationStatuses()

        switch calendarAuthorizationStatus {
        case .notDetermined:
            if requestIfNeeded {
                await connectToCalendar()
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
            events = []
        case .fullAccess, .authorized:
            NSLog("Calendar access granted")
            await reloadCalendarAndReminderLists()
            await updateEvents()
        case .writeOnly:
            NSLog("Calendar access is write only; read access required")
            events = []
        @unknown default:
            print("Unknown authorization status")
            events = []
        }
    }

    func connectToCalendar() async {
        guard calendarAuthorizationStatus.canAttemptConnection else { return }

        let granted = await calendarService.requestAccess()

        refreshAuthorizationStatuses()

        guard granted || calendarAuthorizationStatus.allowsCalendarReadAccess else { return }

        await reloadCalendarAndReminderLists()
        await updateEvents()
    }

    func updateSelectedCalendars() {
        selectedCalendars = allCalendars.filter { getCalendarSelected($0) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        switch Defaults[.calendarSelectionState] {
        case .all:
            return true
        case .selected(let identifiers):
            return identifiers.contains(calendar.id)
        }
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        let calendarIDs = selectedCalendars.map { $0.id }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        self.events = eventsResult
    }

    @MainActor
    func refreshAuthorizationStatuses() {
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }
}

private extension EKAuthorizationStatus {
    var allowsCalendarReadAccess: Bool {
        switch self {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    var canAttemptConnection: Bool {
        switch self {
        case .restricted, .denied:
            return false
        default:
            return true
        }
    }
}
