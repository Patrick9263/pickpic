import Testing

@testable import PickPic

struct UploadStageTests {
    // Every case UploadStage currently defines. CLAUDE.md trap #2: adding a
    // case here doesn't get caught by the compiler the way a `switch` does,
    // so this list needs a manual update alongside the ~7 exhaustive
    // switches elsewhere when a new stage is introduced.
    private static let allStages: [UploadStage] = [
        .queued, .preparing, .prepared, .preflighting,
        .converting, .readyToUpload, .uploading, .completed, .failed,
    ]

    @Test
    func everyStageHasATitleAndSystemImage() {
        for stage in Self.allStages {
            #expect(!stage.title.isEmpty)
            #expect(!stage.systemImage.isEmpty)
        }
    }

    @Test(arguments: [
        UploadStage.preparing, .preflighting, .converting, .uploading,
    ])
    func activeOperationStagesReportBusy(stage: UploadStage) {
        #expect(stage.isActiveOperation)
    }

    @Test(arguments: [
        UploadStage.queued, .prepared, .readyToUpload, .completed, .failed,
    ])
    func idleStagesReportNotBusy(stage: UploadStage) {
        #expect(!stage.isActiveOperation)
    }

    @Test
    func activeAndIdleStagesPartitionAllCases() {
        let active = Set(Self.allStages.filter(\.isActiveOperation))
        let idle = Set(Self.allStages.filter { !$0.isActiveOperation })

        #expect(active.union(idle) == Set(Self.allStages))
        #expect(active.isDisjoint(with: idle))
    }
}
