import Foundation
import CoreBluetooth

final class BLEController: NSObject {
    private static let centralRestoreID = "com.vo2mask.vo2bleios.central"

    var onMaskStatus: ((String) -> Void)?
    var onBandStatus: ((String) -> Void)?
    var onMaskPacket: ((Data) -> Void)?
    var onBandECGPacket: ((Data, Date, TimeInterval) -> Void)?
    var onBandIMUPacket: ((Data, Date, TimeInterval) -> Void)?

    private(set) var discoveredDevices: [DiscoveredDevice] = []

    private var central: CBCentralManager!
    private var scanTimer: Timer?
    private var scanCompletion: (([DiscoveredDevice]) -> Void)?

    private var discoveredMap: [UUID: DiscoveredDevice] = [:]

    private var maskTarget: DeviceTarget
    private var bandTarget: DeviceTarget

    private var maskPeripheral: CBPeripheral?
    private var bandPeripheral: CBPeripheral?
    private var maskStreamChar: CBCharacteristic?
    private var bandEcgChar: CBCharacteristic?
    private var bandImuChar: CBCharacteristic?
    private var monitoredServices: [CBUUID] {
        [AppConfig.maskServiceUUID, AppConfig.bandServiceUUID]
    }
    private let connectOptions: [String: Any] = [
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        CBConnectPeripheralOptionNotifyOnNotificationKey: true
    ]

    init(maskTarget: DeviceTarget, bandTarget: DeviceTarget) {
        self.maskTarget = maskTarget
        self.bandTarget = bandTarget
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreID
            ]
        )
    }

    func start() {
        if central.state == .poweredOn {
            ensureScanning()
        }
    }

    func updateTargets(mask: DeviceTarget, band: DeviceTarget) {
        maskTarget = mask
        bandTarget = band

        if let maskPeripheral {
            central.cancelPeripheralConnection(maskPeripheral)
        }
        if let bandPeripheral {
            central.cancelPeripheralConnection(bandPeripheral)
        }

        maskPeripheral = nil
        bandPeripheral = nil
        maskStreamChar = nil
        bandEcgChar = nil
        bandImuChar = nil

        onMaskStatus?("Reconnecting mask...")
        onBandStatus?("Reconnecting pulse band...")
        ensureScanning()
    }

    func currentTargets() -> (DeviceTarget, DeviceTarget) {
        (maskTarget, bandTarget)
    }

    func scanDevicesOnce(seconds: TimeInterval = 4.5, completion: @escaping ([DiscoveredDevice]) -> Void) {
        guard central.state == .poweredOn else {
            completion([])
            return
        }

        scanCompletion = completion
        discoveredMap.removeAll(keepingCapacity: true)
        discoveredDevices = []

        central.scanForPeripherals(withServices: monitoredServices, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.central.stopScan()
            let list = self.discoveredDevices.sorted { $0.name < $1.name }
            let callback = self.scanCompletion
            self.scanCompletion = nil
            callback?(list)
            self.ensureScanning()
        }
    }

    private func ensureScanning() {
        guard central.state == .poweredOn else { return }
        guard scanCompletion == nil else { return }

        let needMask = (maskPeripheral == nil)
        let needBand = (bandPeripheral == nil)
        guard needMask || needBand else {
            central.stopScan()
            return
        }

        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        if needMask {
            onMaskStatus?("Scanning for \(maskTarget.name)...")
        }
        if needBand {
            onBandStatus?("Scanning for \(bandTarget.name)...")
        }
    }

    private func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(target: DeviceTarget, peripheral: CBPeripheral, advData: [String: Any], fallbackService: CBUUID? = nil) -> Bool {
        if let id = target.identifier, peripheral.identifier == id {
            return true
        }
        let targetName = normalize(target.name)
        let pName = normalize(peripheral.name ?? "")
        let advName = normalize((advData[CBAdvertisementDataLocalNameKey] as? String) ?? "")
        if !targetName.isEmpty, (targetName == pName || targetName == advName) {
            return true
        }
        if let fallbackService,
           let uuids = advData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           uuids.contains(fallbackService) {
            return true
        }
        return false
    }

    private func matchesRestored(target: DeviceTarget, peripheral: CBPeripheral, fallbackService: CBUUID? = nil) -> Bool {
        if let id = target.identifier, peripheral.identifier == id {
            return true
        }
        let targetName = normalize(target.name)
        let pName = normalize(peripheral.name ?? "")
        if !targetName.isEmpty, targetName == pName {
            return true
        }
        if let fallbackService,
           let services = peripheral.services,
           services.contains(where: { $0.uuid == fallbackService }) {
            return true
        }
        return false
    }

    private func restorePeripheralConnections(_ peripherals: [CBPeripheral]) {
        for peripheral in peripherals {
            peripheral.delegate = self

            if maskPeripheral == nil,
               matchesRestored(target: maskTarget, peripheral: peripheral) {
                maskPeripheral = peripheral
                maskStreamChar = nil
                if peripheral.state == .connected {
                    onMaskStatus?("Mask restored. Discovering services...")
                    peripheral.discoverServices([AppConfig.maskServiceUUID])
                } else {
                    onMaskStatus?("Restoring mask connection...")
                    central.connect(peripheral, options: connectOptions)
                }
            }

            if bandPeripheral == nil,
               matchesRestored(target: bandTarget, peripheral: peripheral, fallbackService: AppConfig.bandServiceUUID) {
                bandPeripheral = peripheral
                bandEcgChar = nil
                bandImuChar = nil
                if peripheral.state == .connected {
                    onBandStatus?("Pulse band restored. Discovering services...")
                    peripheral.discoverServices([AppConfig.bandServiceUUID])
                } else {
                    onBandStatus?("Restoring pulse band connection...")
                    central.connect(peripheral, options: connectOptions)
                }
            }
        }

        ensureScanning()
    }
}

