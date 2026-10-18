import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@main struct AvansiaUtility: App {
    @StateObject private var model = UtilityModel()
    var body: some Scene {
        Window("Avansia Utility", id: "main") {
            UtilityWindow(model: model)
                .frame(minWidth: 860, minHeight: 620)
                .task {
                    NSApp.setActivationPolicy(.regular)
                    if let image = NSImage(contentsOf: model.imageURL) { NSApp.applicationIconImage = image }
                    await model.pollCache()
                }
                .task { await model.pollInstallation() }
        }
        .defaultSize(width: 1020, height: 740)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
enum UtilityPage: String, CaseIterable, Identifiable {
    case overview = "Overview", supplies = "Supplies", accessories = "Accessories", settings = "Settings", print = "Print PDF", recovery = "Recovery", installation = "Installation"
    var id: String { rawValue }
    var title: String { AppStrings.text(rawValue) }
    var symbol: String {
        switch self {
        case .overview: return "printer"
        case .supplies: return "drop.halffull"
        case .accessories: return "puzzlepiece.extension"
        case .settings: return "slider.horizontal.3"
        case .print: return "doc.richtext"
        case .recovery: return "exclamationmark.triangle"
        case .installation: return "arrow.down.app"
        }
    }
}
struct UtilityWindow: View {
    @ObservedObject var model: UtilityModel
    @State private var selection: UtilityPage? = .overview
    var body: some View {
        NavigationSplitView {
            List(UtilityPage.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Evolis Avansia").font(.headline)
                    Text(model.checkingInstallation ? AppStrings.text("Checking installation") : model.installationState.title).font(.caption).foregroundStyle(.secondary)
                    if model.fixture != nil { Label("Preview data", systemImage: "testtube.2").font(.caption) }
                }.padding()
            }
        } detail: {
            VStack(spacing: 0) {
                if let operation = model.operation {
                    HStack { ProgressView().controlSize(.small); Text(operation); Spacer() }.padding(12).background(.quaternary)
                }
                if let error = model.actionError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.callout).textSelection(.enabled)
                            if let details = model.actionDetails { TechnicalDetails(text: details) }
                        }
                        Spacer()
                        Button { model.actionError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                    }.padding().background(.orange.opacity(0.08))
                }
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle").padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.green.opacity(0.08))
                }
                Group {
                    switch selection ?? .overview {
                    case .overview: OverviewView(model: model)
                    case .supplies: SuppliesView(model: model)
                    case .accessories: AccessoriesView(model: model)
                    case .settings: PrinterSettingsView(model: model)
                    case .print: PrintPDFView(model: model)
                    case .recovery: RecoveryView(model: model)
                    case .installation: InstallationView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle((selection ?? .overview).title)
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.refreshDetails() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(!model.canReadDetails)
                        .help("Refresh printer details once, when the printer is idle")
                }
            }
        }
    }
}
struct StatusLine: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppStrings.text(title)).foregroundStyle(.secondary)
            Spacer(minLength: 18)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.padding(.vertical, 3)
    }
}
struct TechnicalDetails: View {
    let text: String
    var body: some View {
        DisclosureGroup("Technical details") {
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
        }
    }
}
struct ObservationNote: View {
    @ObservedObject var model: UtilityModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.stale { Label("Status may be out of date", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
            if let observed = model.snapshot?.observed_at, let date = PrinterSnapshot.date(observed) {
                Text(AppStrings.format("Last successful observation: %@", AppStrings.date(date))).foregroundStyle(.secondary)
            } else { Text("No successful printer observation yet.").foregroundStyle(.secondary) }
            if let error = model.cacheError {
                Text(error).foregroundStyle(.secondary)
                if let details = model.cacheDetails { TechnicalDetails(text: details) }
            } else if let details = model.snapshot?.error {
                Text("The latest status could not be read. Check the connection and refresh when idle.").foregroundStyle(.secondary)
                TechnicalDetails(text: details)
            }
        }.font(.callout)
    }
}
struct OverviewView: View {
    @ObservedObject var model: UtilityModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 28) {
                    Group {
                        if let image = NSImage(contentsOf: model.imageURL) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else { Image(systemName: "printer.fill").resizable().scaledToFit().foregroundStyle(.secondary).padding(24) }
                    }.frame(width: 190, height: 150).accessibilityLabel("Avansia printer")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Evolis Avansia").font(.largeTitle.weight(.semibold))
                        Text(AppStrings.connection(model.snapshot?.connection)).font(.title2)
                        Text("CR80 · 600 dpi · USB").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                GroupBox("Printer and queue") {
                    VStack {
                        StatusLine(title: "Hardware", value: AppStrings.connection(model.snapshot?.connection))
                        StatusLine(title: "Queue", value: AppStrings.text(model.snapshot?.queue?.active_job.map { $0 == .null ? "Unknown" : $0.isPresent ? "Job active" : "No active job reported" } ?? "Unknown"))
                        StatusLine(title: "Card recovery", value: AppStrings.text(model.snapshot?.queue?.recovery_required.map { $0 ? "Physical inspection required" : "No recovery reported" } ?? "Unknown"))
                        if let device = model.snapshot?.device {
                            ForEach(["model", "firmware", "base_revision", "serial", "total_count"], id: \.self) { key in
                                if let value = device[key], value != .null { StatusLine(title: key.replacingOccurrences(of: "_", with: " ").capitalized, value: value.text) }
                            }
                        }
                    }.padding(8)
                }
                ObservationNote(model: model)
                HStack {
                    Button("Open Print Center") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Print Center.app")) }
                    Spacer()
                    Text("Monitoring uses the driver's local status cache.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }
}
struct SuppliesView: View {
    @ObservedObject var model: UtilityModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                supplyBox("Color ribbon", supply: model.snapshot?.ribbon)
                supplyBox("Transfer film", supply: model.snapshot?.film)
                ObservationNote(model: model)
            }.padding(28)
        }
    }
    func supplyBox(_ name: String, supply: SupplyStatus?) -> some View {
        GroupBox(AppStrings.text(name)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(supply?.percentText ?? AppStrings.text("Unknown")).font(.largeTitle.monospacedDigit())
                if let percent = supply?.percent { ProgressView(value: Double(percent), total: 100) }
                if let reference = supply?.reference { StatusLine(title: "Reference", value: reference) }
                if let label = supply?.label { StatusLine(title: "Label", value: AppStrings.text(label)) }
                if let region = supply?.region { StatusLine(title: "Region", value: AppStrings.text(region)) }
                if let type = supply?.type { StatusLine(title: "Type", value: AppStrings.text(type)) }
                if let observed = supply?.identity_observed_at { StatusLine(title: "Identity observed", value: PrinterSnapshot.date(observed).map(AppStrings.date) ?? observed) }
                if supply?.reference == nil && name == "Color ribbon" { Text("Ribbon identity is unavailable. Refresh while idle to read it.").font(.caption).foregroundStyle(.secondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct AccessoriesView: View {
    @ObservedObject var model: UtilityModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let accessories = model.snapshot?.accessories, !accessories.isEmpty {
                    GroupBox("Detected accessories") {
                        ForEach(accessories) { accessory in StatusLine(title: accessory.displayName, value: accessory.displayStatus).padding(.horizontal, 12) }
                    }
                } else { ContentUnavailableView("Accessory status unknown", systemImage: "puzzlepiece.extension", description: Text("Refresh while idle to read supported accessory status.")) }
                ObservationNote(model: model)
            }.padding(28)
        }
    }
}
struct PrinterSettingsView: View {
    @ObservedObject var model: UtilityModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Settings are read from the connected printer.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Read Settings") { Task { await model.refreshSettings() } }.disabled(!model.canReadDetails)
                }
                if model.settingsNeedRefresh { Text("Read settings before applying a change. After an uncertain result, refresh before trying again.").foregroundStyle(.secondary) }
                if let settings = model.settings {
                    ForEach(Array(Set(settings.settings.map(\.group))).sorted(), id: \.self) { group in
                        GroupBox(AppStrings.text(group)) {
                            VStack(spacing: 14) {
                                ForEach(settings.settings.filter { $0.group == group }) { setting in SettingRow(model: model, setting: setting) }
                            }.padding(12)
                        }
                    }
                    if let information = settings.information, !information.isEmpty {
                        GroupBox("Printer information") {
                            ForEach(information) { entry in StatusLine(title: entry.label, value: entry.value.text).padding(.horizontal, 12) }
                        }
                    }
                } else { ContentUnavailableView("No settings loaded", systemImage: "slider.horizontal.3", description: Text("Read settings while the printer and queue are idle.")) }
            }.padding(28)
        }
    }
}
struct SettingRow: View {
    @ObservedObject var model: UtilityModel
    let setting: PrinterSetting
    @State private var proposed = ""
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.displayLabel)
                Text(AppStrings.format("Current: %@", setting.current.map { $0.formatted(.number.locale(AppStrings.locale)) } ?? AppStrings.text("Unknown"))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if setting.acceptsInput {
                if let choices = setting.choices, !choices.isEmpty {
                    Picker(setting.displayLabel, selection: $proposed) {
                        ForEach(choices) { choice in Text(AppStrings.text(choice.label)).tag(String(choice.value)) }
                    }.labelsHidden().frame(maxWidth: 190)
                } else {
                    TextField("Value", text: $proposed).frame(width: 65).textFieldStyle(.roundedBorder)
                    Text("\(setting.minimum ?? 0)…\(setting.maximum ?? 0)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Apply") { if let value = Int(proposed) { Task { await model.apply(setting, value: value) } } }
                    .disabled(!model.canChangeSettings || Int(proposed) == setting.current || Int(proposed).map(setting.accepts) != true)
            } else { Text("Read-only").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { proposed = setting.current.map(String.init) ?? "" }
        .onChange(of: setting.current) { _, current in proposed = current.map(String.init) ?? "" }
    }
}
struct PDFPreview: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = url.flatMap(PDFDocument.init(url:)) }
    }
}
struct PrintPDFView: View {
    @ObservedObject var model: UtilityModel
    @State private var source: URL?
    @State private var choosing = false
    @State private var copies = 1
    @State private var sides = "two-sided-long-edge"
    @State private var scaling = "none"
    @State private var documentError: String?
    @State private var documentDetails: String?
    @State private var confirmPrint = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Choose PDF…") { choosing = true }
                Text(source?.lastPathComponent ?? AppStrings.text("No PDF selected")).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            PDFPreview(url: source).frame(minHeight: 250).overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if let error = documentError { Text(error).foregroundStyle(.red) }
            if let details = documentDetails { TechnicalDetails(text: details) }
            HStack {
                Stepper(AppStrings.format("Copies: %ld", copies), value: $copies, in: 1...100).frame(minWidth: 110)
                Picker("Sides", selection: $sides) {
                    Text("One-sided").tag("one-sided")
                    Text("Two-sided · long edge").tag("two-sided-long-edge")
                    Text("Two-sided · short edge").tag("two-sided-short-edge")
                }
                Picker("Scaling", selection: $scaling) {
                    Text("Actual size").tag("none")
                    Text("Fit").tag("fit")
                    Text("Fill").tag("fill")
                }
            }
            HStack {
                Text("CR80 53.98 × 85.60 mm · 600 dpi").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Print…") { confirmPrint = true }.buttonStyle(.borderedProminent)
                    .disabled(source == nil || documentError != nil || !model.canPrint)
            }
        }.padding(24)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { result in
            do {
                let url = try result.get()
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 && size <= 256 * 1024 * 1024, let document = PDFDocument(url: url), !document.isEncrypted, (1...100).contains(document.pageCount) else {
                    throw AppFailure.message("Choose an unencrypted PDF with 1–100 pages, no larger than 256 MiB.")
                }
                source = url; documentError = nil; documentDetails = nil
            } catch {
                source = nil
                if case AppFailure.message(let text) = error {
                    documentError = AppStrings.text(text); documentDetails = nil
                } else {
                    documentError = AppStrings.text("The PDF could not be opened. Check the file and choose it again.")
                    documentDetails = error.localizedDescription
                }
            }
        }
        .confirmationDialog("Print this PDF on Evolis Avansia?", isPresented: $confirmPrint, titleVisibility: .visible) {
            Button(AppStrings.format("Print copies: %ld", copies)) { if let source { Task { await model.printPDF(source, copies: copies, sides: sides, scaling: scaling) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This sends the selected PDF to the printer queue and can produce physical cards.") }
    }
}
struct RecoveryView: View {
    @ObservedObject var model: UtilityModel
    @State private var confirmCancel = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(AppStrings.text(model.snapshot?.recoveryRequired == true ? "Card inspection required" : "Recovery status"), systemImage: "exclamationmark.triangle").font(.title2)
                Text("If a card outcome is uncertain, inspect the card and printer before clearing the recovery record. Clear local queued jobs in Print Center first.")
                GroupBox("Stopped remote job") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Remote job ID", text: $model.stoppedJobID).textFieldStyle(.roundedBorder).frame(width: 200)
                        Button("Cancel Stopped Job…") { confirmCancel = true }
                            .disabled(!model.commandsAllowed || !model.runtimeAvailable || (Int(model.stoppedJobID) ?? 0) <= 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Physical inspection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("I inspected the physical card and printer.", isOn: $model.inspected)
                        Button("Acknowledge Inspected Card") { Task { await model.acknowledge() } }.disabled(!model.canAcknowledge)
                        Text("Acknowledgement is enabled only when recovery is reported and no active remote job is reported. The driver checks queue state again.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                ObservationNote(model: model)
            }.padding(28)
        }
        .confirmationDialog(AppStrings.format("Cancel stopped remote job %@?", model.stoppedJobID), isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Stopped Job", role: .destructive) { Task { await model.cancelStopped() } }
            Button("Keep Job", role: .cancel) {}
        }
    }
}
struct InstallationView: View {
    @ObservedObject var model: UtilityModel
    @State private var confirmUninstall = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.installationState.explanation).font(.title3)
            StatusLine(title: "Runtime files", value: AppStrings.text(model.runtimeAvailable ? "Available" : "Unavailable"))
            if !model.installationDetails.isEmpty { TechnicalDetails(text: model.installationDetails) }
            Text("Setup reports dependency downloads and installation progress below. Existing jobs and recovery records must be resolved before removing the driver.").foregroundStyle(.secondary)
            Text("Installation downloads the proprietary Evolis SDK from its original distribution. You can also import an official version 9.4.1 SDK archive or library. No Python runtime is required.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Import Official SDK…") {
                    let panel = NSOpenPanel()
                    panel.title = AppStrings.text("Import Official Evolis SDK 9.4.1")
                    panel.allowedContentTypes = [UTType(filenameExtension: "whl") ?? .zip, UTType(filenameExtension: "dylib") ?? .data]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url { Task { @MainActor in await model.importSDK(url) } }
                    }
                }.disabled(!model.commandsAllowed)
                Button("Open Official SDK Page") { NSWorkspace.shared.open(URL(string: "https://www2.evolis.com/sdk")!) }
            }
            HStack {
                Button("Install") { Task { await model.setupAction("install") } }.disabled(!model.canInstall)
                Button("Update") { Task { await model.setupAction("upgrade") } }.disabled(!model.canUpdate)
                Button("Check Installation") { Task { await model.refreshInstallation() } }.disabled(!model.commandsAllowed)
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }.disabled(!model.canUninstall)
            }
            if model.output.isEmpty { Text("Command output will appear here.").foregroundStyle(.secondary) }
            else { TechnicalDetails(text: model.output) }
            Spacer(minLength: 0)
        }.padding(28)
        .confirmationDialog("Uninstall the Avansia driver for this user?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await model.setupAction("uninstall") } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
