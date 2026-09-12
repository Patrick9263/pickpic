import Testing

@testable import PickPic

struct EditedFolderServiceTests {
    @Test(arguments: [
        "jpg", "jpeg", "JPG", "JPEG", "Jpg",
    ])
    func supportedExtensionsAreAccepted(fileExtension: String) {
        #expect(
            EditedFolderService
                .isSupportedEditedFileExtension(fileExtension)
        )
    }

    // #236: saving (rather than exporting) from Affinity, or exporting to
    // the wrong format, leaves a file in Edited with one of these
    // extensions. It must be reported as "unsupported format", not
    // silently dropped from both the matched and missing lists.
    @Test(arguments: [
        "png", "heic", "tiff", "tif", "afphoto", "PNG", "",
    ])
    func unsupportedExtensionsAreRejected(fileExtension: String) {
        #expect(
            !EditedFolderService
                .isSupportedEditedFileExtension(fileExtension)
        )
    }
}
