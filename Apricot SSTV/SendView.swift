// SPDX-License-Identifier: GPL-3.0-only
//
//  SendView.swift
//  Apricot SSTV
//
//  Pick a photo, place it in the frame, choose a mode, put your callsign
//  on it, and send it to the radio through the audio output, or export
//  it as a WAV. Send / Stop is at the top right, as in Mail; the share
//  button at the top left makes a WAV of the picture (a spinner shows
//  while it's encoded, off the main thread) and then opens the share
//  sheet. The progress of a transmission shows under the picture.
//
//  A picture comes from the photo library, Favorites (pictures kept in
//  the app, and two built-in test cards) or Files, from one menu. A
//  favorite remembers where it was placed in the frame. The mode is chosen
//  from a list grouped by family, with each mode's size and length.
//

import SwiftUI
import PhotosUI
import Combine
import UniformTypeIdentifiers

struct SendView: View {
    @EnvironmentObject private var receiver: Receiver
    @EnvironmentObject private var tx: Transmitter

    @AppStorage("tx.mode") private var modeVIS = 44
    @AppStorage("tx.callsign") private var callsign = ""
    @AppStorage("tx.text") private var overlayText = ""

    // The text fields edit these drafts; the picture is redrawn only when
    // a field is left (or Return is pressed), not on every keystroke.
    @State private var callsignDraft = ""
    @State private var textDraft = ""
    @FocusState private var focus: Field?

    private enum Field { case callsign, text }

    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var placement = PhotoPlacement()
    @State private var composed: UIImage?
    @State private var adjusting = false
    @State private var makingWAV = false
    @State private var sharedWAV: SharedWAV?
    @State private var shareError: String?
    @State private var loadingPhoto = false
    @State private var showLibrary = false
    @State private var showFavorites = false
    @State private var showFiles = false
    /// The favorite the current photo came from, so its placement is kept.
    @State private var favoriteID: String?
    @State private var photoError: String?

    private var mode: SSTVMode {
        SSTVMode.byVIS(modeVIS) ?? SSTVMode.all[0]
    }

