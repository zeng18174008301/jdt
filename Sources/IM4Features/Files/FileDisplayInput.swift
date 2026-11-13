// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
public struct FileDisplayInput: Equatable, Sendable {
    let name: String
    let type: String
    let size: String
    let owner: String
    let source: String
    let time: String
    let scope: String
    let status: String
    let accentHex: UInt
    let downloadAvailable: Bool

    public init(name: String, type: String, size: String, owner: String, source: String, time: String,
                scope: String, status: String, accentHex: UInt, downloadAvailable: Bool) {
        self.name = name
        self.type = type
        self.size = size
        self.owner = owner
        self.source = source
        self.time = time
        self.scope = scope
        self.status = status
        self.accentHex = accentHex
        self.downloadAvailable = downloadAvailable
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
