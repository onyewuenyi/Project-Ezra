//
//  BriefHomeView.swift
//  Project-Ezra
//
//  The Today tab's container: a thin NavigationStack that owns the day-scoped
//  `TodayPlanStore` and hands it (plus the brain) to the sequence surface. The
//  toolbar (AI trail + Replan) lives on `BriefView`, where the sequence state is.
//

import SwiftUI

struct BriefHomeView: View {
    @Environment(AppBrain.self) private var brain
    @State private var store = TodayPlanStore()

    var body: some View {
        NavigationStack {
            BriefView(brain: brain, store: store)
                .navigationTitle("")
                .toolbarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    BriefHomeView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
