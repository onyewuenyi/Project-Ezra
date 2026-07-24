//
//  TodayHomeView.swift
//  Project-Ezra
//
//  The Today tab's container: a thin NavigationStack that owns the day-scoped
//  `TodayPlanStore` and hands it (plus the brain) to the sequence surface. The
//  toolbar (AI trail + Replan) lives on `TodayView`, where the sequence state is.
//

import SwiftUI

struct TodayHomeView: View {
    @Environment(AppBrain.self) private var brain
    @State private var store = TodayPlanStore()

    var body: some View {
        NavigationStack {
            TodayView(brain: brain, store: store)
                .navigationTitle("")
                .toolbarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    TodayHomeView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
