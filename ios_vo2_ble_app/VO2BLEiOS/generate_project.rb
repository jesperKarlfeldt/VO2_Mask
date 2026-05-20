require 'xcodeproj'

project_path = File.join(__dir__, 'VO2BLEiOS.xcodeproj')
project = Xcodeproj::Project.new(project_path)

app_group = project.main_group.new_group('VO2BLEiOS', 'VO2BLEiOS')
models_group = app_group.new_group('Models', 'Models')
ble_group = app_group.new_group('BLE', 'BLE')
processing_group = app_group.new_group('Processing', 'Processing')
recording_group = app_group.new_group('Recording', 'Recording')
ui_group = app_group.new_group('UI', 'UI')
resources_group = app_group.new_group('Resources', 'Resources')

source_files = [
  ['VO2BLEiOSApp.swift', app_group],
  ['ContentView.swift', app_group],
  ['AppModel.swift', app_group],
  ['AppConfig.swift', models_group],
  ['DataExtensions.swift', models_group],
  ['Models.swift', models_group],
  ['BLEController.swift', ble_group],
  ['VO2Processor.swift', processing_group],
  ['PulseBandProcessor.swift', processing_group],
  ['DualCSVRecorder.swift', recording_group],
  ['ChartViews.swift', ui_group],
  ['SettingsView.swift', ui_group],
]

resource_files = [
  ['Info.plist', resources_group],
  ['Assets.xcassets', resources_group],
]

target = project.new_target(:application, 'VO2BLEiOS', :ios, '16.0')
target.product_reference.name = 'VO2BLEiOS.app'

# Keep framework linking fully auto-resolved from Swift imports.
# Older xcodeproj versions can emit stale iPhoneOSXX SDK paths.
target.frameworks_build_phase.files_references.each do |ref|
  target.frameworks_build_phase.remove_file_reference(ref)
  ref.remove_from_project
end

source_refs = source_files.map { |path, group| group.new_file(path) }
source_refs.each { |ref| target.source_build_phase.add_file_reference(ref) }

resource_refs = resource_files.map { |path, group| group.new_file(path) }
# Only add assets to resources phase; Info.plist is configured via build setting.
target.resources_build_phase.add_file_reference(resource_refs[1])

target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.vo2mask.vo2bleios'
  settings['INFOPLIST_FILE'] = 'VO2BLEiOS/Resources/Info.plist'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings.delete('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME')
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project_path, 'VO2BLEiOS', true)

project.save
puts "Generated #{project_path}"
