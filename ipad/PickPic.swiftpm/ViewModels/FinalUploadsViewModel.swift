import Combine
import Foundation

private enum FinalUploadsViewModelError:
    LocalizedError
{
    case noReadyFinals
    case noVariantRepairs
    
    var errorDescription: String? {
        switch self {
        case .noReadyFinals:
            return """
            No edited JPEGs currently match photos \
            waiting for a final image.
            """
            
        case .noVariantRepairs:
            return """
            No existing finals currently need optimized \
            images.
            """
        }
    }
}

@MainActor
final class FinalUploadsViewModel:
    ObservableObject
{
    @Published private(set)
    var scanResult: FinalUploadScanResult?
    
    @Published private(set)
    var isLoading = false
    
    @Published private(set)
    var isUploading = false
    
    @Published private(set)
    var isRepairingVariants = false
    
    @Published private(set)
    var uploadedCount = 0
    
    @Published private(set)
    var optimizedCount = 0
    
    @Published private(set)
    var currentFilename: String?
    
    @Published private(set)
    var currentStep: String?
    
    @Published private(set)
    var lastUploadedCount: Int?
    
    @Published private(set)
    var lastOptimizedCount: Int?
    
    @Published private(set)
    var variantUploadFailures: [String] = []
    
    @Published private(set)
    var errorMessage: String?
    
    var isBusy: Bool {
        isLoading
        || isUploading
        || isRepairingVariants
    }
    
    func load(
        eventID: String,
        reference: EventFolderReference,
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isBusy else {
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        defer {
            isLoading = false
        }
        
        do {
            scanResult = try await fetchScan(
                eventID: eventID,
                reference: reference,
                using: configuration
            )
        } catch {
            errorMessage =
            error.localizedDescription
        }
    }
    
    func uploadAll(
        eventID: String,
        reference: EventFolderReference,
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isBusy else {
            return
        }
        
        isUploading = true
        uploadedCount = 0
        optimizedCount = 0
        currentFilename = nil
        currentStep = nil
        lastUploadedCount = nil
        lastOptimizedCount = nil
        variantUploadFailures = []
        errorMessage = nil
        
        do {
            let client =
            try configuration.makeClient()
            
            let freshScan =
            try await fetchScan(
                eventID: eventID,
                reference: reference,
                using: configuration
            )
            
            scanResult = freshScan
            
            guard
                !freshScan.candidates.isEmpty
            else {
                throw FinalUploadsViewModelError
                    .noReadyFinals
            }
            
            for candidate in freshScan.candidates {
                currentFilename =
                candidate.editedFilename
                
                currentStep =
                "Preparing optimized images…"
                
                let stagedUpload =
                try await Task.detached(
                    priority: .userInitiated
                ) {
                    try FinalUploadFileService
                        .stage(
                            candidate: candidate,
                            reference: reference
                        )
                }
                .value
                
                do {
                    currentStep =
                    "Uploading full-resolution final…"
                    
                    _ = try await client
                        .uploadFinalPhoto(
                            stagedUpload,
                            to: candidate.photoID
                        )
                    
                    uploadedCount += 1
                    
                    currentStep =
                    "Uploading thumbnail and preview…"
                    
                    do {
                        _ = try await client
                            .uploadFinalVariants(
                                stagedUpload.variants,
                                to: candidate.photoID
                            )
                        
                        optimizedCount += 1
                    } catch {
                        variantUploadFailures.append(
                            candidate.editedFilename
                        )
                    }
                } catch {
                    try? FinalUploadFileService
                        .removeStagedFile(
                            photoID:
                                candidate.photoID
                        )
                    
                    throw error
                }
                
                try? FinalUploadFileService
                    .removeStagedFile(
                        photoID:
                            candidate.photoID
                    )
            }
            
            lastUploadedCount =
            uploadedCount
            
            lastOptimizedCount =
            optimizedCount
            
            currentFilename = nil
            currentStep = nil
            
            scanResult = try await fetchScan(
                eventID: eventID,
                reference: reference,
                using: configuration
            )
            
            isUploading = false
        } catch {
            let uploadError =
            error.localizedDescription
            
            lastUploadedCount =
            uploadedCount
            
            lastOptimizedCount =
            optimizedCount
            
            currentFilename = nil
            currentStep = nil
            isUploading = false
            
            if let refreshedScan =
                try? await fetchScan(
                    eventID: eventID,
                    reference: reference,
                    using: configuration
                )
            {
                scanResult = refreshedScan
            }
            
            errorMessage = uploadError
        }
    }
    
    func repairMissingVariants(
        eventID: String,
        reference: EventFolderReference,
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isBusy else {
            return
        }
        
        isRepairingVariants = true
        optimizedCount = 0
        currentFilename = nil
        currentStep = nil
        lastOptimizedCount = nil
        variantUploadFailures = []
        errorMessage = nil
        
        do {
            let client =
            try configuration.makeClient()
            
            let freshScan =
            try await fetchScan(
                eventID: eventID,
                reference: reference,
                using: configuration
            )
            
            scanResult = freshScan
            
            let repairCandidates =
            freshScan
                .variantRepairCandidates
            
            guard !repairCandidates.isEmpty else {
                throw FinalUploadsViewModelError
                    .noVariantRepairs
            }
            
            for candidate in repairCandidates {
                currentFilename =
                candidate.editedFilename
                
                currentStep =
                "Generating thumbnail and preview…"
                
                let stagedUpload =
                try await Task.detached(
                    priority: .userInitiated
                ) {
                    try FinalUploadFileService
                        .stage(
                            candidate: candidate,
                            reference: reference
                        )
                }
                .value
                
                do {
                    currentStep =
                    "Uploading optimized images…"
                    
                    _ = try await client
                        .uploadFinalVariants(
                            stagedUpload.variants,
                            to: candidate.photoID
                        )
                    
                    optimizedCount += 1
                } catch {
                    try? FinalUploadFileService
                        .removeStagedFile(
                            photoID:
                                candidate.photoID
                        )
                    
                    throw error
                }
                
                try? FinalUploadFileService
                    .removeStagedFile(
                        photoID:
                            candidate.photoID
                    )
            }
            
            lastOptimizedCount =
            optimizedCount
            
            currentFilename = nil
            currentStep = nil
            
            scanResult = try await fetchScan(
                eventID: eventID,
                reference: reference,
                using: configuration
            )
            
            isRepairingVariants = false
        } catch {
            let repairError =
            error.localizedDescription
            
            lastOptimizedCount =
            optimizedCount
            
            currentFilename = nil
            currentStep = nil
            isRepairingVariants = false
            
            if let refreshedScan =
                try? await fetchScan(
                    eventID: eventID,
                    reference: reference,
                    using: configuration
                )
            {
                scanResult = refreshedScan
            }
            
            errorMessage = repairError
        }
    }
    
    func showError(
        _ error: Error
    ) {
        errorMessage =
        error.localizedDescription
    }
    
    private func fetchScan(
        eventID: String,
        reference: EventFolderReference,
        using configuration:
        APIConfigurationStore
    ) async throws -> FinalUploadScanResult {
        let client =
        try configuration.makeClient()
        
        let photos =
        try await client.fetchEventPhotos(
            eventID: eventID
        )
        
        return try await Task.detached(
            priority: .userInitiated
        ) {
            try EditedFolderService.scan(
                reference: reference,
                photos: photos
            )
        }
        .value
    }
}
