import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var localSettings: ProcessingSettings
    @State private var manualMaskName: String = ""
    @State private var manualBandName: String = ""

    init(model: AppModel) {
        self.model = model
        _localSettings = State(initialValue: model.settings)
        _manualMaskName = State(initialValue: model.maskTargetName)
        _manualBandName = State(initialValue: model.bandTargetName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mask status")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.maskStatus)
                            .font(.subheadline)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pulse band status")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.bandStatus)
                            .font(.subheadline)
                    }

                    Button("Scan Nearby Devices") {
                        model.scanDevices()
                    }
                }

                Section("Processing") {
                    HStack { Text("Weight (kg)"); Spacer(); numberField(value: $localSettings.weightKg) }
                    HStack { Text("VO2 window (s)"); Spacer(); numberField(value: $localSettings.vo2WindowSec) }
                    HStack { Text("Pressure deadband (Pa)"); Spacer(); numberField(value: $localSettings.pressureDeadbandPa) }
                    HStack { Text("Flow start (L/s)"); Spacer(); numberField(value: $localSettings.flowStartLS) }
                    HStack { Text("Flow end (L/s)"); Spacer(); numberField(value: $localSettings.flowEndLS) }
                    HStack { Text("Min breath (L)"); Spacer(); numberField(value: $localSettings.minBreathL) }
                    HStack { Text("Min breath (s)"); Spacer(); numberField(value: $localSettings.minBreathS) }
                    HStack { Text("Start hold (ms)"); Spacer(); numberField(value: $localSettings.breathStartHoldMs) }
                    HStack { Text("End hold (ms)"); Spacer(); numberField(value: $localSettings.breathEndHoldMs) }
                }

                Section("Sensors (not persisted)") {
                    VStack(alignment: .leading) {
                        Text("Current mask: \(model.maskTargetName)")
                            .font(.subheadline)
                        if let id = model.maskTargetID {
                            Text(id.uuidString).font(.caption2).foregroundStyle(.secondary)
                        }
                        TextField("Mask name", text: $manualMaskName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading) {
                        Text("Current pulse band: \(model.bandTargetName)")
                            .font(.subheadline)
                        if let id = model.bandTargetID {
                            Text(id.uuidString).font(.caption2).foregroundStyle(.secondary)
                        }
                        TextField("Pulse band name", text: $manualBandName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button("Apply Manual Names") {
                        model.applyManualTargets(maskName: manualMaskName, bandName: manualBandName)
                    }

                    ForEach(model.discoveredDevices) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(device.displayName)
                                .font(.subheadline)
                            HStack {
                                Button("Use as Mask") {
                                    model.useDeviceAsMask(device)
                                    manualMaskName = model.maskTargetName
                                }
                                .buttonStyle(.bordered)

                                Button("Use as Pulse") {
                                    model.useDeviceAsBand(device)
                                    manualBandName = model.bandTargetName
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.settings = localSettings
                        dismiss()
                    }
                }
            }
        }
    }

    private func numberField(value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 120)
    }
}