extension BLEController: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        guard
            let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            !peripherals.isEmpty
        else { return }
        restorePeripheralConnections(peripherals)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            ensureScanning()
        } else {
            onMaskStatus?("Bluetooth unavailable (\(central.state.rawValue))")
            onBandStatus?("Bluetooth unavailable (\(central.state.rawValue))")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let device = DiscoveredDevice(
            identifier: peripheral.identifier,
            name: peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "",
            serviceUUIDs: uuids
        )
        discoveredMap[device.identifier] = device
        discoveredDevices = Array(discoveredMap.values)

        if maskPeripheral == nil,
           matches(target: maskTarget, peripheral: peripheral, advData: advertisementData) {
            maskPeripheral = peripheral
            central.connect(peripheral, options: connectOptions)
            onMaskStatus?("Connecting mask...")
        }

        if bandPeripheral == nil,
           matches(target: bandTarget, peripheral: peripheral, advData: advertisementData, fallbackService: AppConfig.bandServiceUUID) {
            bandPeripheral = peripheral
            central.connect(peripheral, options: connectOptions)
            onBandStatus?("Connecting pulse band...")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        if peripheral.identifier == maskPeripheral?.identifier {
            onMaskStatus?("Mask connected. Discovering services...")
            peripheral.discoverServices([AppConfig.maskServiceUUID])
        } else if peripheral.identifier == bandPeripheral?.identifier {
            onBandStatus?("Pulse band connected. Discovering services...")
            peripheral.discoverServices([AppConfig.bandServiceUUID])
        }
        ensureScanning()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == maskPeripheral?.identifier {
            maskPeripheral = nil
            maskStreamChar = nil
            onMaskStatus?("Mask connect failed: \(error?.localizedDescription ?? "unknown")")
        } else if peripheral.identifier == bandPeripheral?.identifier {
            bandPeripheral = nil
            bandEcgChar = nil
            bandImuChar = nil
            onBandStatus?("Pulse band connect failed: \(error?.localizedDescription ?? "unknown")")
        }
        ensureScanning()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == maskPeripheral?.identifier {
            maskPeripheral = nil
            maskStreamChar = nil
            onMaskStatus?("Mask disconnected. Reconnecting...")
        } else if peripheral.identifier == bandPeripheral?.identifier {
            bandPeripheral = nil
            bandEcgChar = nil
            bandImuChar = nil
            onBandStatus?("Pulse band disconnected. Reconnecting...")
        }
        ensureScanning()
    }
}

extension BLEController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            if peripheral.identifier == maskPeripheral?.identifier {
                onMaskStatus?("Mask service discovery failed")
            } else if peripheral.identifier == bandPeripheral?.identifier {
                onBandStatus?("Pulse service discovery failed")
            }
            return
        }

        guard let services = peripheral.services else { return }
        for service in services {
            if peripheral.identifier == maskPeripheral?.identifier,
               service.uuid == AppConfig.maskServiceUUID {
                peripheral.discoverCharacteristics([AppConfig.maskStreamCharUUID], for: service)
            }
            if peripheral.identifier == bandPeripheral?.identifier,
               service.uuid == AppConfig.bandServiceUUID {
                peripheral.discoverCharacteristics([AppConfig.bandEcgCharUUID, AppConfig.bandImuCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }

        if peripheral.identifier == maskPeripheral?.identifier {
            for ch in chars where ch.uuid == AppConfig.maskStreamCharUUID {
                maskStreamChar = ch
                peripheral.setNotifyValue(true, for: ch)
                onMaskStatus?("Mask connected. Streaming...")
            }
        }

        if peripheral.identifier == bandPeripheral?.identifier {
            for ch in chars {
                if ch.uuid == AppConfig.bandEcgCharUUID {
                    bandEcgChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                }
                if ch.uuid == AppConfig.bandImuCharUUID {
                    bandImuChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                }
            }
            if bandEcgChar != nil && bandImuChar != nil {
                onBandStatus?("Pulse band connected. Streaming...")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        if peripheral.identifier == maskPeripheral?.identifier,
           characteristic.uuid == AppConfig.maskStreamCharUUID {
            onMaskPacket?(value)
            return
        }

        if peripheral.identifier == bandPeripheral?.identifier {
            let ts = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            if characteristic.uuid == AppConfig.bandEcgCharUUID {
                onBandECGPacket?(value, ts, uptime)
            } else if characteristic.uuid == AppConfig.bandImuCharUUID {
                onBandIMUPacket?(value, ts, uptime)
            }
        }
    }
}