    var body: some View {
        NavigationStack {
            Form {
                pictureSection
                transmissionSection
                modeSection
                photoSection
                textSection
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.large)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    shareButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    sendButton
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
        }
        .sheet(item: $sharedWAV) { wav in
            ActivityView(url: wav.url) { sharedWAV = nil }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert(
            "Couldn't Make the WAV",
            isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .sheet(isPresented: $adjusting) {
            if let photo {
                PhotoAdjustView(
                    photo: photo,
                    mode: mode,
                    overlay: PictureComposer.overlay(mode: mode, callsign: callsign, text: overlayText),
                    placement: $placement
                )
            }
        }
        .onAppear {
            callsignDraft = callsign
            textDraft = overlayText
            recompose()
        }
        .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
        .sheet(isPresented: $showFavorites) {
            FavoritesView { pick in
                photo = PictureComposer.prepare(pick.photo)
                placement = pick.placement
                favoriteID = pick.favoriteID
                recompose()
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            loadFile(result)
        }
        .alert(
            "Couldn't Open the Picture",
            isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoError ?? "")
        }
        .onChange(of: focus) { commitText() }
        .onChange(of: pickerItem) { loadPhoto() }
        .onChange(of: placement) {
            recompose()
            if let favoriteID { FavoritesStore.update(id: favoriteID, placement: placement) }
        }
        .onChange(of: modeVIS) { recompose() }
        .onChange(of: callsign) { recompose() }
        .onChange(of: overlayText) { recompose() }
    }

    // MARK: Sections

    /// The picture edge to edge in a section of its own (the section
    /// rounds it, as on Receive). Under it the transmission's progress,
    /// then the mode, then the photo controls.
    private var pictureSection: some View {
        Section {
            if photo == nil {
                // Nothing to show yet: the same light placeholder as
                // Receive, and tapping it picks a photo.
                Menu {
                    photoMenuItems
                } label: {
                    Color(.secondarySystemFill)
                        .aspectRatio(CGFloat(mode.width) / CGFloat(mode.height), contentMode: .fit)
                        .overlay {
                            if loadingPhoto {
                                ProgressView()
                            } else {
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.largeTitle)
                                    Text("Choose a Picture")
                                        .font(.subheadline)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .disabled(tx.isBusy)
            } else if let composed {
                Button {
                    openAdjust()
                } label: {
                    Image(uiImage: composed)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            if loadingPhoto { ProgressView() }
                        }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .accessibilityLabel("Picture to send")
                .accessibilityHint("Opens the adjust screen.")
            }
        }
    }

    private var photoSection: some View {
        Section {
            Menu {
                photoMenuItems
                if photo != nil {
                    Divider()
                    Button {
                        addToFavorites()
                    } label: {
                        Label(favoriteID == nil ? LocalizedStringKey("Add to Favorites") : LocalizedStringKey("In Favorites"), systemImage: favoriteID == nil ? "star" : "star.fill")
                    }
                    .disabled(favoriteID != nil)
                }
            } label: {
                Label(photo == nil ? LocalizedStringKey("Choose Picture") : LocalizedStringKey("Change Picture"), systemImage: "photo.on.rectangle")
            }
            .disabled(tx.isBusy)

            Button {
                openAdjust()
            } label: {
                Label("Adjust Position and Size", systemImage: "crop")
            }
            .disabled(photo == nil || tx.isBusy)
        } footer: {
            Text("Tap the picture or Adjust to move and zoom the photo in the frame.")
        }
    }

    private var modeSection: some View {
        Section {
            NavigationLink {
                ModeList(selection: $modeVIS)
            } label: {
                LabeledContent("Mode", value: mode.name)
            }
            .disabled(tx.isBusy)
        } footer: {
            Text(verbatim: "\(mode.width) × \(mode.height) · \(mode.lengthText)")
        }
    }

    /// Where a picture can come from.
    @ViewBuilder
    private var photoMenuItems: some View {
        Button {
            showLibrary = true
        } label: {
            Label("Photo Library", systemImage: "photo.on.rectangle")
        }
        Button {
            showFavorites = true
        } label: {
            Label("Favorites", systemImage: "star")
        }
        Button {
            showFiles = true
        } label: {
            Label("Files", systemImage: "folder")
        }
    }

    private var textSection: some View {
        Section("Text on the picture") {
            TextField("Callsign", text: $callsignDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focus, equals: .callsign)
                .submitLabel(.next)
                .onSubmit { focus = .text }
            TextField("Second line (optional)", text: $textDraft)
                .autocorrectionDisabled()
                .focused($focus, equals: .text)
                .submitLabel(.done)
                .onSubmit { focus = nil }
        }
        .disabled(tx.isBusy)
    }

    // MARK: Share / Send / Stop

    /// Makes the WAV first (the button turns into a spinner), then opens
    /// the share sheet with the finished file.
    @ViewBuilder
    private var shareButton: some View {
        if makingWAV {
            ProgressView()
                .accessibilityLabel("Making the WAV")
        } else {
            Button {
                shareWAV()
            } label: {
                Label("Share WAV", systemImage: "square.and.arrow.up")
            }
            .disabled(photo == nil || composed == nil || tx.isBusy)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if tx.isBusy {
            Button("Stop", role: .destructive) {
                tx.stop()
            }
            .tint(.red)
        } else {
            Button("Send") {
                send()
            }
            .buttonStyle(.glassProminent)
            .disabled(photo == nil || loadingPhoto)
        }
    }

    /// Always two lines, so the form below doesn't move when sending
    /// starts or ends.
    private var transmissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                switch tx.state {
                case .idle:
                    // The mode is in its own row below: here, only the state.
                    Text(photo == nil ? LocalizedStringKey("No Picture Yet") : LocalizedStringKey("Ready to Send"))
                    Group {
                        if let notice = tx.notice {
                            Text(notice)
                        } else if photo == nil {
                            Text("Choose a picture to send.")
                        } else {
                            Text("Tap Send. The radio keys on VOX.")
                        }
                    }
                        .foregroundStyle(.secondary)
                case .encoding:
                    Text("Encoding \(mode.name)…")
                    ProgressView()
                        .progressViewStyle(.linear)
                case .sending:
                    HStack {
                        Text("Sending \(mode.name)")
                        Spacer()
                        Text(verbatim: "\(Self.clock(tx.elapsed)) / \(Self.clock(tx.duration))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: tx.elapsed, total: max(tx.duration, 1))
                }
            }
            .font(.subheadline)
            .transaction { $0.animation = nil }
        } footer: {
            Text(outputFooter)
        }
    }

    private var outputFooter: String {
        if tx.state == .sending, let output = tx.outputName {
            return String(localized: "Output: \(output). The iPhone's volume sets the level.")
        }
        return String(localized: "Connect the audio output (headphone adapter or USB interface) to the radio's audio input; the iPhone's volume sets the level. Before sending on the air with a new setup, share a WAV (top left) and check it with another SSTV decoder.")
    }

    // MARK: Actions

    private func loadPhoto() {
        guard let item = pickerItem else { return }
        loadingPhoto = true
        Task {
            defer { loadingPhoto = false }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { return }
            photo = PictureComposer.prepare(image)
            placement = PhotoPlacement()
            favoriteID = nil
            recompose()
            pickerItem = nil        // so picking the same photo again loads it again
        }
    }

    /// A picture picked in Files: read it while the app may.
    private func loadFile(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                photoError = String(localized: "The file isn't a picture Apricot SSTV can read.")
                return
            }
            photo = PictureComposer.prepare(image)
            placement = PhotoPlacement()
            favoriteID = nil
            recompose()
        case .failure(let error):
            photoError = error.localizedDescription
        }
    }

    /// Keeps the photo, with its place in the frame, for sending again.
    private func addToFavorites() {
        guard let photo else { return }
        do {
            try FavoritesStore.add(photo: photo, placement: placement)
            favoriteID = FavoritesStore.list().first?.id
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func recompose() {
        composed = PictureComposer.compose(
            photo: photo,
            placement: placement,
            mode: mode,
            callsign: callsign,
            text: overlayText
        )
    }

    /// Saves the drafts; changing callsign / overlayText redraws the picture.
    private func commitText() {
        if callsignDraft != callsign { callsign = callsignDraft }
        if textDraft != overlayText { overlayText = textDraft }
    }

    /// Before using the picture: take what's in a field still being edited.
    private func commitAndRecompose() {
        focus = nil
        if callsignDraft != callsign || textDraft != overlayText {
            commitText()
            recompose()
        }
    }

    private func shareWAV() {
        commitAndRecompose()
        guard let composed, let rgb = PictureComposer.rgbBytes(of: composed, mode: mode) else { return }
        let mode = self.mode
        makingWAV = true
        Task {
            defer { makingWAV = false }
            do {
                let url = try await Transmitter.exportWAV(rgb: rgb, mode: mode)
                sharedWAV = SharedWAV(url: url)
            } catch {
                shareError = error.localizedDescription
            }
        }
    }

    private func openAdjust() {
        guard photo != nil else { return }
        commitAndRecompose()
        adjusting = true
    }

    private func send() {
        commitAndRecompose()
        guard let composed, let rgb = PictureComposer.rgbBytes(of: composed, mode: mode) else { return }
        if receiver.isRunning { receiver.stop() }
        tx.send(rgb: rgb, mode: mode)
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Share sheet

/// A finished WAV, ready to hand to the share sheet.
private struct SharedWAV: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, for a file that already exists.
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDone() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Mode list

/// Every mode, by family, with its picture size and how long it takes.
private struct ModeList: View {
    @Binding var selection: Int
    @Environment(\.dismiss) private var dismiss

    private struct Family: Identifiable {
        let name: String
        let vis: [Int]
        var id: String { name }
    }

    private static let families = [
        Family(name: "Robot", vis: [8, 12]),
        Family(name: "Martin", vis: [44, 40]),
        Family(name: "Scottie", vis: [60, 56, 76]),
        Family(name: "PD", vis: [93, 99, 95, 98, 96, 97, 94]),
    ]

    var body: some View {
        List {
            ForEach(Self.families) { family in
                Section {
                    ForEach(family.vis.compactMap { SSTVMode.byVIS($0) }) { m in
                        Button {
                            selection = m.vis
                            dismiss()
                        } label: {
                            HStack {
                                Text(verbatim: m.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(verbatim: "\(m.width) × \(m.height)")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 76, alignment: .trailing)
                                Text(verbatim: m.lengthText)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 44, alignment: .trailing)
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                                    .opacity(m.vis == selection ? 1 : 0)
                                    .accessibilityHidden(m.vis != selection)
                            }
                            .monospacedDigit()
                        }
                        .accessibilityAddTraits(m.vis == selection ? .isSelected : [])
                    }
                } header: {
                    Text(verbatim: family.name)
                }
            }
        }
        .navigationTitle("Mode")
        .navigationBarTitleDisplayMode(.inline)
    }
}
