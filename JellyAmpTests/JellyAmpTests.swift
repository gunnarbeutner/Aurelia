//
//  JellyAmpTests.swift
//  JellyAmpTests
//
//  Created by Grafton on 10/17/25.
//

import Testing
@testable import JellyAmp

struct JellyAmpTests {

    @Test func decodesAudioMusePluginInfo() throws {
        let data = Data(#"{"Version":"1.4.2","AvailableEndpoints":["GET /AudioMuseAI/health"]}"#.utf8)
        let info = try JSONDecoder().decode(AudioMusePluginInfo.self, from: data)

        #expect(info.version == "1.4.2")
        #expect(info.availableEndpoints == ["GET /AudioMuseAI/health"])
    }

    @Test func decodesAudioMuseProgressAndDetails() throws {
        let data = Data(#"{"task_id":"analysis","task_type":"library","status":"running","progress":"42.5","details":{"status_message":"Analyzing albums"},"running_time_seconds":12}"#.utf8)
        let status = try JSONDecoder().decode(AudioMuseTaskStatus.self, from: data)

        #expect(status.taskId == "analysis")
        #expect(status.progressFraction == 0.425)
        #expect(status.message == "Analyzing albums")
        #expect(status.isActive)
    }

}
