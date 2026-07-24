//
//  ContentView.swift
//  Project-Ezra
//
//  App root. Delegates to the four-tab shell.
//

import SwiftUI
import CoreData

struct ContentView: View {
    var body: some View {
        RootTabView()
    }
}

#Preview {
    ContentView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
