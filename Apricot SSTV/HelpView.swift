// SPDX-License-Identifier: GPL-3.0-only
//
//  HelpView.swift
//  Apricot SSTV
//
//  Help, entirely in the app (no web pages): a list of topics, each a
//  short article. The text is in the String Catalog with everything else,
//  so it's translated the same way.
//

import SwiftUI

struct HelpView: View {
    var body: some View {
        List {
            Section {
                topic("Getting Started", systemImage: "play.circle") { GettingStartedHelp() }
                topic("Receiving", systemImage: "antenna.radiowaves.left.and.right") { ReceivingHelp() }
                topic("Sending", systemImage: "paperplane") { SendingHelp() }
                topic("Darkroom", systemImage: "wand.and.stars") { DarkroomHelp() }
                topic("Notes and Events", systemImage: "calendar") { EventsHelp() }
                topic("Apple Watch", systemImage: "applewatch") { WatchHelp() }
            }
            Section {
                topic("Questions", systemImage: "questionmark.bubble") { QuestionsHelp() }
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func topic<Destination: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

// MARK: - Articles

private struct GettingStartedHelp: View {
    var body: some View {
        HelpArticle("Getting Started") {
            Text("Apricot SSTV turns the sound of slow-scan television into pictures. Tune your radio to a frequency where SSTV is sent, and let your iPhone or Apple Watch hear it.")

            HelpSection("Connect the audio") {
                Text("Hold the iPhone near the radio's speaker, or, for a much cleaner signal, connect the radio's audio output to a USB audio interface plugged into the iPhone. Receive shows which input is in use.")
            }
            HelpSection("Listen") {
                Text("Tap Listen. When a picture's VIS header is heard, the picture builds line by line, and it is saved to Pictures when it ends. You can lock the iPhone: receiving carries on.")
            }
            HelpSection("Set the level") {
                Text("Adjust the radio's volume so the Level bar stays in the green, between the −40 and −10 dB marks. The red stretch at the right end means it's about to clip: if the bar turns red and says Clipping, turn the radio down.")
            }
        }
    }
}

private struct ReceivingHelp: View {
    var body: some View {
        HelpArticle("Receiving") {
            HelpSection("The tuning bar") {
                Text("Its marks are the tones SSTV uses: 1200 Hz (sync), 1500 Hz (black), 1900 Hz (the VIS leader) and 2300 Hz (white). During a picture the marker moves between black and white; a steady 1900 Hz means a picture is about to start. Tuning errors up to ±150 Hz are corrected from the VIS header.")
            }
            HelpSection("Straight pictures") {
                Text("If the sender's clock runs a little fast or slow, a picture would lean. Apricot SSTV measures this from the line syncs and straightens the picture as it goes; Sender's clock shows the difference in ppm.")
            }
            HelpSection("A missed start") {
                Text("With Start Without VIS on, a picture whose header was missed still starts after a few lines, from its line syncs.")
            }
            HelpSection("Choosing a mode") {
                Text("Automatic suits most listening. If you know what's coming, such as PD120 from the International Space Station, choose that mode in Settings or the ⋯ menu on Receive. Other modes are then ignored, which also avoids false starts in noise.")
            }
            HelpSection("Fades and gaps") {
                Text("If the signal fades or the audio is interrupted, the picture carries on at the right line when it comes back within two minutes.")
            }
            HelpSection("Stopping by itself") {
                Text("Listening uses a lot of battery, so it stops when no picture has come in for the Receive Timeout in Settings (10 minutes at first), never in the middle of a picture. In its last two minutes a countdown shows, with Keep Listening to start it over. Choose Never to listen until you tap Stop.")
            }
            HelpSection("Recordings made elsewhere") {
                Text("Decode Audio File, in the ⋯ menu on Receive, finds the pictures in a recording made with another device or app (WAV, M4A, MP3 and others), as if it were played to Receive. Each is saved in Pictures with its stretch of the recording as raw audio, to develop again in the darkroom; its note says which file it came from. The file itself isn't changed. (Import Library, in Settings, is something else: it takes back a folder this app exported.)")
            }
            HelpSection("Raw audio") {
                Text("With Save Raw Audio on, each picture keeps the sound it was decoded from, from as long before the picture to as long after it as the picture takes to send, so nothing is lost if its start or end was misjudged. Share it from the picture's details as a WAV file to decode it in another program, or to show someone what was received. Tapping Stop ends the recording there. Turn it off in Settings to save space.")
            }
        }
    }
}

private struct DarkroomHelp: View {
    var body: some View {
        HelpArticle("Darkroom") {
            HelpSection("Developed again, not edited") {
                Text("Many apps straighten a picture by bending the image afterwards: pixels are slid, stretched and filled in, and whatever was lost stays lost. The darkroom works on the sound instead. It decodes the picture's raw audio again, reading every line at the timing you set, so nothing is stretched or made up: every pixel comes from the signal, as when the picture first came in.")
            }
            HelpSection("What it needs") {
                Text("The picture's raw audio, kept when Save Raw Audio is on (on the iPhone, and on the watch for its own pictures). A picture without it can still be shared, but not developed again. Open a picture and tap Edit, or Develop Again in the Darkroom.")
            }
            HelpSection("Develop") {
                Text("Decodes the whole recording with the latest decoder: the slant fitted over the whole picture, syncs found where the first decode missed them, weak lines carried through. Often that's all a picture needs.")
            }
            HelpSection("By hand") {
                Text("Then, from what Develop found: the mode, where the first line starts (a line at a time, or finely), the slant (the sender's clock error, set by hand or measured on the picture with two points on an upright edge or a region with upright edges) and the horizontal position. Every change is decoded again from the sound. Touch and hold the picture to compare with the picture as received.")
            }
            HelpSection("Nothing is overwritten") {
                Text("Done keeps the developed picture beside the original, which is never changed, and the raw audio stays. Revert to Original goes back at any time.")
            }
            HelpSection("Fragments") {
                Text("A start too short to count as a picture, mostly a false start, is kept as a fragment, with its raw audio. Its sound may hold a whole picture whose start was missed. Fragments are shown apart: choose Fragments in the menu at the top right of Pictures.")
            }
        }
    }
}

private struct EventsHelp: View {
    var body: some View {
        HelpArticle("Notes and Events") {
            HelpSection("Notes") {
                Text("Each picture's details have room for its frequency, its source (a satellite, a callsign) and a note. They're kept apart from how it was received, which never changes.")
            }
            HelpSection("Events") {
                Text("An event gathers the pictures of one occasion, such as an ISS SSTV weekend or a net. Make one current, and pictures received from then on, here or on Apple Watch, go into it until the end of its last day. Others can be added with Select in Pictures. An event's pictures are grouped by when they came in: a gap of more than 20 minutes starts a new group.")
            }
        }
    }
}

private struct SendingHelp: View {
    var body: some View {
        HelpArticle("Sending") {
            HelpSection("Connect the radio") {
                Text("Connect the iPhone's audio output (a headphone adapter or a USB audio interface) to the radio's microphone or data input, and turn on VOX so the radio transmits when it hears the audio. The iPhone's volume sets the level: start low and raise it until the radio's ALC just begins to move.")
            }
            HelpSection("Prepare the picture") {
                Text("Choose a picture from the photo library, Favorites or Files, then tap it to move and zoom it in the frame. Favorites keeps pictures you send often, each where you last placed it, and two test cards for trying out a setup. Your callsign is drawn at the top left; add a second line, such as a signal report, if you like.")
            }
            HelpSection("Check before going on the air") {
                Text("With a new setup, tap the share button to make a WAV and decode it with another SSTV program, or play it to Apricot SSTV on Apple Watch.")
            }
            HelpSection("Send") {
                Text("Tap Send. Receiving stops while sending. Keep the radio connected until the progress bar finishes; you can lock the iPhone.")
            }
            HelpSection("On the air") {
                Text("Transmitting needs an amateur radio license and must follow its rules, including identifying your station.")
            }
        }
    }
}

private struct WatchHelp: View {
    var body: some View {
        HelpArticle("Apple Watch") {
            HelpSection("Receiving on the watch") {
                Text("Open Apricot SSTV on the watch, tap Listen, and keep the watch near the radio's speaker. The watch taps you when a picture starts, when it's saved, when the signal is lost, and when listening stops by itself.")
            }
            HelpSection("Lowering your wrist") {
                Text("The first time you open the app on the watch, you choose what lowering your wrist does: keep listening, or stop to save battery (after the picture coming in). Change it under Wrist Down in the watch's Settings, which are apart from the iPhone's. If it stopped, the reason stays on screen, with a button to listen again and keep listening from then on.")
            }
            HelpSection("Pictures come to the iPhone") {
                Text("Every saved picture goes to the iPhone by itself when the iPhone app is installed and the two are near each other. You don't need to open either app. Its raw audio follows, if saved. In the watch's Pictures, a phone icon marks the ones the iPhone already has in full.")
            }
            HelpSection("Freeing space") {
                Text("Delete Synced, in the watch's Pictures, removes the pictures the iPhone already has. To keep less on the watch, turn off Save Raw Audio in the watch's Settings.")
            }
        }
    }
}

private struct QuestionsHelp: View {
    var body: some View {
        HelpArticle("Questions") {
            HelpSection("A picture was sent but nothing happened.") {
                Text("Check that the Level bar moves, that Mode is Automatic or matches the picture, and that the tuning marker sits near 1900 Hz during the VIS header. Weak or distorted audio can hide the header; Start Without VIS helps.")
            }
            HelpSection("The picture is noisy or the colors are wrong.") {
                Text("Usually it's the level: too low lets noise in, too high (Clipping) distorts the tones. A cable or USB interface is much cleaner than a microphone held to a speaker.")
            }
            HelpSection("It says a mode was skipped.") {
                Text("Either that mode isn't one of the 14 that Apricot SSTV handles, or you chose a single mode and this picture is a different one.")
            }
            HelpSection("Pictures from the watch don't reach the iPhone.") {
                Text("The iPhone app must be installed, and the watch and iPhone near each other. Transfers wait and finish by themselves. Settings shows whether the watch app is installed.")
            }
            HelpSection("Does Apricot SSTV collect any data?") {
                Text("No. There are no ads, no accounts and no analytics. Nothing leaves your devices, except pictures going from your watch to your iPhone.")
            }
        }
    }
}

// MARK: - Layout

/// A help page: a column of text sections under an inline title.
private struct HelpArticle<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A heading and the text under it.
private struct HelpSection<Content: View>: View {
    let heading: LocalizedStringKey
    let content: Content

    init(_ heading: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.heading = heading
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.headline)
            content
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
