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
            Text("Apricot SSTV turns the sound of slow-scan television into pictures, and your pictures into that sound, to send through your radio. To receive, tune your radio to a frequency where SSTV is sent, and let your iPhone or Apple Watch hear it.")

            HelpSection("Connect the audio") {
                Text("Hold the iPhone near the radio's speaker, or, for a much cleaner signal, connect the radio's audio output to a USB audio interface plugged into the iPhone. Receive shows which input is in use.")
            }
            HelpSection("Listen") {
                Text("You can lock the iPhone: receiving carries on.")
            }
            HelpSection("Set the level") {
                Text("Keep the Level bar in the green, between −40 and −10 dB. If it turns red and says Clipping, turn the radio down.")
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
                Text("Listening stops when no picture has come in for the Receive Timeout in Settings, never in the middle of a picture.")
            }
            HelpSection("Recordings made elsewhere") {
                Text("Decode Audio File, in the ⋯ menu on Receive, finds the pictures in a recording (WAV, M4A, MP3 and others). Each keeps its stretch of the recording as raw audio. When they were received is worked out from the file's date.")
            }
            HelpSection("Raw audio") {
                Text("With Save Raw Audio on, each picture keeps its sound, with as long again before and after it as it takes to send, in case its start or end was misjudged. Tapping Stop ends the recording there.")
            }
        }
    }
}

private struct DarkroomHelp: View {
    var body: some View {
        HelpArticle("Darkroom") {
            HelpSection("How it works") {
                Text("The darkroom decodes a picture's raw audio again. Every change you make is decoded again from the sound.")
            }
            HelpSection("What it needs") {
                Text("The picture's raw audio, kept when Save Raw Audio is on.")
            }
            HelpSection("Develop") {
                Text("Decodes the whole recording again with the latest decoder. Often that's all a picture needs.")
            }
            HelpSection("By hand") {
                Text("The mode, where the first line starts, the slant and the horizontal position. The slant can be measured on the picture: two points on an edge that should be upright, or a region with upright edges. Touch and hold the picture to compare with the original.")
            }
            HelpSection("Nothing is overwritten") {
                Text("The original picture and its raw audio are never changed. Revert to Original goes back at any time.")
            }
            HelpSection("Fragments") {
                Text("A start too short to count as a picture is kept as a fragment, with its raw audio, which may hold a picture whose start was missed. Fragments are under the menu at the top right of Pictures.")
            }
        }
    }
}

private struct EventsHelp: View {
    var body: some View {
        HelpArticle("Notes and Events") {
            HelpSection("Notes") {
                Text("Each picture's details have room for its frequency, its source and a note.")
            }
            HelpSection("Events") {
                Text("While an event is current, new pictures from the iPhone and Apple Watch go into it, until the end of its last day. In an event, a gap of more than 20 minutes starts a new group.")
            }
        }
    }
}

private struct SendingHelp: View {
    var body: some View {
        HelpArticle("Sending") {
            HelpSection("Connect the radio") {
                Text("Connect the iPhone's audio output (a headphone adapter or a USB audio interface) to the radio's microphone or data input, and turn on VOX. Raise the level until the radio's ALC just begins to move.")
            }
            HelpSection("Prepare the picture") {
                Text("Favorites keeps pictures you send often, each where you last placed it. Built In has a test card, colour bars and the Mandelbrot set. Your callsign is drawn at the top left.")
            }
            HelpSection("Check before going on the air") {
                Text("With a new setup, tap the share button to make a WAV and decode it with another SSTV program, or play it to Apricot SSTV on Apple Watch.")
            }
            HelpSection("Send") {
                Text("Receiving stops while sending. You can lock the iPhone.")
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
                Text("The watch taps you when a picture starts, when it's saved, when the signal is lost, and when listening stops by itself.")
            }
            HelpSection("Lowering your wrist") {
                Text("Whether listening carries on with the wrist down is under Wrist Down in the watch's own Settings. A picture coming in is always finished first.")
            }
            HelpSection("Pictures come to the iPhone") {
                Text("Pictures go to the iPhone by themselves, raw audio after them. In the watch's Pictures, a phone icon marks the ones the iPhone has.")
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
