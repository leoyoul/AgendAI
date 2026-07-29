import CoreFoundation

final class HandoffChangeObserver: @unchecked Sendable {
    static let notificationName = "io.github.leoyoul.agendai.handoff.changed"

    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else {
                    return
                }
                Unmanaged<HandoffChangeObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                    .onChange()
            },
            Self.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(Self.notificationName as CFString),
            nil
        )
    }
}
