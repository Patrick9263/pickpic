import Combine
import Foundation

private enum FinalUploadsViewModelError:
    LocalizedError
{
    case noReadyFinals
    
    var errorDescription: String? {
        switch self {
        case .noReadyFinals:
            return """
            No edited JPEGs currently match photos \
            waiting for a final image.
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
    var uploadedCount = 0
    
    @Published private(set)
    var currentFilename: String?
    
    @Published private(set)
    var lastUploadedCount: Int?
    
    @Published private(set)
    var errorMessage: String?
    
    func load(
        eventID: String,
        reference: EventFolderReference,
        using configuration:
        APIConfigurationStore
    ) async {
        guard
            !isLoading,
            !isUploading
        else {
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
        guard
            !isUploading,
            !isLoading
        else {
            return
        }
        
        isUploading = true
        uploadedCount = 0
        currentFilename = nil
        lastUploadedCount = nil
        errorMessage = nil
        
        do {
            let client =
            try configuration.makeClient()
            
            let photos =
            try await client.fetchEventPhotos(
                eventID: eventID
            )
            
            let freshScan =
            try await Task.detached(
                priority: .userInitiated
            ) {
                try EditedFolderService.scan(
                    reference: reference,
                    photos: photos
                )
            }
            .value
            
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
                    _ = try await client
                        .uploadFinalPhoto(
                            stagedUpload,
                            to: candidate.photoID
                        )
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
                
                uploadedCount += 1
            }
            
            lastUploadedCount = uploadedCount
            currentFilename = nil
            
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
            
            currentFilename = nil
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
