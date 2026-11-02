#if DEBUG
import Foundation

extension PoolStore {
    /// Your system's circuits and a typical evening, for Xcode previews. Never connects.
    static var preview: PoolStore {
        let store = PoolStore()
        store.config = ControllerConfig(
            isCelsius: false, minSetPoint: [40, 40], maxSetPoint: [104, 104],
            hasSolar: false, hasIntelliBrite: true,
            circuits: [
                Circuit(id: 500, name: "Spa", functionCode: 1, interfaceCode: 1),
                Circuit(id: 501, name: "Air Blower", functionCode: 0, interfaceCode: 1),
                Circuit(id: 502, name: "Fountains", functionCode: 0, interfaceCode: 0),
                Circuit(id: 503, name: "Pool Light", functionCode: 16, interfaceCode: 3),
                Circuit(id: 504, name: "Spa Light", functionCode: 16, interfaceCode: 3),
                Circuit(id: 505, name: "Pool", functionCode: 2, interfaceCode: 0),
                Circuit(id: 506, name: "Deck Light", functionCode: 7, interfaceCode: 4),
                Circuit(id: 507, name: "Fire Pit", functionCode: 0, interfaceCode: 2),
                Circuit(id: 510, name: "Spillway", functionCode: 14, interfaceCode: 0),
                Circuit(id: 511, name: "Pool High", functionCode: 0, interfaceCode: 2),
            ])
        var state = EquipmentState()
        state.airTemperature = 66
        state.bodies = [BodyState(temperature: 71, heatStatus: 0, setPoint: 81, heatMode: 0),
                        BodyState(temperature: 72, heatStatus: 1, setPoint: 95, heatMode: 3)]
        state.circuitOn = [505: true, 503: true, 504: true, 506: true]
        store.state = state
        store.hasData = true
        store.phase = .connected
        store.link = .local
        store.schedules = [
            Schedule(id: 700, kind: .recurring, circuitId: 505, startMinutes: 480, stopMinutes: 479, days: .everyDay),
            Schedule(id: 705, kind: .recurring, circuitId: 502, startMinutes: 540, stopMinutes: 555, days: .everyDay),
            Schedule(id: 701, kind: .recurring, circuitId: 510, startMinutes: 540, stopMinutes: 1140, days: .everyDay),
            Schedule(id: 702, kind: .recurring, circuitId: 503, startMinutes: 1200, stopMinutes: 1320, days: .everyDay),
        ]
        store.schedulesLoaded = true
        return store
    }
}
#endif
