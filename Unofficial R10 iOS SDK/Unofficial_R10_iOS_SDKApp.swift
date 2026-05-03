//
//  Unofficial_R10_iOS_SDKApp.swift
//  Unofficial R10 iOS SDK
//
//  Created by Hector Zarate on 5/3/26.
//

import SwiftUI
import SwiftData

@main
struct Unofficial_R10_iOS_SDKApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
