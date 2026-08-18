//
//  VolumeNormalizationTests.swift
//  AureliaTests
//
//  What a measured gain is worth as a volume.
//
//  The arithmetic is one line, and every way it can go wrong is audible: a
//  sign the wrong way round makes loud tracks louder, a missing measurement
//  read as zero decibels would mute a song, and honouring a wild figure would
//  leave one all but silent.
//

import Foundation
import Testing

@testable import Aurelia

struct VolumeNormalizationTests {

    @Test func aTrackWithNothingMeasuredPlaysUntouched() {
        #expect(VolumeNormalization.volume(forDecibels: nil) == 1)
        #expect(VolumeNormalization.volume(for: .unmeasured, mode: .track) == 1)
    }

    @Test func aLoudTrackIsBroughtDownByItsGain() {
        // -6 dB is half the amplitude, -20 dB a tenth of it.
        #expect(abs(VolumeNormalization.volume(forDecibels: -6.0206) - 0.5) < 0.001)
        #expect(abs(VolumeNormalization.volume(forDecibels: -20) - 0.1) < 0.001)
    }

    @Test func aQuietTrackIsLeftAsMasteredRatherThanTurnedUp() {
        #expect(VolumeNormalization.volume(forDecibels: 3) == 1)
        #expect(VolumeNormalization.volume(forDecibels: 0) == 1)
    }

    @Test func aWildMeasurementIsHeldAtTheFloor() {
        let floor = VolumeNormalization.volume(forDecibels: VolumeNormalization.floorDecibels)
        #expect(VolumeNormalization.volume(forDecibels: -60) == floor)
        #expect(floor > 0)
    }

    @Test func nonsenseIsNotAppliedAtAll() {
        #expect(VolumeNormalization.volume(forDecibels: .nan) == 1)
        #expect(VolumeNormalization.volume(forDecibels: -.infinity) == 1)
    }

    @Test func theModeDecidesWhichMeasurementIsUsed() {
        let gain = NormalizationGain(track: -8, album: -4)

        #expect(gain.decibels(for: .off) == nil)
        #expect(gain.decibels(for: .track) == -8)
        #expect(gain.decibels(for: .album) == -4)
    }

    @Test func albumModeFallsBackToTheTrackWhenTheAlbumWasNotMeasured() {
        let gain = NormalizationGain(track: -8, album: nil)

        #expect(gain.decibels(for: .album) == -8)
        #expect(VolumeNormalization.volume(for: gain, mode: .album)
                == VolumeNormalization.volume(for: gain, mode: .track))
    }

    @Test func offNormalizesNothing() {
        #expect(VolumeNormalization.volume(for: NormalizationGain(track: -12, album: -12), mode: .off) == 1)
    }

    @Test func anUnreadableStoredModeFallsBackToTheDefault() {
        #expect(NormalizationMode(rawValue: "loudest") == nil)
        #expect(NormalizationMode.default == .off)
    }
}
